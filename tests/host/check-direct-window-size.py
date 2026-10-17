#!/usr/bin/env python3
"""Exercise the production opt-in HWND resize, including reentrant event pumps."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = (root / "build/win32u-unix/driver_ios.c").read_text()
start = source.index("int winios_drv_size_game_window(")
end = source.index("\n}", start) + 2
function = source[start:end]
app = (root / "app/Madeira/Winios/Winios.m").read_text()
start = app.index("static void winios_request_game_size(")
request = app[start:app.index("\n}", start) + 2]
assert "winios_request_game_size(hwnd, cw, ch);" in app
harness = r"""
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
static _Atomic(uintptr_t) g_size_game_hwnd;
static int winios_swapchain_hwnd(void *h) { return h == (void *)1; }
static void winios_screen_size(int *w, int *h) { *w = 1280; *h = 720; }
REQUEST
typedef void *HWND;
typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define COORDS_SCREEN 0
#define SWP_NOZORDER 4
#define SWP_NOACTIVATE 16
struct rect { int left, top, right, bottom; };
struct window_rects { struct rect window, client, visible; };
static int owner = 5, calls, fail, missing;
static struct window_rects rects;
int winios_drv_size_game_window(HWND, int, int);
static int get_window_thread(HWND h, void *unused) { return h ? owner : 0; }
static int GetCurrentThreadId(void) { return 5; }
static int get_thread_dpi(void) { return 96; }
static int get_window_rects(HWND h, int coords, struct window_rects *r, int dpi) {
 *r = rects; return !missing;
}
static int NtUserSetWindowPos(HWND h, HWND after, int x, int y, int w, int height, int flags) {
 calls++;
 assert(!winios_drv_size_game_window(h,1280,720)); /* reentrant pump */
 assert(x == -4 && y == -30 && w == 1288 && height == 754);
 assert(flags == (SWP_NOZORDER | SWP_NOACTIVATE));
 return !fail;
}
FUNCTION
int main(void) {
 unsetenv("MADEIRA_DIRECT_WINDOW_SIZE"); unsetenv("MADEIRA_DESKTOP");
 winios_request_game_size((void *)1,480,270); assert(!atomic_load(&g_size_game_hwnd));
 setenv("MADEIRA_DIRECT_WINDOW_SIZE","1",1);
 winios_request_game_size((void *)2,480,270); assert(!atomic_load(&g_size_game_hwnd));
 setenv("MADEIRA_DESKTOP","1",1);
 winios_request_game_size((void *)1,480,270); assert(!atomic_load(&g_size_game_hwnd));
 setenv("MADEIRA_DESKTOP","0",1);
 winios_request_game_size((void *)1,1280,720); assert(!atomic_load(&g_size_game_hwnd));
 winios_request_game_size((void *)1,480,270); assert(atomic_exchange(&g_size_game_hwnd,0)==1);
 /* The engine shrinks again after the first correction has completed. */
 winios_request_game_size((void *)1,480,270); assert(atomic_exchange(&g_size_game_hwnd,0)==1);
 winios_request_game_size((void *)1,1280,720); assert(!atomic_load(&g_size_game_hwnd));
 rects.window = (struct rect){37,51,525,355};
 rects.client = (struct rect){41,81,521,351};
 owner=6; assert(!winios_drv_size_game_window((HWND)1,1280,720) && !calls);
 owner=5; assert(winios_drv_size_game_window((HWND)1,1280,720)==1 && calls==1);
 fail=1; assert(winios_drv_size_game_window((HWND)1,1280,720)==-1 && calls==2);
 missing=1; assert(winios_drv_size_game_window((HWND)1,1280,720)==-1 && calls==2);
 missing=0; assert(winios_drv_size_game_window((HWND)1,0,720)==-1 && calls==2);
 rects.client.right=1321; rects.client.bottom=801;
 assert(winios_drv_size_game_window((HWND)1,1280,720)==1 && calls==2);
 puts("PASS: owner, non-client borders/origin, reentrancy, failure, identical size");
}
""".replace("FUNCTION", function).replace("REQUEST", request)
with tempfile.TemporaryDirectory() as folder:
 path=Path(folder); (path/"test.c").write_text(harness)
 subprocess.run(["cc","-std=c11","-D_POSIX_C_SOURCE=200809L",str(path/"test.c"),"-o",str(path/"test")],check=True)
 subprocess.run([str(path/"test")],check=True)
