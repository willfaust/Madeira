/* GPL-3.0-or-later WITH the Madeira Converter Exception, version 1. */
// WiniosGL.m — the EAGL half of the winios OpenGL driver.
//
// build/win32u-unix/opengl_ios.c implements WGL for win32u on top of Apple's
// OpenGL ES. It calls into this file for the parts that need Objective-C:
//
//   madeira_gl_context_*   EAGLContext lifetime and make-current.
//   madeira_gl_present     put a GL framebuffer on screen.
//
// Presenting: EAGL has no window surface here, so the app renders into an FBO
// (see opengl_ios.c). On swap that FBO is blitted into one of three
// IOSurface-backed GL textures, and the same IOSurface, wrapped as a Metal
// texture, is drawn onto the window's CAMetalLayer -- the layer DXMT uses
// (madeira_display_layer_for_hwnd). The GL blit is completed with glFinish
// before Metal samples the surface: GL and Metal share no fence here, and a
// torn or stale frame is worse than the wait. The ring of three lets GL write
// the next frame while Metal may still be reading an earlier one.
//
// Everything runs on the thread that owns the GL context (Wine's render
// thread); nothing here touches UIKit.

#define GLES_SILENCE_DEPRECATION 1
// The macro above does not reach the OpenGLES module headers; EAGL is
// deprecated but it is the only OpenGL iOS has.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLIOSurface.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <QuartzCore/CAMetalLayer.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>

#include "../IOSDisplayShim.h"

#define GL_RING 3

// stderr is what the app's log view captures (see Winios.m).
#define GLLOG(fmt, ...) do { fprintf(stderr, "[winios-gl] " fmt "\n", ##__VA_ARGS__); fflush(stderr); } while (0)

// ---- background gate -----------------------------------------------------
//
// iOS refuses GPU work from an app that is not active: MoltenVK loses the
// VkDevice ("Insufficient Permission (to submit GPU work from background)")
// and the GL context never draws again; EAGL kills the app outright. The app
// keeps running in the background (its audio session), so the game keeps
// rendering. Each present waits here while the app is inactive; it starts
// waiting at WillResignActive, a little before the GPU is actually denied.
// Notifications are observed without touching UIKit state.

static pthread_mutex_t gl_gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gl_gate_cond = PTHREAD_COND_INITIALIZER;
static BOOL gl_gate_inactive;

static void gl_gate_set(BOOL inactive) {
    pthread_mutex_lock(&gl_gate_lock);
    gl_gate_inactive = inactive;
    pthread_cond_broadcast(&gl_gate_cond);
    pthread_mutex_unlock(&gl_gate_lock);
}

static void gl_gate_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:@"UIApplicationWillResignActiveNotification" object:nil queue:nil
                    usingBlock:^(NSNotification *n) { gl_gate_set(YES); }];
        [nc addObserverForName:@"UIApplicationDidBecomeActiveNotification" object:nil queue:nil
                    usingBlock:^(NSNotification *n) { gl_gate_set(NO); }];
    });
}

void madeira_gl_wait_active(void) {
    gl_gate_init();
    pthread_mutex_lock(&gl_gate_lock);
    if (gl_gate_inactive) {
        GLLOG("app inactive: holding GL presents until it is active again");
        while (gl_gate_inactive) pthread_cond_wait(&gl_gate_cond, &gl_gate_lock);
        GLLOG("app active: GL presents resumed");
    }
    pthread_mutex_unlock(&gl_gate_lock);
}

// ---- contexts ------------------------------------------------------------

void *madeira_gl_context_create(void *share, int *major) {
    @autoreleasepool {
        EAGLContext *s = (__bridge EAGLContext *)share;
        EAGLSharegroup *group = s ? s.sharegroup : nil;
        EAGLContext *c = nil;

        // A shared context has to use the same API as the one it shares with.
        if (!s || s.API == kEAGLRenderingAPIOpenGLES3)
            c = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3 sharegroup:group];
        if (!c && (!s || s.API == kEAGLRenderingAPIOpenGLES2))
            c = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2 sharegroup:group];
        if (!c) return NULL;

        c.multiThreaded = NO;
        *major = c.API == kEAGLRenderingAPIOpenGLES3 ? 3 : 2;
        return (void *)CFBridgingRetain(c);
    }
}

void madeira_gl_context_release(void *context) {
    @autoreleasepool {
        EAGLContext *c = (__bridge EAGLContext *)context;
        if (!c) return;
        if ([EAGLContext currentContext] == c) [EAGLContext setCurrentContext:nil];
        CFBridgingRelease(context);
    }
}

