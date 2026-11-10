// Symbols the iOS Simulator build lacks, so the app links there.
// Throwaway scaffolding for tools/sim: none of this is meant to run a game.
// FEXBridge.mm and WiniosGL.m are excluded from the simulator build (FEX headers are not
// generated for it; EAGL's IOSurface and presentDrawable:afterMinimumDuration: are device-only),
// and the simulator SDK has no MetalFX, whose classes DXMT's archive still names.
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

@interface MTLFXFrameInterpolatorDescriptor : NSObject @end
@implementation MTLFXFrameInterpolatorDescriptor @end
@interface MTLFXSpatialScalerDescriptor : NSObject @end
@implementation MTLFXSpatialScalerDescriptor @end
@interface MTLFXTemporalScalerDescriptor : NSObject @end
@implementation MTLFXTemporalScalerDescriptor @end
@interface MTLSharedTextureHandle : NSObject @end
@implementation MTLSharedTextureHandle @end

typedef void (*fex_log_callback_t)(const char *message);
void fex_set_log_callback(fex_log_callback_t callback) { (void)callback; }
int64_t fex_test_execute(void) { return 0; }
int64_t fex_get_jit_write_offset(void) { return 0; }

uint64_t madeira_frame_count(void) { return 0; }
void madeira_gl_wait_active(void) {}
void *madeira_gl_context_create(void *share, int *major) { (void)share; if (major) *major = 0; return NULL; }
void madeira_gl_context_release(void *context) { (void)context; }
int madeira_gl_make_current(void *context) { (void)context; return 0; }
int madeira_gl_present(void **state, void *hwnd, unsigned int fbo, int width, int height) {
    (void)state; (void)hwnd; (void)fbo; (void)width; (void)height; return 0;
}
void madeira_gl_present_release(void *state) { (void)state; }
void *madeira_zink_target_bind(void **state, void *hwnd, int width, int height, int *row_pixels) {
    (void)state; (void)hwnd; (void)width; (void)height; (void)row_pixels; return NULL;
}
void *madeira_zink_target_present(void **state, void *hwnd, int *row_pixels) {
    (void)state; (void)hwnd; (void)row_pixels; return NULL;
}
void madeira_zink_target_release(void *state) { (void)state; }
