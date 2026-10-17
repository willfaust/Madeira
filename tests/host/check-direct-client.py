#!/usr/bin/env python3
"""Run the production direct-mode client selection and teardown on macOS.

Foundation dictionaries replace the UI compositor; native dispatch runs
synchronously. No device or Wine process is needed.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "app/Madeira/Winios/Winios.m").read_text()


def function(signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


frame = function("void winios_window_frame(")
geometry = function("void winios_window_geometry(")
visibility = function("void winios_window_visibility(")
assert frame.index("g_client_rects[key] =") < frame.index("if (g_comp_game)")
assert geometry.index("g_client_rects[key] =") < geometry.index("if (!l) return;")
assert "g_game_input_hidden = !visible" in frame and "g_game_input_hidden = !visible" in visibility
assert "g_game_input_key = nil;" in function("static void winios_drop_compositor(const char *why) {")

functions = "\n".join(function(signature) for signature in (
    "static void winios_request_game_size(",
    "int winios_game_client_rect(",
    "void winios_note_game_metal_hwnd(",
    "static void winios_remove_layer(HWND hwnd) {",
    "void winios_session_reset(",
    "int winios_compositor_set_hidden(",
))
harness = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <stdatomic.h>
static _Atomic(uintptr_t) g_size_game_hwnd;
typedef void *HWND;
#define dispatch_async(queue, block) (block)()
#define dispatch_get_main_queue() NULL
#define CGRectValue rectValue
#define CALayer TestLayer
#define CAMetalLayer TestMetalLayer
@interface CALayer: NSObject
@property BOOL hidden;
-(void)removeFromSuperlayer;
@end
@implementation CALayer
-(void)removeFromSuperlayer {}
@end
@interface CAMetalLayer: CALayer @end
@implementation CAMetalLayer @end
static NSMutableDictionary<NSNumber *, NSValue *> *g_client_rects, *g_px_rects;
static NSMutableDictionary<NSNumber *, CALayer *> *g_layers;
static NSMutableDictionary<NSNumber *, CAMetalLayer *> *g_metal_layers;
static NSMutableSet<NSNumber *> *g_game_metal;
static NSNumber *g_game_input_key, *g_fit_key;
static BOOL g_game_input_hidden, g_comp_game;
static CALayer *g_compositor_view;
static BOOL desktop, dialog;
static int winios_swapchain_hwnd(void *hwnd) { return hwnd != NULL; }
static void winios_screen_size(int *w, int *h) { *w = 1280; *h = 720; }
static int winios_desktop_session(void) { return desktop; }
static BOOL winios_game_dialog_visible(void) { return dialog; }
static BOOL winios_game_window_shown(NSNumber *key) { return NO; }
static void winios_game_cursor_refresh(void) {}
static void winios_metal_hud_pick(void) {}
static void winios_swapchain_hwnds_reset(void) {}
static void winios_drop_compositor(const char *why) {}
FUNCTIONS
static void expect_rect(int ex, int ey, int ew, int eh) {
    int x = -1, y = -1, w = -1, h = -1;
    assert(winios_game_client_rect(&x, &y, &w, &h));
    assert(x == ex && y == ey && w == ew && h == eh);
}
int main(void) { @autoreleasepool {
    g_client_rects = [NSMutableDictionary new];
    assert(!winios_game_client_rect(NULL, NULL, NULL, NULL));
    void *a = (void *)0x10030, *b = (void *)0x10040;
    g_client_rects[@((uintptr_t)a)] = [NSValue valueWithRect:NSMakeRect(37,51,480,270)];
    winios_note_game_metal_hwnd(a);
    assert(!atomic_load(&g_size_game_hwnd));
    expect_rect(37,51,480,270);
    desktop = YES; assert(!winios_game_client_rect(NULL,NULL,NULL,NULL)); desktop = NO;
    dialog = YES; assert(!winios_game_client_rect(NULL,NULL,NULL,NULL)); dialog = NO;
    g_game_input_hidden = YES; assert(!winios_game_client_rect(NULL,NULL,NULL,NULL)); g_game_input_hidden = NO;
    g_client_rects[@((uintptr_t)a)] = [NSValue valueWithRect:NSMakeRect(42,63,1280,720)];
    expect_rect(42,63,1280,720);  // fresh move/resize, no stale copied rectangle
    winios_note_game_metal_hwnd(b);
    assert(!winios_game_client_rect(NULL,NULL,NULL,NULL)); // no geometry for new HWND yet
    g_client_rects[@((uintptr_t)b)] = [NSValue valueWithRect:NSMakeRect(0,0,640,480)];
    expect_rect(0,0,640,480);
    winios_remove_layer(b); // direct-mode Metal HWND has no GDI layer
    assert(!winios_game_client_rect(NULL,NULL,NULL,NULL));
    assert(!g_client_rects[@((uintptr_t)b)] && ![g_game_metal containsObject:@((uintptr_t)b)]);
    winios_note_game_metal_hwnd(a);
    expect_rect(42,63,1280,720);
    winios_compositor_set_hidden(1); // session ended, even without compositor
    assert(!winios_game_client_rect(NULL,NULL,NULL,NULL));
    winios_note_game_metal_hwnd(a);
    setenv("MADEIRA_DIRECT_WINDOW_SIZE", "1", 1);
    winios_note_game_metal_hwnd(a);
    assert(atomic_load(&g_size_game_hwnd) == (uintptr_t)a);
    winios_session_reset();
    assert(!atomic_load(&g_size_game_hwnd));
    assert(!winios_game_client_rect(NULL,NULL,NULL,NULL) && g_game_metal.count == 0);
    puts("PASS: presenting HWND geometry, desktop/dialog/hidden fallback, switch, destruction and session reset");
} return 0; }
'''.replace("FUNCTIONS", functions)

with tempfile.TemporaryDirectory(prefix="madeira-direct-client-") as temp:
    path, binary = Path(temp) / "check.m", Path(temp) / "check"
    path.write_text(harness)
    subprocess.run([os.environ.get("CC", "clang"), "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    "-framework", "CoreGraphics", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