int madeira_gl_make_current(void *context) {
    @autoreleasepool {
        return [EAGLContext setCurrentContext:(__bridge EAGLContext *)context] ? 1 : 0;
    }
}

// ---- presenter -----------------------------------------------------------

static NSString *const kPresentShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct V { float4 pos [[position]]; float2 uv; };\n"
     "vertex V vs(uint id [[vertex_id]]) {\n"
     "    float2 p = float2((id << 1) & 2, id & 2);\n"   // one triangle covering the target
     "    V o;\n"
     "    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);\n"
     // GL writes the bottom row first, so texture row 0 belongs at the bottom:
     // uv.y = 0 at NDC y = -1 is exactly the GL-to-screen flip.
     "    o.uv = p;\n"
     "    return o;\n"
     "}\n"
     "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
     "                   sampler s [[sampler(0)]]) {\n"
     "    return float4(t.sample(s, in.uv).rgb, 1.0);\n"
     "}\n";

typedef struct {
    IOSurfaceRef surface;
    GLuint tex, fbo;
    id<MTLTexture> mtl_tex;
    id<MTLCommandBuffer> last;   // last Metal work that read this slot
    BOOL locked;                 // Zink target: CPU-locked for OSMesa to write
} GLSlot;

@interface MadeiraGLPresenter : NSObject {
@public
    EAGLContext *gl_ctx;         // context the slot textures/FBOs were made in
    CAMetalLayer *layer;         // looked up once: desktop mode resolves it on the main thread
    GLSlot slots[GL_RING];
    int width, height, next;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    MTLPixelFormat pipeline_format;
    id<MTLSamplerState> sampler;
    unsigned long frames;
}
@end

@implementation MadeiraGLPresenter
@end

static void slots_release(MadeiraGLPresenter *p, BOOL delete_gl) {
    for (int i = 0; i < GL_RING; i++) {
        GLSlot *s = &p->slots[i];
        if (s->last) [s->last waitUntilCompleted];
        if (s->locked) IOSurfaceUnlock(s->surface, 0, NULL);
        s->locked = NO;
        if (delete_gl) {
            if (s->fbo) glDeleteFramebuffers(1, &s->fbo);
            if (s->tex) glDeleteTextures(1, &s->tex);
        }
        if (s->surface) CFRelease(s->surface);
        s->surface = NULL;
        s->tex = s->fbo = 0;
        s->mtl_tex = nil;
        s->last = nil;
    }
    p->width = p->height = 0;
}

static BOOL slots_create(MadeiraGLPresenter *p, EAGLContext *ctx, int w, int h) {
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:w height:h mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    GLint prev_tex = 0, prev_draw = 0;

    glGetIntegerv(GL_TEXTURE_BINDING_2D, &prev_tex);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);

    for (int i = 0; i < GL_RING; i++) {
        GLSlot *s = &p->slots[i];
        NSDictionary *props = @{
            (id)kIOSurfaceWidth: @(w),
            (id)kIOSurfaceHeight: @(h),
            (id)kIOSurfaceBytesPerElement: @4,
            (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
        };
        if (!(s->surface = IOSurfaceCreate((__bridge CFDictionaryRef)props))) {
            GLLOG("IOSurfaceCreate %dx%d failed", w, h);
            goto fail;
        }
        glGenTextures(1, &s->tex);
        glBindTexture(GL_TEXTURE_2D, s->tex);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        if (![ctx texImageIOSurface:s->surface target:GL_TEXTURE_2D internalFormat:GL_RGBA
                              width:w height:h format:GL_BGRA_EXT type:GL_UNSIGNED_BYTE plane:0]) {
            GLLOG("texImageIOSurface %dx%d failed", w, h);
            goto fail;
        }
        glGenFramebuffers(1, &s->fbo);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, s->fbo);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, s->tex, 0);
        GLenum status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            GLLOG("IOSurface framebuffer incomplete %#x", status);
            goto fail;
        }
        if (!(s->mtl_tex = [p->device newTextureWithDescriptor:desc iosurface:s->surface plane:0])) {
            GLLOG("Metal texture for IOSurface %dx%d failed", w, h);
            goto fail;
        }
    }
    glBindTexture(GL_TEXTURE_2D, prev_tex);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev_draw);
    p->gl_ctx = ctx;
    p->width = w;
    p->height = h;
    p->next = 0;
    return YES;

fail:
    glBindTexture(GL_TEXTURE_2D, prev_tex);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev_draw);
    slots_release(p, YES);
    return NO;
}

