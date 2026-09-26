// IOSDisplayShim.m — iOS stand-in for Wine's mac driver, used by DXMT.
//
// DXMT (src/winemetal/unix/winemetal_unix.c) looks up this API via
// dlsym(RTLD_DEFAULT, "macdrv_functions") to obtain a CAMetalLayer for a
// given HWND. We export those symbols from the main binary so DXMT finds
// them in the same process.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <pthread.h>

#include "IOSDisplayShim.h"

// --- Types mirroring DXMT's expectations (see winemetal_unix.c lines ~1524) ---

typedef struct macdrv_opaque_metal_device *macdrv_metal_device;
typedef struct macdrv_opaque_metal_view   *macdrv_metal_view;
typedef struct macdrv_opaque_metal_layer  *macdrv_metal_layer;
typedef struct macdrv_opaque_view         *macdrv_view;
typedef struct macdrv_opaque_window       *macdrv_window;
typedef struct opaque_HWND                *HWND;

struct macdrv_win_data {
    HWND         hwnd;
    macdrv_window cocoa_window;
    macdrv_view   cocoa_view;
    macdrv_view   client_cocoa_view;
};

struct macdrv_functions_t {
    void (*macdrv_init_display_devices)(BOOL);
    struct macdrv_win_data *(*get_win_data)(HWND hwnd);
    void (*release_win_data)(struct macdrv_win_data *data);
    macdrv_window (*macdrv_get_cocoa_window)(HWND hwnd, BOOL require_on_screen);
    macdrv_metal_device (*macdrv_create_metal_device)(void);
    void (*macdrv_release_metal_device)(macdrv_metal_device d);
    macdrv_metal_view (*macdrv_view_create_metal_view)(macdrv_view v, macdrv_metal_device d);
    macdrv_metal_layer (*macdrv_view_get_metal_layer)(macdrv_metal_view v);
    void (*macdrv_view_release_metal_view)(macdrv_metal_view v);
    void (*on_main_thread)(dispatch_block_t b);
};

// --- iOS-side state: one layer shared by the whole process ---

static CAMetalLayer *g_layer = nil;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

void madeira_display_set_layer(CAMetalLayer *layer) {
    pthread_mutex_lock(&g_lock);
    g_layer = layer;
    pthread_mutex_unlock(&g_lock);
}

// --- The guest's virtual monitor ---------------------------------------
//
// win32u owns this number (build/win32u-unix/sysparams_ios.c, ios_screen_size).
// It is no longer a launch-time constant: a guest's ChangeDisplaySettings
// really resizes the virtual monitor, so anything that maps guest pixels to
// screen points -- the presented layer's frame and touch mapping both --
// has to ask for the CURRENT size rather than read MADEIRA_SCREEN_W/H once.
//
// sysparams_ios.c calls winios_display_mode_changed() from its publish path
// (weak import, so win32u still links without the app). The value is cached
// here and seeded from the environment, so a read before the first publish
// still answers with the session default instead of zero.

static int g_screen_w, g_screen_h;
static pthread_mutex_t g_screen_lock = PTHREAD_MUTEX_INITIALIZER;

NSString * const MadeiraDisplayModeChangedNotification = @"MadeiraDisplayModeChanged";

static void madeira_seed_screen_size_locked(void) {
    if (g_screen_w > 0 && g_screen_h > 0) return;
    const char *we = getenv("MADEIRA_SCREEN_W"), *he = getenv("MADEIRA_SCREEN_H");
    int w = (we && atoi(we) > 0) ? atoi(we) : 1024;
    int h = (he && atoi(he) > 0) ? atoi(he) : 768;
    g_screen_w = w;
    g_screen_h = h;
}

// Read by Swift (MetalBackedView.guestSize()).
void winios_screen_size(int *w, int *h) {
    pthread_mutex_lock(&g_screen_lock);
    madeira_seed_screen_size_locked();
    if (w) *w = g_screen_w;
    if (h) *h = g_screen_h;
    pthread_mutex_unlock(&g_screen_lock);
}

// Called by win32u whenever the virtual monitor changes size, INCLUDING the
// one-shot publish of the session default. Runs on whatever guest thread made
// the ChangeDisplaySettings call, so the notification is hopped to the main
// queue -- the observers resize UIKit views.
void winios_display_mode_changed(int w, int h) {
    if (w <= 0 || h <= 0) return;

    int changed;
    pthread_mutex_lock(&g_screen_lock);
    changed = (g_screen_w != w || g_screen_h != h);
    g_screen_w = w;
    g_screen_h = h;
    pthread_mutex_unlock(&g_screen_lock);
    if (!changed) return;

    fprintf(stderr, "[display] guest surface is now %dx%d\n", w, h);
    fflush(stderr);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:MadeiraDisplayModeChangedNotification object:nil];
    });
}

// --- macdrv_* implementations ---

