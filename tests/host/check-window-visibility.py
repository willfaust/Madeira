#!/usr/bin/env python3
"""Exercise the production compositor callback and Wine visibility predicate.

Compiles the callback's frame-forwarding block with Wine's actual
is_window_visible implementation and a synthetic window tree. No UIKit,
Wine process, GPU or account is used. The old rect-only decision must fail
the hidden Launcher / visible child regression from the build 391 log.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def function(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


driver = (ROOT / "build/win32u-unix/driver_ios.c").read_text()
wine = (ROOT / "wine/dlls/win32u/window.c").read_text()
app = (ROOT / "app/Madeira/Winios/Winios.m").read_text()
callback = function(driver, "static void winios_drv_window_pos_changed(")
# The remainder is the existing logging, repaint and chained driver hook.
frame = callback[:callback.index("    /* ml505: z-order")] + "}\n"
coordinates = function(driver, "static BOOL winios_drv_screen_rects(")
refresh = function(driver, "static void winios_drv_refresh_children(")
predicate = function(wine, "BOOL is_window_visible( HWND hwnd )")

# A late GDI flush or swapchain must not make a new layer visible by default.
layer = function(app, "static CALayer *winios_layer_for(HWND hwnd, bool create) {")
assert layer.index("l.hidden = YES;") < layer.index("[g_compositor_view.layer addSublayer:l];")
present = function(app, "int winios_surface_present(")
assert "l.hidden = NO" not in present

harness = r'''
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uintptr_t HWND;
typedef int BOOL;
typedef unsigned int UINT, DWORD, ULONG;
struct ratio { unsigned short num, den; };
typedef int NTSTATUS;
typedef struct { int left, top, right, bottom; } RECT;
struct window_rects { RECT window, client, visible; };
struct window_surface { int unused; };
enum coords_relative { COORDS_SCREEN, COORDS_PARENT };
#define TRUE 1
#define FALSE 0
#define GWL_STYLE (-16)
#define GA_PARENT 1
#define WS_VISIBLE 0x10000000u
#define WS_CHILD 0x40000000u
#define SWP_SHOWWINDOW 0x40u
#define SWP_HIDEWINDOW 0x80u
#define SWP_NOSIZE 0x1u
#define SWP_NOMOVE 0x2u
#define SWP_FRAMECHANGED 0x20u
#define STATUS_BUFFER_TOO_SMALL ((NTSTATUS)0xc0000023u)
#define DESKTOP 1
static DWORD styles[512];
static HWND parents[512];
static int child_visible[512], visibility_calls, resize_calls, enum_error;
static int desktop_mode = 1, game_windows, frame_calls, dialog_calls;
static struct { HWND hwnd; int x,y,w,h,visible,cx,cy,cw,ch; } last;
static struct window_rects queried_rects;
static BOOL IsRectEmpty(const RECT *r) { return r->left >= r->right || r->top >= r->bottom; }
static void OffsetRect(RECT *r, int x, int y) { r->left += x; r->right += x; r->top += y; r->bottom += y; }
static struct ratio get_win_monitor_dpi(HWND hwnd, struct ratio *raw_dpi) { (void)hwnd; *raw_dpi = (struct ratio){1,1}; return *raw_dpi; }
static BOOL get_window_rects(HWND hwnd, enum coords_relative relative, struct window_rects *rects, struct ratio dpi) {
    (void)hwnd; (void)relative; assert(dpi.num == 1 && dpi.den == 1); *rects = queried_rects; return TRUE;
}
static DWORD get_window_long(HWND w, int index) { assert(index == GWL_STYLE && w < 512); return styles[w]; }
static HWND get_desktop_window(void) { return DESKTOP; }
static HWND NtUserGetAncestor(HWND w, UINT kind) { assert(kind == GA_PARENT); return parents[w]; }
static HWND *list_window_parents(HWND w) {
    HWND *list = calloc(64, sizeof(*list));
    assert(list);
    unsigned n = 0;
    while ((w = parents[w])) { assert(n < 63); list[n++] = w; }
    return list;
}
static NTSTATUS NtUserBuildHwndList(uintptr_t desk, HWND hwnd, BOOL children,
                                   BOOL non_immersive, UINT tid, ULONG capacity,
                                   HWND *out, ULONG *count) {
    assert(!desk && children && non_immersive && !tid);
    if (enum_error) return -1;
    HWND found[512]; ULONG n = 0;
    for (HWND w = 2; w < 512; w++) {
        HWND parent = parents[w];
        while (parent && parent != hwnd) parent = parents[parent];
        if (parent) found[n++] = w;
    }
    *count = n + 1;
    if (capacity < *count) { resize_calls++; return STATUS_BUFFER_TOO_SMALL; }
    memcpy(out, found, n * sizeof(*out)); out[n] = DESKTOP; /* HWND_BOTTOM */
    return 0;
}
static int winios_desktop_mode(void) { return desktop_mode; }
static int winios_game_windows(void) { return game_windows; }
static void capture(HWND hwnd, int x, int y, int w, int h, int visible,
                    int cx, int cy, int cw, int ch) {
    frame_calls++;
    last.hwnd=hwnd; last.x=x; last.y=y; last.w=w; last.h=h; last.visible=visible;
    last.cx=cx; last.cy=cy; last.cw=cw; last.ch=ch;
}
static void (*winios_window_frame)(HWND,int,int,int,int,int,int,int,int,int) = capture;
static void capture_visibility(HWND hwnd, int visible) {
    assert(hwnd != DESKTOP && hwnd < 512);
    child_visible[hwnd] = visible; visibility_calls++;
}
static void (*winios_window_visibility)(HWND,int) = capture_visibility;
static void (*winios_window_geometry)(HWND,int,int,int,int,int,int,int,int);
static void __attribute__((unused)) ios_note_fullscreen_show(HWND hwnd, UINT swp_flags, const RECT *v) { (void)hwnd; (void)swp_flags; (void)v; }
static void winios_note_dialog_thread(HWND hwnd, const RECT *v) { (void)hwnd; (void)v; dialog_calls++; }
/* PRODUCTION */
static struct window_rects rects = {
    {64,24,1344,624}, {64,24,1344,624}, {64,24,1344,624}
};
static struct window_surface surface;
static void expect(HWND hwnd, UINT flags, int visible) {
    queried_rects = rects;
    frame_calls = 0;
    winios_drv_window_pos_changed(hwnd, 0, 0, flags, &rects, &surface);
    assert(frame_calls == 1 && last.hwnd == hwnd && last.visible == visible);
    assert(last.x == rects.visible.left && last.y == rects.visible.top);
    assert(last.w == rects.visible.right - rects.visible.left);
    assert(last.h == rects.visible.bottom - rects.visible.top);
    assert(last.cx == rects.client.left && last.cy == rects.client.top);
    assert(last.cw == rects.client.right - rects.client.left);
    assert(last.ch == rects.client.bottom - rects.client.top);
}
static void expect_skipped(HWND hwnd) {
    frame_calls = 0;
    winios_drv_window_pos_changed(hwnd, 0, 0, 0, &rects, &surface);
    assert(frame_calls == 0);
}
int main(void) {
    styles[DESKTOP] = WS_VISIBLE;
    parents[2] = DESKTOP;
    styles[2] = 0x06cf0000u; /* hidden 1280x600 Launcher root */
    expect(2, 0x4000181fu, 0);
    styles[3] = WS_CHILD | WS_VISIBLE;
    parents[3] = 2; /* Metal child of the hidden Launcher */
    expect(3, 0x4000181fu, 0);
    expect(3, SWP_SHOWWINDOW, 0);
    styles[4] = 0x14ca0000u; parents[4] = DESKTOP; /* Sign In */
    styles[5] = 0x56050000u; parents[5] = 4;
    expect(4, 0x1963u, 1); expect(5, 0x181fu, 1);
    expect(4, SWP_HIDEWINDOW, 0);
    expect(2, SWP_SHOWWINDOW, 0); /* flags alone don't set WS_VISIBLE */
    styles[6] = WS_CHILD | WS_VISIBLE; parents[6] = 3;
    expect(6, 0, 0); /* indirect hidden ancestor */
    styles[2] |= WS_VISIBLE;
    expect(2, SWP_SHOWWINDOW, 1);
    assert(child_visible[3] == 1 && child_visible[6] == 1); /* no child callback */
    expect(3, 0, 1); expect(6, 0, 1);
    styles[3] &= ~WS_VISIBLE;
    expect(2, SWP_SHOWWINDOW, 1);
    assert(child_visible[3] == 0 && child_visible[6] == 0);
    expect(6, 0, 0);
    styles[3] |= WS_VISIBLE;
    styles[2] &= ~WS_VISIBLE;
    expect(2, SWP_HIDEWINDOW, 0);
    assert(child_visible[3] == 0 && child_visible[6] == 0);
    expect(3, 0, 0); expect(6, 0, 0);
    /* The Sign In children exist before its first parent show in build 391. */
    expect(4, SWP_SHOWWINDOW, 1);
    assert(child_visible[5] == 1);
    rects.visible.right = rects.visible.left;
    expect(4, 0, 0);
    rects.visible.right = 1344; rects.visible.bottom = rects.visible.top;
    expect(4, 0, 0);
    rects.visible.bottom = 624;
    /* A message-only parent never reaches the desktop. */
    styles[7] = WS_VISIBLE; styles[8] = WS_VISIBLE; parents[8] = 7;
    expect(8, 0, 0);
    /* All descendants, including trees larger than the initial 128 entries. */
    styles[10] = WS_VISIBLE; parents[10] = DESKTOP;
    for (HWND w = 11; w < 300; w++) { styles[w] = WS_CHILD | WS_VISIBLE; parents[w] = 10; }
    visibility_calls = resize_calls = 0;
    expect(10, SWP_SHOWWINDOW, 1);
    assert(visibility_calls == 289 && resize_calls == 1 && child_visible[299] == 1);
    styles[10] = 0; expect(10, SWP_HIDEWINDOW, 0);
    assert(child_visible[11] == 0 && child_visible[299] == 0);
    enum_error = 1; visibility_calls = 0;
    expect(10, SWP_HIDEWINDOW, 0); assert(visibility_calls == 0);
    enum_error = 0; winios_window_visibility = NULL;
    expect(4, SWP_SHOWWINDOW, 1); assert(visibility_calls == 0);
    winios_window_visibility = capture_visibility;
    /* Keep the existing direct-game compositor admission rules. */
    desktop_mode = 0; game_windows = 0;
    expect_skipped(4);
    game_windows = 1; dialog_calls = 0;
    expect(4, 0, 1); assert(dialog_calls == 1);
    expect(2, 0, 0); assert(dialog_calls == 1);
    expect_skipped(5); /* game mode doesn't forward child windows */
    styles[8] = WS_VISIBLE; parents[8] = 4;
    expect_skipped(8); /* only desktop-parented roots enter game overlay */
    winios_window_frame = NULL; expect_skipped(4);
    puts("PASS: hidden roots/ancestors, Sign In show, descendant refresh, flags and game admission");
    return 0;
}
'''

compiler = os.environ.get("CC") or shutil.which("clang") or shutil.which("cc")
if not compiler:
    raise SystemExit("A C compiler is required")
with tempfile.TemporaryDirectory(prefix="winios-visibility-") as folder:
    directory = Path(folder)
    source = directory / "visibility.c"
    binary = directory / "visibility"
    old_frame = frame.replace("is_window_visible( hwnd ) && ", "", 1)
    assert old_frame != frame, "the negative control must remove the visibility gate"
    for label, block in (("current", frame), ("rect-only", old_frame)):
        source.write_text(harness.replace("/* PRODUCTION */", predicate + "\n" + coordinates + "\n" + refresh + "\n" + block))
        subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-Wno-unused-parameter", "-g", "-fsanitize=address,undefined",
                        str(source), "-o", str(binary)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if label == "current":
            if result.returncode:
                raise SystemExit(result.stdout + result.stderr)
            print(result.stdout.strip())
        else:
            assert result.returncode != 0 and "last.visible == visible" in result.stderr
            print("PASS: the original rect-only callback fails the hidden Launcher regression")
print("PASS: new compositor layers stay hidden until a Wine frame decision")