static BOOL pipeline_ensure(MadeiraGLPresenter *p, MTLPixelFormat format) {
    if (p->pipeline && p->pipeline_format == format) return YES;

    NSError *err = nil;
    id<MTLLibrary> lib = [p->device newLibraryWithSource:kPresentShader options:nil error:&err];
    if (!lib) {
        GLLOG("present shader failed to compile: %s", err.description.UTF8String);
        return NO;
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = format;
    if (!(p->pipeline = [p->device newRenderPipelineStateWithDescriptor:pd error:&err])) {
        GLLOG("present pipeline failed: %s", err.description.UTF8String);
        return NO;
    }
    p->pipeline_format = format;

    if (!p->sampler) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        p->sampler = [p->device newSamplerStateWithDescriptor:sd];
    }
    return YES;
}

// Frames put on screen by GL, both backends. DXMT counts its own presents
// (madeira_get_present_count); madeira_frame_count adds the two, so the FPS
// readout and the launch checks that wait for a first frame see GL games too.
static _Atomic uint64_t gl_present_count;
extern uint64_t madeira_get_present_count(void);

uint64_t madeira_frame_count(void) {
    return madeira_get_present_count() + atomic_load_explicit(&gl_present_count, memory_order_relaxed);
}

// The presenter behind *state, created on first use for hwnd's layer.
static MadeiraGLPresenter *presenter_get(void **state, void *hwnd) {
    MadeiraGLPresenter *p = (__bridge MadeiraGLPresenter *)*state;
    if (!p) {
        CAMetalLayer *layer = madeira_display_layer_for_hwnd(hwnd);
        if (!layer) return nil;
        p = [MadeiraGLPresenter new];
        p->layer = layer;
        p->device = layer.device ?: MTLCreateSystemDefaultDevice();
        p->queue = [p->device newCommandQueue];
        p->queue.label = @"winios-gl present";
        *state = (void *)CFBridgingRetain(p);
        GLLOG("presenter for hwnd %p on layer %p", hwnd, (__bridge void *)layer);
    }
    if (!p->layer.device) p->layer.device = p->device;
    return p;
}

// Draw slot `s` (its IOSurface, rows bottom-up) onto the presenter's layer.
static BOOL present_slot(MadeiraGLPresenter *p, GLSlot *s, void *hwnd) {
    CAMetalLayer *layer = p->layer;
    CGSize want = CGSizeMake(p->width, p->height);
    if (!CGSizeEqualToSize(layer.drawableSize, want)) layer.drawableSize = want;
    if (!pipeline_ensure(p, layer.pixelFormat)) return NO;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return NO;

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> cb = [p->queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:p->pipeline];
    [enc setFragmentTexture:s->mtl_tex atIndex:0];
    [enc setFragmentSamplerState:p->sampler atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
    s->last = cb;
    atomic_fetch_add_explicit(&gl_present_count, 1, memory_order_relaxed);

    if (++p->frames == 1 || p->frames % 600 == 0)
        GLLOG("hwnd %p: %lu frames presented (%dx%d)", hwnd, p->frames, p->width, p->height);
    return YES;
}

// Copy framebuffer `fbo` (width x height, colour attachment 0) of the current
// GL context to hwnd's layer. `*state` is the drawable's presenter, created on
// first use. Returns 1 when a frame was presented.
int madeira_gl_present(void **state, void *hwnd, unsigned int fbo, int width, int height) {
    @autoreleasepool {
        EAGLContext *ctx = [EAGLContext currentContext];
        if (!ctx || width <= 0 || height <= 0) return 0;
        MadeiraGLPresenter *p = presenter_get(state, hwnd);
        if (!p) return 0;

        if (p->gl_ctx != ctx || p->width != width || p->height != height) {
            // GL names belong to the context that made them; if the context
            // changed, the old ones are unreachable from here.
            slots_release(p, p->gl_ctx == ctx);
            if (!slots_create(p, ctx, width, height)) return 0;
            GLLOG("presenting %dx%d from context %p", width, height, (__bridge void *)ctx);
        }

        GLSlot *s = &p->slots[p->next];
        p->next = (p->next + 1) % GL_RING;
        if (s->last) [s->last waitUntilCompleted];   // Metal may still be reading this one

        // GL: copy the app's framebuffer into the slot's IOSurface.
        GLint prev_read = 0, prev_draw = 0;
        GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
        if (scissor) glDisable(GL_SCISSOR_TEST);   // the only fragment op that clips a blit
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
        GLint read_buffer = GL_COLOR_ATTACHMENT0;
        glGetIntegerv(GL_READ_BUFFER, &read_buffer);   // FBO state the app may have changed
        if (read_buffer != GL_COLOR_ATTACHMENT0) glReadBuffer(GL_COLOR_ATTACHMENT0);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, s->fbo);
        glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        if (read_buffer != GL_COLOR_ATTACHMENT0) glReadBuffer(read_buffer);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, prev_read);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev_draw);
        if (scissor) glEnable(GL_SCISSOR_TEST);
        glFinish();

        // Metal: draw the IOSurface onto the layer.
        return present_slot(p, s, hwnd) ? 1 : 0;
    }
}