// DXMT only dereferences client_cocoa_view (passing it straight back to
// macdrv_view_create_metal_view), so we use that field to carry the HWND
// through: desktop mode needs it to pick the right window's layer. One
// static struct suffices — DXMT's get/create/release sequence is not
// concurrent per-process, and the value is consumed before release.
static struct macdrv_win_data g_fake_win_data = {
    .hwnd              = NULL,
    .cocoa_window      = NULL,
    .cocoa_view        = (macdrv_view)(uintptr_t)0x1,
    .client_cocoa_view = (macdrv_view)(uintptr_t)0x1,
};

static struct macdrv_win_data *my_get_win_data(HWND hwnd) {
    g_fake_win_data.hwnd = hwnd;
    g_fake_win_data.client_cocoa_view = (macdrv_view)hwnd;
    return &g_fake_win_data;
}

static void my_release_win_data(struct macdrv_win_data *data) {
    (void)data;
}

static int madeira_desktop_mode(void) {
    static int desk = -1;
    if (desk < 0) {
        const char *d = getenv("MADEIRA_DESKTOP");
        desk = d && *d == '1';
    }
    return desk;
}

// Winios.m compositor: per-window CAMetalLayer inside the window's
// compositor layer (desktop mode only).
extern CAMetalLayer *winios_metal_layer_for_hwnd(void *hwnd);

// ml -- DIRECT-LAUNCH OVERLAY. Winios.m now draws a directly-launched
// program's ordinary GDI windows (dialogs, message boxes, popup menus) into a
// transparent overlay inside the presented layer, so a chooser shown before
// the 3D window exists can be seen and clicked. The one window that must NOT
// be drawn that way is the one HOSTING this layer: its GDI client area is the
// program's own (usually black) paint and would cover the game image. This is
// the only place that knows which HWND that is. Desktop mode does not call it
// -- there each window has its own metal sublayer and its GDI frame is wanted.
extern void winios_overlay_note_metal_hwnd(void *hwnd);

// A window whose rect is degenerate (0x0) hands the compositor a zero frame,
// so the CAMetalLayer it makes for that window is 0x0 too -- and DXMT then
// presents frame after frame into a layer that cannot draw a single pixel,
// inside a window layer the compositor has hidden because the window "has no
// area". The window rect being 0x0 is the real bug and must be fixed in
// win32u; this is the backstop that keeps the output on screen meanwhile.
//
// The swapchain knows its own size: DXMT sets drawableSize on the layer right
// after it takes it (ApplyLayerProps -> changeLayerProperties). drawableSize
// is not set yet when the layer is handed over, so retry briefly, then size
// the layer from the backbuffer, aspect-fitted into the compositor area, and
// un-hide the ancestors the zero rect hid.
#define MADEIRA_DEGENERATE_RETRIES 12

static void madeira_fix_degenerate_layer(CAMetalLayer *layer, void *hwnd, int attempt) {
    if (!layer) return;
    if (!CGRectIsEmpty(layer.frame)) return;  // a real window rect arrived meanwhile

    CGSize drawable = layer.drawableSize;
    if (drawable.width < 1 || drawable.height < 1) {
        if (attempt >= MADEIRA_DEGENERATE_RETRIES) {
            fprintf(stderr, "[madeira-display] hwnd=%p layer frame is 0x0 and the swapchain "
                            "never published a drawable size -- nothing to show\n", hwnd);
            fflush(stderr);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            madeira_fix_degenerate_layer(layer, hwnd, attempt + 1);
        });
        return;
    }

    CALayer *window_layer = layer.superlayer;
    CALayer *root = window_layer.superlayer ?: window_layer;
    if (!window_layer || CGRectIsEmpty(root.bounds)) return;

    CGRect avail = root.bounds;
    CGFloat s = MIN(avail.size.width / drawable.width, avail.size.height / drawable.height);
    CGSize fit = CGSizeMake(drawable.width * s, drawable.height * s);
    CGPoint in_root = CGPointMake(avail.origin.x + (avail.size.width - fit.width) / 2,
                                  avail.origin.y + (avail.size.height - fit.height) / 2);
    CGPoint in_window = [window_layer convertPoint:in_root fromLayer:root];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.frame = CGRectMake(in_window.x, in_window.y, fit.width, fit.height);
    layer.hidden = NO;
    for (CALayer *l = window_layer; l && l != root.superlayer; l = l.superlayer)
        l.hidden = NO;
    [CATransaction commit];

    fprintf(stderr, "[madeira-display] hwnd=%p DEGENERATE window rect: sized the metal layer from "
                    "the swapchain instead -- drawable=%.0fx%.0f -> frame=(%.0f,%.0f %.0fx%.0f)\n",
            hwnd, drawable.width, drawable.height,
            layer.frame.origin.x, layer.frame.origin.y,
            layer.frame.size.width, layer.frame.size.height);
    fflush(stderr);
}

static macdrv_metal_device my_create_metal_device(void) {
    // DXMT also has a separate code path that creates its own MTLDevice;
    // this is only called by a Wine-flavoured API we don't hit. Return a
    // non-null sentinel so the caller doesn't think it's a failure.
    return (macdrv_metal_device)(uintptr_t)0x1;
}

