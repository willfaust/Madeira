#!/usr/bin/env python3
"""Run the production driver with Wine's real rectangle and DPI functions.

Synthetic HWND trees and server replies; no UIKit, Wine process or GPU.
Check the build 391 coordinates, nested children, parent movement, reparent,
raw DPI, clipped bounds, lookup failures and unchanged root/game frames.
The two negative controls must fail placement and inherited movement.
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
dpi = (ROOT / "wine/dlls/win32u/sysparams.c").read_text()
app = (ROOT / "app/Madeira/Winios/Winios.m").read_text()
coordinates = function(driver, "static BOOL winios_drv_screen_rects(")
refresh = function(driver, "static void winios_drv_refresh_children(")
callback = function(driver, "static void winios_drv_window_pos_changed(")
frame = callback[:callback.index("    /* ml505: z-order")] + "}\n"
predicate = function(wine, "BOOL is_window_visible( HWND hwnd )")
getter = function(wine, "BOOL get_window_rects( HWND hwnd,")
# Keep the actual local/cache/parent traversal. Inject replies only at the
# wineserver boundary; Wine's fallback does not return a visible rectangle.
getter = getter[:getter.index("\nother_process:")] + """
other_process:
    ret = server_rects( hwnd, relative, rects, dpi );
    return ret;
}
"""
getter = getter.replace("BOOL get_window_rects(", "static BOOL wine_get_window_rects(", 1)
mirror = function(wine, "static void mirror_rect(")
mapping = function(dpi, "static BOOL needs_dpi_mapping(") + "\n" + function(dpi, "RECT map_dpi_rect(")
bridge = function(app, "void winios_window_geometry(")
assert "if (!l) return;" in bridge
assert "winios_layer_for" not in bridge and "l.hidden" not in bridge
assert "get_window_rects" not in bridge and "get_win_monitor_dpi" not in bridge
assert "winios_apply_contents_rect(key, l);" in bridge
assert "winios_place_metal_layer(key);" in bridge

harness = r'''
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uintptr_t HWND;
typedef int BOOL, NTSTATUS;
typedef unsigned int UINT, DWORD, ULONG;
struct ratio { unsigned short num, den; };
typedef struct { int left, top, right, bottom; } RECT;
struct window_rects { RECT window, client, visible; };
struct window_surface { int unused; };
enum coords_relative { COORDS_CLIENT, COORDS_WINDOW, COORDS_PARENT, COORDS_SCREEN };
typedef struct { HWND parent; struct window_rects rects; DWORD dwExStyle; UINT flags; } WND;
#define TRUE 1
#define FALSE 0
#define DESKTOP 1
#define MESSAGE_PARENT 511
#define WND_DESKTOP ((WND *)2)
#define WND_OTHER_PROCESS ((WND *)1)
#define WIN_CHILDREN_MOVED 0x40u
#define WS_EX_LAYOUTRTL 0x00400000u
#define ERROR_INVALID_WINDOW_HANDLE 1400
#define GWL_STYLE (-16)
#define GA_PARENT 1
#define WS_VISIBLE 0x10000000u
#define WS_CHILD 0x40000000u
#define SWP_NOSIZE 0x1u
#define SWP_NOMOVE 0x2u
#define SWP_FRAMECHANGED 0x20u
#define SWP_SHOWWINDOW 0x40u
#define SWP_HIDEWINDOW 0x80u
#define STATUS_BUFFER_TOO_SMALL ((NTSTATUS)0xc0000023u)
static WND nodes[512];
static HWND parents[512];
static DWORD styles[512];
static UINT window_dpi[512], raw_dpi = 96;
static int foreign[512], query_calls, server_calls, dpi_fail, fail_relative = -1;
static HWND fail_hwnd;
static struct window_rects server_screen;
static int desktop_mode = 1, game_windows;
struct frame { int x,y,w,h,visible,cx,cy,cw,ch; };
static struct frame last, inherited[512];
static int frame_calls, geometry_calls, visibility_calls, inherited_visible[512];
static BOOL IsRectEmpty(const RECT *r) { return r->left >= r->right || r->top >= r->bottom; }
static void OffsetRect(RECT *r, int x, int y) { r->left+=x; r->right+=x; r->top+=y; r->bottom+=y; }
static int muldiv(int a, UINT b, UINT c) {
    int64_t n = (int64_t)a * b;
    return (int)((n + (n >= 0 ? (int64_t)c/2 : -(int64_t)c/2)) / c);
}
static struct ratio get_dpi_for_window(HWND w) { return (struct ratio){window_dpi[w] ? window_dpi[w] : 96,96}; }
static RECT get_primary_monitor_rect(struct ratio dpi) { (void)dpi; return (RECT){0,0,1920,1080}; }
static HWND get_hwnd_message_parent(void) { return MESSAGE_PARENT; }
static HWND get_desktop_window(void) { return DESKTOP; }
static WND *get_win_ptr(HWND w) {
    if (!w || w >= 512) return NULL;
    if (w == DESKTOP || w == MESSAGE_PARENT) return WND_DESKTOP;
    if (foreign[w]) return WND_OTHER_PROCESS;
    nodes[w].parent = parents[w];
    return &nodes[w];
}
static void release_win_ptr(WND *w) { assert(w && w != WND_DESKTOP && w != WND_OTHER_PROCESS); }
static void RtlSetLastWin32Error(UINT error) { assert(error == ERROR_INVALID_WINDOW_HANDLE); }
static struct ratio get_win_monitor_dpi(HWND hwnd, struct ratio *raw) {
    (void)hwnd; if (dpi_fail) return (struct ratio){0}; *raw = (struct ratio){raw_dpi,96}; return (struct ratio){96,96};
}
static DWORD get_window_long(HWND w, int index) { assert(index == GWL_STYLE); return styles[w]; }
static HWND NtUserGetAncestor(HWND w, UINT kind) { assert(kind == GA_PARENT); return parents[w]; }
static HWND *list_window_parents(HWND w) {
    HWND *list = calloc(64, sizeof(*list)); assert(list);
    unsigned n = 0;
    while ((w = parents[w])) { assert(n < 63); list[n++] = w; }
    return list;
}
static NTSTATUS NtUserBuildHwndList(uintptr_t desk, HWND hwnd, BOOL children,
                                   BOOL non_immersive, UINT tid, ULONG capacity,
                                   HWND *out, ULONG *count) {
    assert(!desk && children && non_immersive && !tid);
    HWND found[512]; ULONG n = 0;
    for (HWND w = 2; w < MESSAGE_PARENT; w++) {
        HWND parent = parents[w];
        while (parent && parent != hwnd) parent = parents[parent];
        if (parent) found[n++] = w;
    }
    *count = n + 1;
    if (capacity < *count) return STATUS_BUFFER_TOO_SMALL;
    memcpy(out, found, n * sizeof(*out)); out[n] = DESKTOP;
    return 0;
}
static BOOL server_rects(HWND w, enum coords_relative relative, struct window_rects *out, struct ratio dpi) {
    assert(dpi.num == raw_dpi && dpi.den == 96);
    server_calls++;
    if (relative == COORDS_SCREEN) *out = server_screen;
    else { assert(relative == COORDS_PARENT); *out = nodes[w].rects; }
    out->visible = out->window; /* actual Wine server fallback */
    return TRUE;
}
/* WINE RECTANGLES */
static BOOL get_window_rects(HWND hwnd, enum coords_relative relative, struct window_rects *out, struct ratio dpi) {
    query_calls++; assert(dpi.num == raw_dpi && dpi.den == 96);
    if (hwnd == fail_hwnd && (int)relative == fail_relative) return FALSE;
    return wine_get_window_rects(hwnd, relative, out, dpi);
}
static int winios_desktop_mode(void) { return desktop_mode; }
static int winios_game_windows(void) { return game_windows; }
static void capture(HWND hwnd, int x, int y, int w, int h, int visible,
                    int cx, int cy, int cw, int ch) {
    (void)hwnd; frame_calls++; last=(struct frame){x,y,w,h,visible,cx,cy,cw,ch};
}
static void capture_geometry(HWND hwnd, int x, int y, int w, int h,
                             int cx, int cy, int cw, int ch) {
    geometry_calls++; inherited[hwnd]=(struct frame){x,y,w,h,0,cx,cy,cw,ch};
}
static void capture_visibility(HWND hwnd, int visible) {
    visibility_calls++; inherited_visible[hwnd]=visible;
}
static void (*winios_window_frame)(HWND,int,int,int,int,int,int,int,int,int)=capture;
static void (*winios_window_geometry)(HWND,int,int,int,int,int,int,int,int)=capture_geometry;
static void (*winios_window_visibility)(HWND,int)=capture_visibility;
static void __attribute__((unused)) ios_note_fullscreen_show(HWND hwnd, UINT swp_flags, const RECT *v) { (void)hwnd; (void)swp_flags; (void)v; }
static void winios_note_dialog_thread(HWND hwnd, const RECT *v) { (void)hwnd; (void)v; }
/* DRIVER */
static void set_node(HWND w, HWND parent, RECT window, RECT client, RECT visible) {
    parents[w]=parent; styles[w]=WS_VISIBLE | (parent != DESKTOP ? WS_CHILD : 0);
    nodes[w].rects=(struct window_rects){window,client,visible};
}
static void move(HWND w, int x, int y) {
    OffsetRect(&nodes[w].rects.window,x,y);
    OffsetRect(&nodes[w].rects.client,x,y);
    OffsetRect(&nodes[w].rects.visible,x,y);
}
static void changed(HWND w, UINT flags, const struct window_rects *rects) {
    struct window_rects original=*rects;
    frame_calls=geometry_calls=visibility_calls=0;
    winios_drv_window_pos_changed(w,0,0,flags,rects,NULL);
    assert(!memcmp(&original,rects,sizeof(original))); /* no Wine geometry mutation */
}
static void expect_frame(int x, int y, int w, int h, int cx, int cy, int cw, int ch) {
    assert(frame_calls == 1);
    assert(last.x == x && last.y == y && last.w == w && last.h == h);
    assert(last.cx == cx && last.cy == cy && last.cw == cw && last.ch == ch);
}
int main(void) {
    const UINT still=SWP_NOMOVE | SWP_NOSIZE;
    styles[DESKTOP]=WS_VISIBLE;
    set_node(2,DESKTOP,(RECT){610,140,1310,940},(RECT){610,140,1310,940},(RECT){610,140,1310,940});
    set_node(3,2,(RECT){0,0,700,800},(RECT){0,0,700,800},(RECT){0,0,700,800});
    changed(3,still,&nodes[3].rects);
    expect_frame(610,140,700,800,610,140,700,800); assert(last.visible);
    /* The original hidden 1280x600 Launcher must remain hidden. */
    set_node(5,DESKTOP,(RECT){320,240,1600,840},(RECT){320,240,1600,840},(RECT){320,240,1600,840});
    set_node(6,5,(RECT){0,0,1280,600},(RECT){0,0,1280,600},(RECT){0,0,1280,600});
    styles[5] &= ~WS_VISIBLE;
    changed(6,still,&nodes[6].rects);
    expect_frame(320,240,1280,600,320,240,1280,600); assert(!last.visible);
    set_node(4,3,(RECT){20,30,320,230},(RECT){24,36,314,224},(RECT){22,32,318,228});
    changed(4,still,&nodes[4].rects);
    expect_frame(632,172,296,196,634,176,290,188);
    move(2,40,50); changed(2,SWP_NOSIZE,&nodes[2].rects);
    assert(geometry_calls == 2 && visibility_calls == 2);
    assert(inherited[3].x == 650 && inherited[3].y == 190);
    assert(inherited[4].x == 672 && inherited[4].y == 222);
    assert(inherited[4].cx == 674 && inherited[4].cy == 226);
    assert(inherited_visible[3] && inherited_visible[4]);
    /* Moving the client origin with an unchanged window also moves children. */
    nodes[2].rects.client.left+=7; nodes[2].rects.client.top+=11;
    changed(2,still | SWP_FRAMECHANGED,&nodes[2].rects);
    assert(inherited[3].x == 657 && inherited[3].y == 201);
    move(3,-10,15); changed(3,SWP_NOSIZE,&nodes[3].rects);
    assert(geometry_calls == 1 && inherited[4].x == 669 && inherited[4].y == 248);
    parents[4]=2; changed(4,still | SWP_FRAMECHANGED,&nodes[4].rects);
    expect_frame(679,233,296,196,681,237,290,188);
    set_node(2,DESKTOP,(RECT){-400,-200,300,600},(RECT){-400,-200,300,600},(RECT){-400,-200,300,600});
    changed(3,still,&nodes[3].rects);
    expect_frame(-410,-185,700,800,-410,-185,700,800);
    /* Use the raw output DPI, not get_win_monitor_dpi's logical return value. */
    set_node(2,DESKTOP,(RECT){610,140,1310,940},(RECT){610,140,1310,940},(RECT){610,140,1310,940});
    set_node(3,2,(RECT){0,0,700,800},(RECT){0,0,700,800},(RECT){0,0,700,800});
    /* Wine mirrors saved child rectangles, but the callback is parent-local. */
    nodes[2].dwExStyle=WS_EX_LAYOUTRTL;
    struct window_rects rtl_input={{20,30,320,230},{24,36,310,224},{22,32,316,228}};
    RECT rtl_client={0,0,700,800};
    nodes[3].rects=rtl_input;
    mirror_rect(&rtl_client,&nodes[3].rects.window);
    mirror_rect(&rtl_client,&nodes[3].rects.client);
    mirror_rect(&rtl_client,&nodes[3].rects.visible);
    changed(3,still,&rtl_input);
    expect_frame(994,172,294,196,1000,176,286,188);
    nodes[2].dwExStyle=0;
    set_node(3,2,(RECT){0,0,700,800},(RECT){0,0,700,800},(RECT){0,0,700,800});
    raw_dpi=192;
    struct window_rects scaled={map_dpi_rect(nodes[3].rects.window,(struct ratio){96,96},(struct ratio){192,96}),
                               map_dpi_rect(nodes[3].rects.client,(struct ratio){96,96},(struct ratio){192,96}),
                               map_dpi_rect(nodes[3].rects.visible,(struct ratio){96,96},(struct ratio){192,96})};
    changed(3,still,&scaled);
    expect_frame(1220,280,1400,1600,1220,280,1400,1600);
    raw_dpi=144;
    scaled=(struct window_rects){map_dpi_rect(nodes[3].rects.window,(struct ratio){96,96},(struct ratio){144,96}),
                                map_dpi_rect(nodes[3].rects.client,(struct ratio){96,96},(struct ratio){144,96}),
                                map_dpi_rect(nodes[3].rects.visible,(struct ratio){96,96},(struct ratio){144,96})};
    changed(3,still,&scaled);
    expect_frame(915,210,1050,1200,915,210,1050,1200);
    raw_dpi=96;
    /* Server fallback loses visible bounds; keep the callback's clipped frame. */
    set_node(3,2,(RECT){0,0,700,800},(RECT){4,6,696,794},(RECT){8,10,692,790});
    server_screen=(struct window_rects){{610,140,1310,940},{614,146,1306,934},{610,140,1310,940}};
    foreign[3]=1; server_calls=0;
    changed(3,still,&nodes[3].rects);
    expect_frame(618,150,684,780,614,146,692,788); assert(server_calls == 2);
    foreign[3]=0;
    nodes[2].flags=WIN_CHILDREN_MOVED; server_calls=0;
    changed(3,still,&nodes[3].rects);
    expect_frame(618,150,684,780,614,146,692,788); assert(server_calls == 2);
    nodes[2].flags=0;
    fail_hwnd=3; fail_relative=COORDS_SCREEN;
    changed(3,still,&nodes[3].rects); assert(!frame_calls);
    fail_relative=COORDS_PARENT;
    changed(3,still,&nodes[3].rects); assert(!frame_calls);
    fail_relative=-1; dpi_fail=1;
    changed(3,still,&nodes[3].rects); assert(!frame_calls);
    dpi_fail=0;
    /* Keep authoritative root/fullscreen frames, without a geometry lookup. */
    struct window_rects fullscreen={{0,0,1920,1080},{0,0,1920,1080},{0,0,1920,1080}};
    query_calls=0; changed(2,still,&fullscreen);
    expect_frame(0,0,1920,1080,0,0,1920,1080); assert(!query_calls);
    desktop_mode=0; game_windows=1; query_calls=0;
    changed(2,still,&fullscreen); expect_frame(0,0,1920,1080,0,0,1920,1080);
    assert(!query_calls && !geometry_calls);
    changed(3,still,&nodes[3].rects); assert(!frame_calls && !query_calls);
    desktop_mode=1; game_windows=0;
    winios_window_geometry=NULL;
    changed(2,SWP_SHOWWINDOW,&nodes[2].rects);
    assert(!geometry_calls && visibility_calls == 2);
    winios_window_geometry=capture_geometry; winios_window_visibility=NULL;
    changed(2,SWP_NOSIZE,&nodes[2].rects);
    assert(geometry_calls == 2 && !visibility_calls);
    /* A child with no WS_CHILD bit still receives parent-relative rects. */
    styles[3] &= ~WS_CHILD;
    changed(3,still,&nodes[3].rects);
    expect_frame(618,150,684,780,614,146,692,788);
    puts("PASS: 1080p/nested coordinates, parent/client movement, reparent, RTL, raw DPI, fallback bounds, failures and root/game frames");
    return 0;
}
'''

compiler = os.environ.get("CC") or shutil.which("clang") or shutil.which("cc")
if not compiler:
    raise SystemExit("A C compiler is required")
old_frame = frame.replace(
    "BOOL frame_valid = !desktop || winios_drv_screen_rects( hwnd, new_rects, &rects );",
    "BOOL frame_valid = TRUE;")
assert old_frame != frame
no_movement = frame.replace(
    "winios_drv_refresh_children( hwnd, geometry );",
    "winios_drv_refresh_children( hwnd, FALSE );")
assert no_movement != frame
with tempfile.TemporaryDirectory(prefix="winios-coordinates-") as folder:
    directory = Path(folder)
    source, binary = directory / "coordinates.c", directory / "coordinates"
    for label, block, assertion in (
        ("current", frame, ""),
        ("parent-relative", old_frame, "last.x == x"),
        ("no-parent-movement", no_movement, "geometry_calls == 2")):
        source.write_text(harness.replace("/* WINE RECTANGLES */", mirror + "\n" + mapping + "\n" + getter)
                          .replace("/* DRIVER */", predicate + "\n" + coordinates + "\n" + refresh + "\n" + block))
        subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-Wno-unused-parameter", "-g", "-fsanitize=address,undefined",
                        str(source), "-o", str(binary)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if label == "current":
            if result.returncode:
                raise SystemExit(result.stdout + result.stderr)
            print(result.stdout.strip())
        else:
            assert result.returncode != 0 and assertion in result.stderr, result.stderr
            print("PASS: negative control " + label + " fails its placement assertion")
print("PASS: inherited geometry retains existing layers, visibility, crop and Metal placement")