void madeira_gl_present_release(void *state) {
    @autoreleasepool {
        MadeiraGLPresenter *p = (MadeiraGLPresenter *)CFBridgingRelease(state);
        // Only delete GL names if their context is the current one.
        slots_release(p, p->gl_ctx && [EAGLContext currentContext] == p->gl_ctx);
    }
}

// ---- Zink render target (desktop OpenGL through OSMesa) ------------------
//
// OSMesa renders into its own GPU texture and, on glFlush/glFinish, copies the
// frame into a caller-supplied buffer (bottom row first, which is what the
// present shader expects). That buffer is the base address of one of the
// presenter's three IOSurfaces, so the frame lands directly in memory Metal can
// draw. The slot OSMesa writes to stays CPU-locked; presenting unlocks it,
// hands it to Metal and locks the next one. Used by the "zink" backend of
// build/win32u-unix/opengl_ios.c.

static BOOL zink_slots_create(MadeiraGLPresenter *p, int w, int h) {
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:w height:h mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    for (int i = 0; i < GL_RING; i++) {
        GLSlot *s = &p->slots[i];
        NSDictionary *props = @{
            (id)kIOSurfaceWidth: @(w),
            (id)kIOSurfaceHeight: @(h),
            (id)kIOSurfaceBytesPerElement: @4,
            (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
        };
        if (!(s->surface = IOSurfaceCreate((__bridge CFDictionaryRef)props)) ||
            !(s->mtl_tex = [p->device newTextureWithDescriptor:desc iosurface:s->surface plane:0])) {
            GLLOG("zink target: IOSurface %dx%d failed", w, h);
            slots_release(p, NO);
            return NO;
        }
    }
    p->gl_ctx = nil;
    p->width = w;
    p->height = h;
    p->next = 0;
    return YES;
}

static void *zink_slot_lock(GLSlot *s, int *row_pixels) {
    if (s->last) [s->last waitUntilCompleted];   // Metal may still be reading it
    if (!s->locked) {
        IOSurfaceLock(s->surface, 0, NULL);
        s->locked = YES;
    }
    *row_pixels = (int)(IOSurfaceGetBytesPerRow(s->surface) / 4);
    return IOSurfaceGetBaseAddress(s->surface);
}

// Buffer for OSMesa to render hwnd's width x height frame into, (re)creating
// the ring when the size changes. Returns the base address; *row_pixels is the
// row pitch in pixels (OSMESA_ROW_LENGTH).
void *madeira_zink_target_bind(void **state, void *hwnd, int width, int height, int *row_pixels) {
    @autoreleasepool {
        if (width <= 0 || height <= 0) return NULL;
        MadeiraGLPresenter *p = presenter_get(state, hwnd);
        if (!p) return NULL;
        if (p->width != width || p->height != height || !p->slots[0].surface) {
            slots_release(p, NO);
            if (!zink_slots_create(p, width, height)) return NULL;
            GLLOG("zink target %dx%d for hwnd %p", width, height, hwnd);
        }
        return zink_slot_lock(&p->slots[p->next], row_pixels);
    }
}

// Present the frame OSMesa just copied into the current slot (the caller has
// run glFinish) and return the next slot's buffer to render into.
void *madeira_zink_target_present(void **state, void *hwnd, int *row_pixels) {
    @autoreleasepool {
        MadeiraGLPresenter *p = (__bridge MadeiraGLPresenter *)*state;
        if (!p || !p->slots[0].surface) return NULL;
        GLSlot *s = &p->slots[p->next];
        if (s->locked) {
            IOSurfaceUnlock(s->surface, 0, NULL);
            s->locked = NO;
        }
        present_slot(p, s, hwnd);
        p->next = (p->next + 1) % GL_RING;
        return zink_slot_lock(&p->slots[p->next], row_pixels);
    }
}

void madeira_zink_target_release(void *state) {
    @autoreleasepool {
        MadeiraGLPresenter *p = (MadeiraGLPresenter *)CFBridgingRelease(state);
        slots_release(p, NO);
    }
}