static void my_release_metal_device(macdrv_metal_device d) {
    (void)d;
}

// The critical two: return a "view" handle that maps to the CAMetalLayer.
// We pack the layer pointer directly. `v` carries the swapchain's HWND
// (see my_get_win_data). Desktop mode: per-window layer in the desktop
// compositor. Game mode: the fullscreen singleton, exactly as before.
static macdrv_metal_view my_view_create_metal_view(macdrv_view v, macdrv_metal_device d) {
    (void)d;
    if (madeira_desktop_mode()) {
        CAMetalLayer *layer = winios_metal_layer_for_hwnd((void *)v);
        if (!layer) {
            NSLog(@"[madeira-display] desktop metal layer creation failed for hwnd=%p", (void *)v);
            return NULL;
        }
        fprintf(stderr, "[madeira-display] desktop metal view for hwnd=%p layer=%p frame=(%.0f,%.0f %.0fx%.0f)\n",
                (void *)v, layer, layer.frame.origin.x, layer.frame.origin.y,
                layer.frame.size.width, layer.frame.size.height);
        fflush(stderr);
        if (CGRectIsEmpty(layer.frame)) {
            void *hwnd = (void *)v;
            dispatch_async(dispatch_get_main_queue(), ^{
                madeira_fix_degenerate_layer(layer, hwnd, 0);
            });
        }
        return (macdrv_metal_view)CFBridgingRetain(layer);
    }
    pthread_mutex_lock(&g_lock);
    CAMetalLayer *layer = g_layer;
    pthread_mutex_unlock(&g_lock);
    if (!layer) {
        NSLog(@"[madeira-display] view_create_metal_view called before layer registered!");
        return NULL;
    }
    winios_overlay_note_metal_hwnd((void *)v);
    return (macdrv_metal_view)CFBridgingRetain(layer);
}

static macdrv_metal_layer my_view_get_metal_layer(macdrv_metal_view v) {
    return (macdrv_metal_layer)v;
}

static void my_view_release_metal_view(macdrv_metal_view v) {
    if (v) CFBridgingRelease((CFTypeRef)v);
}

static void my_on_main_thread(dispatch_block_t b) {
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

// --- Exported symbols (dlsym RTLD_DEFAULT finds these in the main binary) ---
//
// `used` is LOAD-BEARING, not decoration. Nothing in this program references
// these by name: DXMT's winemetal_unix.c reaches them only through
// dlsym(RTLD_DEFAULT, "macdrv_functions"), which the linker cannot see. Under a
// Release link (-dead_strip) they are therefore unreferenced and get removed,
// visibility("default") notwithstanding -- visibility governs whether a symbol
// that SURVIVES is exported, not whether it survives. `used` emits .no_dead_strip
// so the linker keeps them.
//
// That is exactly how Thumper broke on 2026-08-08: the host app was rebuilt
// Release instead of Debug, these six symbols vanished from the binary, DXMT's
// lookup returned NULL and d3d11_swapchain aborted with "your Wine has no
// exported symbols needed by DXMT" -> exit code 3 -> white screen.
//
// `used` alone proved sufficient: after adding it, all six land in the export
// trie of a Release build, so no -u roots or -export_dynamic are needed. Do not
// assume that stays true -- VERIFY BY CONTENT after any build or link change:
//   xcrun dyld_info -exports Madeira.app/Madeira | grep macdrv_functions
// If that prints nothing, Thumper will exit 3 with a white screen.

__attribute__((used, visibility("default")))
struct macdrv_functions_t macdrv_functions = {
    .macdrv_init_display_devices    = NULL,
    .get_win_data                   = my_get_win_data,
    .release_win_data               = my_release_win_data,
    .macdrv_get_cocoa_window        = NULL,
    .macdrv_create_metal_device     = my_create_metal_device,
    .macdrv_release_metal_device    = my_release_metal_device,
    .macdrv_view_create_metal_view  = my_view_create_metal_view,
    .macdrv_view_get_metal_layer    = my_view_get_metal_layer,
    .macdrv_view_release_metal_view = my_view_release_metal_view,
    .on_main_thread                 = my_on_main_thread,
};

// Also export individual symbols as a fallback (DXMT checks both paths).
__attribute__((used, visibility("default")))
struct macdrv_win_data *get_win_data(HWND hwnd) { return my_get_win_data(hwnd); }

__attribute__((used, visibility("default")))
void release_win_data(struct macdrv_win_data *data) { my_release_win_data(data); }

__attribute__((used, visibility("default")))
macdrv_metal_view macdrv_view_create_metal_view(macdrv_view v, macdrv_metal_device d) {
    return my_view_create_metal_view(v, d);
}

__attribute__((used, visibility("default")))
macdrv_metal_layer macdrv_view_get_metal_layer(macdrv_metal_view v) {
    return my_view_get_metal_layer(v);
}

__attribute__((used, visibility("default")))
void macdrv_view_release_metal_view(macdrv_metal_view v) {
    my_view_release_metal_view(v);
}
