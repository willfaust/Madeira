/*
 * Graphics driver management functions
 *
 * Copyright 1994 Bob Amstadt
 * Copyright 1996, 2001 Alexandre Julliard
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#if 0
#pragma makedep unix
#endif

#include <assert.h>
#include <pthread.h>
#include <time.h>

#include "ntstatus.h"
#include "ntgdi_private.h"
#include "ntuser_private.h"
#include "wine/winbase16.h"
#include "wine/list.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(driver);
WINE_DECLARE_DEBUG_CHANNEL(winediag);

static const struct user_driver_funcs lazy_load_driver;
static struct user_driver_funcs null_user_driver;
static WCHAR driver_load_error[80];

#ifdef WINE_IOS
/* winios.drv — Madeira's iOS display/input driver. Lives in
 * app/Madeira/Winios/. Most slots stay NULL so __wine_set_user_driver's
 * SET_USER_FUNC fallback installs the always-success nulldrv_* stubs;
 * we only override the bits that need real iOS UIKit bridging
 * (pProcessEvents, pSetCursor, etc.) once those are wired up.
 *
 * Implementations live in app/Madeira/Winios/Winios.m and are pulled in
 * via these extern declarations. Each is __attribute__((weak)) so the
 * driver registers cleanly even before the Obj-C side is implemented —
 * a missing impl resolves to NULL and SET_USER_FUNC falls back. */
extern BOOL winios_pCreateWindow( HWND hwnd ) __attribute__((weak));
extern BOOL winios_pProcessEvents( DWORD mask ) __attribute__((weak));
extern void winios_pSetCursor( HWND hwnd, HCURSOR cursor ) __attribute__((weak));
extern void winios_pDestroyCursorIcon( HCURSOR cursor ) __attribute__((weak));
extern void winios_pDestroyWindow( HWND hwnd ) __attribute__((weak));
extern UINT winios_pShowWindow( HWND hwnd, INT cmd, RECT *rect, UINT swp ) __attribute__((weak));
extern void winios_pWindowPosChanged( HWND hwnd, HWND insert_after, HWND owner_hint, UINT swp_flags,
                                      const struct window_rects *new_rects, struct window_surface *surface ) __attribute__((weak));

static struct user_driver_funcs winios_user_driver;

/* C bridge for Winios.m to inject mouse input without pulling in Wine
 * headers into Obj-C (where INPUT/HWND/etc. would conflict with UIKit
 * types). Call this from pProcessEvents drain or directly from a
 * deferred Swift dispatch — it just packages an INPUT_MOUSE event and
 * hands it to NtUserSendHardwareInput. */
void winios_drv_post_mouse(int x, int y, unsigned int flags, unsigned int mouse_data, HWND hwnd)
{
    INPUT input;
    input.type           = INPUT_MOUSE;
    input.mi.dx          = x;
    input.mi.dy          = y;
    input.mi.mouseData   = mouse_data;
    input.mi.dwFlags     = flags;
    input.mi.time        = 0;
    input.mi.dwExtraInfo = 0;

    /* Pass hwnd=NULL — the server then hit-tests via shallow_window_from_point
     * which walks the desktop's children (where the game's window lives).
     * Passing the desktop handle goes through window_thread_from_point on
     * the detached desktop window and returns NULL, dropping the message.
     * Call win32u's send_hardware_message directly (same library) instead
     * of the NtUserCallHwndParam inline — we get the raw NTSTATUS and skip
     * a dispatch layer that can fail for its own reasons. */
    NTSTATUS st = send_hardware_message( NULL, 0, &input, 0 );
    {
        /* ml661: the old "first 40 lines" cap is the same trap ml647 fixed on
         * the keyboard side — it is exhausted in the first second of pointer
         * movement, so every later event, including every FAILING one, left no
         * trace and the log read as if the driver had never been called. A
         * button transition (the events a dead on-screen button is about) is
         * rare enough to log every time; moves are thinned. Failures are always
         * logged, and the running failure total is always truthful. */
        static unsigned cnt, moves, bad;
        BOOL is_move = !(flags & ~(unsigned)(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE));
        cnt++;
        if (st) bad++;
        if (st || !is_move || cnt <= 8 || (moves & 0xff) == 0)
            dprintf(2, "[winios] ml661 drv_post_mouse #%u hwnd=%p flags=0x%x x=%d y=%d "
                       "-> status=0x%x (failures=%u)\n",
                    cnt, hwnd, flags, x, y, (unsigned)st, bad);
        if (is_move) moves++;

        /* ml667 — the driver half of [relmouse]; the server half is printed by
         * relmouse_report() in queue_ios.c. Together they bracket the one gap
         * nothing could see before: whether a relative delta that LEFT the app
         * ever became a WM_INPUT for the game.
         *
         * This end reports what win32u handed the server and what the cursor
         * did as a result. rel/acc rising with cursor= standing still means the
         * cursor is pinned (a clip rect, or a game re-centring); rel rising
         * with the server's rel_in standing still means the send_hardware_message
         * call itself is being lost. Relative moves only, so the line appears
         * only in Relative pointer mode, at most once every 5s. */
        if (is_move && !(flags & MOUSEEVENTF_ABSOLUTE))
        {
            static unsigned rel_cnt, rel_bad;
            static long long acc_x, acc_y;
            static struct timespec next_at;
            struct timespec now;

            rel_cnt++;
            if (st) rel_bad++;
            acc_x += x;
            acc_y += y;

            clock_gettime( CLOCK_MONOTONIC, &now );
            if (now.tv_sec >= next_at.tv_sec)
            {
                CURSORINFO info = { .cbSize = sizeof(info) };
                POINT pt = {0};
                DWORD fg_tid = 0, fg_pid = 0;
                HWND fg = NtUserGetForegroundWindow();

                if (NtUserGetCursorInfo( &info )) pt = info.ptScreenPos;
                if (fg) fg_tid = get_window_thread( fg, &fg_pid );

                next_at.tv_sec = now.tv_sec + 5;
                dprintf(2, "[relmouse] ml667 src=drv rel=%u fail=%u acc=(%lld,%lld) "
                           "last=(%d,%d) cursor=(%d,%d) cursor_flags=0x%x "
                           "foreground=%p fg_tid=%04x fg_pid=%04x\n",
                        rel_cnt, rel_bad, acc_x, acc_y, x, y,
                        (int)pt.x, (int)pt.y, (unsigned)info.flags,
                        fg, (unsigned)fg_tid, (unsigned)fg_pid);
            }
        }
    }
}

/* Keyboard sibling of winios_drv_post_key: packages an INPUT_KEYBOARD
 * event. vk is a Windows virtual-key code (VK_RETURN=0x0D, VK_SPACE=0x20,
 * VK_ESCAPE=0x1B, ...); flags is 0 for key-down, KEYEVENTF_KEYUP (0x2)
 * for key-up. Scan code derived via the default layout so games reading
 * scan codes (DirectInput-style) see something plausible. */
void winios_drv_post_key(unsigned short vk, unsigned int flags)
{
    INPUT input = {0};
    NTSTATUS st;
    UINT scan;

    /* ml647: DERIVE THE SCAN CODE. This used to hardcode wScan = 0 while the
     * comment above claimed it was "derived via the default layout" — the
     * comment described an intent the code never implemented.
     *
     * Nothing downstream fills it in for us. wineserver passes our value
     * straight through, twice:
     *     rawkeyboard_init(): RAWKEYBOARD.MakeCode = scan      (queue_ios.c:2093)
     *     queue_keyboard_message(): lparam = scan << 16        (queue_ios.c:2356)
     * so with 0 every synthetic key arrived with MakeCode 0 and an empty
     * scan-code field in WM_KEYDOWN's lParam. No real keyboard can do that.
     *
     * Wine's own UI never noticed, because dialogs read the VK out of wParam.
     * A GAME does notice: Unity reads the keyboard through raw input and
     * DirectInput identifies keys by scan code (DIK_W is 0x11, not 'W'), so
     * W/A/S/D were delivered, accepted with STATUS_SUCCESS, and then discarded
     * as unidentifiable. That is why the on-screen stick moved nothing.
     *
     * MAPVK_VK_TO_VSC_EX returns 0xE0xx for the extended keys — arrows, the nav
     * cluster, right ctrl/alt, numpad enter and divide. Those MUST carry
     * KEYEVENTF_EXTENDEDKEY, or a scan-code reader sees the numpad twin
     * instead: without E0, "up arrow" is numpad 8. */
    scan = NtUserMapVirtualKeyEx( vk, MAPVK_VK_TO_VSC_EX, NtUserGetKeyboardLayout(0) );
    if (scan & 0xe000) flags |= KEYEVENTF_EXTENDEDKEY;

    input.type           = INPUT_KEYBOARD;
    input.ki.wVk         = vk;
    input.ki.wScan       = scan & 0xff;
    input.ki.dwFlags     = flags;
    input.ki.time        = 0;
    input.ki.dwExtraInfo = 0;

    st = send_hardware_message( NULL, 0, &input, 0 );
    {
        /* ml647: COUNT EVENTS, and never let a cap masquerade as absence. The
         * old "first 40 lines" cap was exhausted by arrow keys early in the
         * session, so the WASD presses that prompted this fix left no trace at
         * all and the log looked like they were never sent. Log the first few,
         * then one line per 256 with a running total that is always truthful. */
        static unsigned cnt, bad;
        if (st) bad++;
        cnt++;
        if (cnt <= 8 || (cnt & 0xff) == 0)
            dprintf(2, "[winios] ml647 drv_post_key #%u vk=0x%x scan=0x%x flags=0x%x "
                       "-> status=0x%x (failures=%u)\n",
                    cnt, vk, scan, flags, (unsigned)st, bad);
    }
}

/* [winios-tree] window-tree dump: every top-level window with class,
 * title, style and rects. Driven from the app side (Winios.m
 * ProcessEvents drain) every few seconds in desktop mode — ground truth
 * for "does the taskbar exist / is it visible / where is it". */
void winios_dump_window_tree(void)
{
    HWND list[128];
    ULONG size = ARRAY_SIZE(list), i;
    NTSTATUS status;

    status = NtUserBuildHwndList( 0, 0, FALSE, TRUE, 0, ARRAY_SIZE(list), list, &size );
    if (status)
    {
        dprintf( 2, "[winios-tree] BuildHwndList failed 0x%x\n", (unsigned)status );
        return;
    }
    dprintf( 2, "[winios-tree] ---- %u top-level windows ----\n", (unsigned)(size ? size - 1 : 0) );
    for (i = 0; i + 1 < size && i < ARRAY_SIZE(list); i++)
    {
        HWND hwnd = list[i];
        WCHAR clsW[64], txtW[64];
        char cls[64], txt[64];
        UNICODE_STRING us = { .Buffer = clsW, .MaximumLength = sizeof(clsW) };
        struct window_rects rects = {0};
        DWORD style, ex_style, pid = 0, tid;
        int j, n;

        cls[0] = 0;
        if (NtUserGetClassName( hwnd, FALSE, &us ) > 0)
        {
            for (j = 0; j < us.Length / (int)sizeof(WCHAR) && j < 63; j++)
                cls[j] = (clsW[j] >= 32 && clsW[j] < 127) ? (char)clsW[j] : '?';
            cls[j] = 0;
        }
        n = NtUserInternalGetWindowText( hwnd, txtW, ARRAY_SIZE(txtW) );
        for (j = 0; j < n && j < 63; j++)
            txt[j] = (txtW[j] >= 32 && txtW[j] < 127) ? (char)txtW[j] : '?';
        txt[j] = 0;

        style = get_window_long( hwnd, GWL_STYLE );
        ex_style = get_window_long( hwnd, GWL_EXSTYLE );
        tid = get_window_thread( hwnd, &pid );
        get_window_rects( hwnd, COORDS_SCREEN, &rects, get_thread_dpi() );

        dprintf( 2, "[winios-tree] %p '%s' \"%s\" style=%08x ex=%08x vis=%d tid=%04x "
                 "win={%d,%d,%d,%d} client={%d,%d,%d,%d}\n",
                 hwnd, cls, txt, (unsigned)style, (unsigned)ex_style,
                 (style & WS_VISIBLE) ? 1 : 0, (unsigned)tid,
                 (int)rects.window.left, (int)rects.window.top, (int)rects.window.right, (int)rects.window.bottom,
                 (int)rects.client.left, (int)rects.client.top, (int)rects.client.right, (int)rects.client.bottom );

        /* children of visible top-levels (controls like the Start button) */
        if (style & WS_VISIBLE)
        {
            HWND kids[32];
            ULONG ksize = ARRAY_SIZE(kids), k;
            if (!NtUserBuildHwndList( 0, hwnd, TRUE, TRUE, 0, ARRAY_SIZE(kids), kids, &ksize ))
            {
                for (k = 0; k + 1 < ksize && k < ARRAY_SIZE(kids); k++)
                {
                    WCHAR kclsW[32];
                    char kcls[32];
                    UNICODE_STRING kus = { .Buffer = kclsW, .MaximumLength = sizeof(kclsW) };
                    struct window_rects krects = {0};
                    DWORD kstyle;

                    kcls[0] = 0;
                    if (NtUserGetClassName( kids[k], FALSE, &kus ) > 0)
                    {
                        for (j = 0; j < kus.Length / (int)sizeof(WCHAR) && j < 31; j++)
                            kcls[j] = (kclsW[j] >= 32 && kclsW[j] < 127) ? (char)kclsW[j] : '?';
                        kcls[j] = 0;
                    }
                    kstyle = get_window_long( kids[k], GWL_STYLE );
                    get_window_rects( kids[k], COORDS_SCREEN, &krects, get_thread_dpi() );
                    dprintf( 2, "[winios-tree]    +child %p '%s' style=%08x vis=%d win={%d,%d,%d,%d}\n",
                             kids[k], kcls, (unsigned)kstyle, (kstyle & WS_VISIBLE) ? 1 : 0,
                             (int)krects.window.left, (int)krects.window.top,
                             (int)krects.window.right, (int)krects.window.bottom );
                }
            }
        }
    }
}

/* ============================================================ *
 * winios window surfaces (S2): GDI window content → app compositor.
 * Modeled on win32u's offscreen surface (dce.c): the generic
 * window_surface layer owns the 32bpp top-down DIB and hands us the
 * bits at flush time; we just forward them to the app side, which
 * uploads into a per-window CALayer. Gated on MADEIRA_DESKTOP=1 so the
 * games path keeps its invisible offscreen surfaces unchanged.
 * ============================================================ */

/* Implemented in app/Madeira/Winios/Winios.m (weak, same pattern as the
 * driver hooks below). Called on wine threads — the app side copies the
 * bits before returning and uploads on the main thread. */
extern int winios_surface_present( HWND hwnd, int dirty_x, int dirty_y, int dirty_w, int dirty_h,
                                    int surf_w, int surf_h, int stride, const void *bits ) __attribute__((weak));
extern void winios_window_frame( HWND hwnd, int x, int y, int w, int h, int visible,
                                 int cx, int cy, int cw, int ch ) __attribute__((weak));
/* ml1110 — WHERE THE SURFACE SITS INSIDE THE WINDOW.
 *
 * winios_surface_present carries only the surface's SIZE, and the app side
 * assumed that size was always at window-local (0,0) and never smaller than
 * the window ("surfaces are 128px-aligned, usually LARGER"). get_surface_rect()
 * breaks both halves of that: it INTERSECTS the surface with the virtual screen
 * for a window bigger than the screen, then rounds the result down/up to 128 —
 * so a 1286x1011 window on a 1280x720 desktop gets a 1280x768 surface, and a
 * window whose visible rect starts far off the left/top edge gets a non-zero
 * origin. Publishing the rect once per surface creation is enough: it cannot
 * change without the surface being recreated. Weak, like every other app hook
 * here — a stale app side simply keeps the old (0,0)-and-no-smaller assumption. */
extern void winios_window_surface_rect( HWND hwnd, int left, int top,
                                        int right, int bottom ) __attribute__((weak));
extern void winios_cursor_set( unsigned int id, int w, int h, int hot_x, int hot_y,
                               const void *bgra ) __attribute__((weak));
extern void winios_cursor_show( int show ) __attribute__((weak));
/* ml — direct-launch overlay, see winios_direct_overlay() below. */
extern int winios_overlay_skip_hwnd( void *hwnd ) __attribute__((weak));

static int winios_desktop_mode(void);

/* pSetCursor: extract the cursor image as straight-alpha BGRA and forward
 * to the app-side compositor cursor layer. win32u calls this on every
 * cursor CHANGE (WM_SETCURSOR → NtUserSetCursor), so resize arrows,
 * I-beam and app cursors all arrive here. */
static void winios_drv_set_cursor( HWND hwnd, HCURSOR cursor )
{
    static HCURSOR last_cursor;
    ICONINFO info = {0};
    BITMAP bm;
    HDC hdc;
    unsigned int *color = NULL, *mask = NULL;
    int w, h, i, has_alpha = 0;
    char bmibuf[sizeof(BITMAPINFOHEADER) + 256 * sizeof(RGBQUAD)];
    BITMAPINFO *bmi = (BITMAPINFO *)bmibuf;

    /* ml — WAS gated to desktop mode only ("iOS has no mouse cursor" — see
     * winios_pSetCursor's own comment in Winios.m). Direct-launch titles
     * that rely on the SYSTEM cursor (no self-drawn pointer, common in
     * older DirectInput/GDI-menu games) need this hook too now that the app
     * side can host the drawn cursor on the game's own presented layer
     * instead of the desktop compositor — see winios_set_game_layer in
     * Winios.m. `last_cursor` caching below still applies in both modes. */
    if (!winios_cursor_set) return;
    if (!cursor)
    {
        if (winios_cursor_show) winios_cursor_show( 0 );
        return;
    }
    if (winios_cursor_show) winios_cursor_show( 1 );
    if (cursor == last_cursor) return;

    if (!NtUserGetIconInfo( cursor, &info, NULL, NULL, NULL, 0 )) return;
    hdc = NtGdiCreateCompatibleDC( 0 );

#define WINIOS_BMI_INIT(width, height) do { \
        memset( bmibuf, 0, sizeof(bmibuf) ); \
        bmi->bmiHeader.biSize = sizeof(BITMAPINFOHEADER); \
        bmi->bmiHeader.biWidth = (width); \
        bmi->bmiHeader.biHeight = -(height); \
        bmi->bmiHeader.biPlanes = 1; \
        bmi->bmiHeader.biBitCount = 32; \
        bmi->bmiHeader.biCompression = BI_RGB; \
    } while (0)

    if (info.hbmColor)
    {
        if (!NtGdiExtGetObjectW( info.hbmColor, sizeof(bm), &bm )) goto done;
        w = bm.bmWidth; h = bm.bmHeight;
        if (w <= 0 || h <= 0 || w > 256 || h > 256) goto done;
        if (!(color = malloc( (size_t)w * h * 4 ))) goto done;
        WINIOS_BMI_INIT( w, h );
        NtGdiGetDIBitsInternal( hdc, info.hbmColor, 0, h, color, bmi, DIB_RGB_COLORS,
                                w * h * 4, sizeof(bmibuf) );
        for (i = 0; i < w * h; i++) if (color[i] & 0xff000000) { has_alpha = 1; break; }
        if (!has_alpha)
        {
            /* no alpha channel — derive from the AND mask (0 = opaque) */
            if (!(mask = malloc( (size_t)w * h * 4 ))) goto done;
            WINIOS_BMI_INIT( w, h );
            NtGdiGetDIBitsInternal( hdc, info.hbmMask, 0, h, mask, bmi, DIB_RGB_COLORS,
                                    w * h * 4, sizeof(bmibuf) );
            for (i = 0; i < w * h; i++)
                color[i] = (color[i] & 0xffffff) | ((mask[i] & 0xffffff) ? 0 : 0xff000000);
        }
    }
    else  /* monochrome: hbmMask stacks AND (top) over XOR (bottom) */
    {
        if (!NtGdiExtGetObjectW( info.hbmMask, sizeof(bm), &bm )) goto done;
        w = bm.bmWidth; h = bm.bmHeight / 2;
        if (w <= 0 || h <= 0 || w > 256 || h > 256) goto done;
        if (!(mask = malloc( (size_t)w * h * 2 * 4 ))) goto done;
        WINIOS_BMI_INIT( w, h * 2 );
        NtGdiGetDIBitsInternal( hdc, info.hbmMask, 0, h * 2, mask, bmi, DIB_RGB_COLORS,
                                w * h * 2 * 4, sizeof(bmibuf) );
        if (!(color = malloc( (size_t)w * h * 4 ))) goto done;
        for (i = 0; i < w * h; i++)
        {
            int and_set = mask[i] & 0xffffff;
            int xor_set = mask[w * h + i] & 0xffffff;
            if (and_set && !xor_set) color[i] = 0;              /* transparent */
            else if (xor_set)        color[i] = 0xffffffff;     /* white (invert ≈ white) */
            else                     color[i] = 0xff000000;     /* black */
        }
    }
#undef WINIOS_BMI_INIT

    winios_cursor_set( (unsigned int)(UINT_PTR)cursor, w, h,
                       (int)info.xHotspot, (int)info.yHotspot, color );
    last_cursor = cursor;
    dprintf( 2, "[winios] cursor set hcursor=%p %dx%d hot=(%u,%u)\n",
             cursor, w, h, (unsigned)info.xHotspot, (unsigned)info.yHotspot );

done:
    free( color );
    free( mask );
    if (info.hbmColor) NtGdiDeleteObjectApp( info.hbmColor );
    if (info.hbmMask) NtGdiDeleteObjectApp( info.hbmMask );
    NtGdiDeleteObjectApp( hdc );
}

static int winios_desktop_mode(void)
{
    static int mode = -1;
    if (mode < 0)
    {
        const char *env = getenv( "MADEIRA_DESKTOP" );
        mode = (env && *env == '1');
    }
    return mode;
}

/* ml — THE DIRECT-LAUNCH GDI OVERLAY, win32u side.
 *
 * Two gates in this file used to make a direct launch blind to every ordinary
 * window: pCreateWindowSurface was installed only in desktop mode (so a
 * dialog got win32u's OFFSCREEN surface, whose flush is a no-op and reaches
 * nobody), and winios_window_frame was forwarded only in desktop mode (so
 * nothing on the app side ever learned where a window was). A program that
 * asks a question before it creates its 3D window — a windowed/fullscreen
 * chooser, a message box, an installer-style window — therefore sat waiting
 * for a click on something that was never drawn.
 *
 * Nothing about that is desktop-specific: the surface bits and the window
 * rect are the same data in both modes. So both gates now also open for a
 * direct launch, and the app side decides where to draw the result — into a
 * transparent overlay inside the game's own presented layer rather than the
 * desktop compositor, which must not exist here (its opaque backdrop would
 * cover the game; see winios_ensure_compositor's own comment).
 *
 * The one window this must NOT apply to is the one hosting the presented
 * Metal layer: its GDI client area is the program's own paint, normally
 * black, and drawing it would cover the game image. Only the app side knows
 * which HWND that is (it is told by the swapchain), so the flush path asks —
 * winios_overlay_skip_hwnd, which answers 0 in desktop mode.
 *
 * MADEIRA_DIRECT_OVERLAY=0 restores the previous behaviour exactly. */
static int winios_direct_overlay(void)
{
    static int on = -1;
    if (on < 0)
    {
        const char *env = getenv( "MADEIRA_DIRECT_OVERLAY" );
        on = !winios_desktop_mode() && !(env && *env == '0');
    }
    return on;
}

/* ml1110 — EVERY "HOW BIG IS THE SCREEN" ROUTE, ONCE, IN ONE LINE.
 *
 * A program that centres its own dialog can read the screen through at least
 * six different APIs, and in a direct launch — where no explorer has ever run —
 * they do not all come from the same place: SM_CXSCREEN and
 * GetDeviceCaps(HORZRES) end at get_primary_monitor_rect(), SPI_GETWORKAREA at
 * a separately cached work area, GetWindowRect(GetDesktopWindow()) at either a
 * per-thread SYNTHESISED monitor rect or the window's STORED rect depending on
 * whether the calling thread has resolved top_window, and MonitorFromPoint +
 * GetMonitorInfo at the monitor list itself. ml1100 healed the list and the
 * work area; ml1090 sized the desktop window asynchronously from a thread that
 * may not own it. Two rounds have now been spent inferring which of those a
 * mis-centred dialog actually read. Print all of them, once, at the moment the
 * first ordinary window appears — which is the state the program's own
 * centring helper runs in — and the next log names the route outright. */
static void winios_log_screen_routes( const char *when )
{
    static int logged;
    struct window_rects desk_rects = {0};
    RECT mon, virt, work = {0};
    HWND desktop;

    if (logged || !winios_direct_overlay()) return;
    logged = 1;

    desktop = get_desktop_window();
    mon = get_primary_monitor_rect( get_thread_dpi() );
    virt = get_virtual_screen_rect( get_thread_dpi(), MDT_DEFAULT );
    NtUserSystemParametersInfo( SPI_GETWORKAREA, 0, &work, 0 );
    get_window_rects( desktop, COORDS_SCREEN, &desk_rects, get_thread_dpi() );

    dprintf( 2, "[screen-routes] ml1110 at=%s SM_CXSCREEN=%d SM_CYSCREEN=%d "
             "SM_CXVIRTUALSCREEN=%d SM_CYVIRTUALSCREEN=%d primary={%d,%d,%d,%d} "
             "virtual={%d,%d,%d,%d} workarea={%d,%d,%d,%d} desktop=%p "
             "desktop-win={%d,%d,%d,%d} desktop-client={%d,%d,%d,%d}%s\n",
             when,
             get_system_metrics( SM_CXSCREEN ), get_system_metrics( SM_CYSCREEN ),
             get_system_metrics( SM_CXVIRTUALSCREEN ), get_system_metrics( SM_CYVIRTUALSCREEN ),
             (int)mon.left, (int)mon.top, (int)mon.right, (int)mon.bottom,
             (int)virt.left, (int)virt.top, (int)virt.right, (int)virt.bottom,
             (int)work.left, (int)work.top, (int)work.right, (int)work.bottom,
             desktop,
             (int)desk_rects.window.left, (int)desk_rects.window.top,
             (int)desk_rects.window.right, (int)desk_rects.window.bottom,
             (int)desk_rects.client.left, (int)desk_rects.client.top,
             (int)desk_rects.client.right, (int)desk_rects.client.bottom,
             IsRectEmpty( &desk_rects.window )
                 ? "  <-- THE DESKTOP WINDOW IS STILL 0x0: every CenterWindow helper that "
                   "reads it lands at (-cx/2,-cy/2)" : "" );
}

/* One [overlay] line for the FIRST window whose GDI content actually reaches
 * the app in a direct launch. Class and size are what identify the window in
 * a device log; the style word says whether it is the dialog/popup shape the
 * overlay exists for. Once per session, so this stays a low-volume family. */
static void winios_overlay_log_first( HWND hwnd, int surf_w, int surf_h )
{
    static int logged;
    struct window_rects rects = {0};
    UNICODE_STRING us;
    WCHAR clsW[64];
    char cls[64];
    int j;

    if (logged || !winios_direct_overlay()) return;
    logged = 1;
    winios_log_screen_routes( "first-window-content" );

    us.Buffer = clsW;
    us.Length = 0;
    us.MaximumLength = sizeof(clsW);
    cls[0] = 0;
    if (NtUserGetClassName( hwnd, FALSE, &us ) > 0)
    {
        for (j = 0; j < us.Length / (int)sizeof(WCHAR) && j < 63; j++)
            cls[j] = (clsW[j] >= 32 && clsW[j] < 127) ? (char)clsW[j] : '?';
        cls[j] = 0;
    }
    get_window_rects( hwnd, COORDS_SCREEN, &rects, get_thread_dpi() );
    dprintf( 2, "[overlay] first window hwnd=%p class='%s' surface=%dx%d "
             "win={%d,%d,%d,%d} style=%08x\n", hwnd, cls, surf_w, surf_h,
             (int)rects.window.left, (int)rects.window.top,
             (int)rects.window.right, (int)rects.window.bottom,
             (unsigned)get_window_long( hwnd, GWL_STYLE ) );
}

/* ml1110 — PER-WINDOW diagnostic budget for the direct-launch overlay.
 *
 * The question these lines answer is always per-WINDOW ("did THIS window's
 * content ever reach a layer, and with what geometry"), so a global counter is
 * the wrong shape: a window created late — the child that covers the client
 * area, the dialog that appears after a minute — falls past any global window
 * and is never sampled at all. That is the ml493 lesson one file over, and it
 * cost a whole round there. Returns the 1-based call number while it is within
 * `max` for this hwnd, 0 afterwards, so every caller is `if (!n) skip`.
 *
 * Lock-free and approximate on purpose: it runs on the GDI flush path. A race
 * can only mis-count a line, never lose the window. */
#define WINIOS_DIAG_SLOTS 16
struct winios_diag_table
{
    struct { HWND hwnd; int n; } slot[WINIOS_DIAG_SLOTS];
    int used;
};
static int winios_overlay_diag_n( struct winios_diag_table *t, HWND hwnd, int max )
{
    int i;

    if (!winios_direct_overlay()) return 0;
    for (i = 0; i < t->used && i < WINIOS_DIAG_SLOTS; i++)
        if (t->slot[i].hwnd == hwnd) return t->slot[i].n < max ? ++t->slot[i].n : 0;
    if (t->used >= WINIOS_DIAG_SLOTS) return 0;
    i = t->used++;
    t->slot[i].hwnd = hwnd;
    t->slot[i].n = 1;
    return 1;
}

/* ml1110 — THE LINE THAT DECIDES "WHY IS THE CLIENT AREA BLANK".
 *
 * A direct launch has no window manager and no desktop compositor, so between
 * "the program painted" and "pixels on screen" there are four places the
 * content can be lost, and no log so far could tell them apart:
 *
 *   1. the window is a CHILD and has no surface of its own — it paints into an
 *      ancestor's, and only that ancestor ever flushes (surface=... here names
 *      the owner, `child=1 own-surface=0` names the case);
 *   2. the surface is SMALLER than the window, because get_surface_rect()
 *      cropped it to the virtual screen — the rows past `surf` are bits win32u
 *      never allocated and nothing downstream can show them;
 *   3. the dirty rect the program damaged lies wholly or partly OUTSIDE that
 *      surface, so the flush carries nothing (dirty vs clipped below);
 *   4. the client rect is not where the layer thinks it is.
 *
 * All four are printed together, first few flushes per window, direct launch
 * only — so one device log settles which it is without another round. */
static void winios_overlay_log_flush( struct window_surface *surface, const RECT *dirty )
{
    static struct winios_diag_table flush_diag;
    struct window_rects rects = {0};
    RECT surf, clipped, client_local;
    HWND hwnd = surface->hwnd, parent;
    UINT style, ex_style;
    int n, is_child;

    if (!(n = winios_overlay_diag_n( &flush_diag, hwnd, 3 ))) return;

    surf = surface->rect;
    parent = NtUserGetAncestor( hwnd, GA_PARENT );
    is_child = parent && parent != get_desktop_window();
    style = get_window_long( hwnd, GWL_STYLE );
    ex_style = get_window_long( hwnd, GWL_EXSTYLE );
    get_window_rects( hwnd, COORDS_SCREEN, &rects, get_thread_dpi() );

    clipped = *dirty;
    if (!intersect_rect( &clipped, &clipped, &surf )) SetRectEmpty( &clipped );

    /* The client area in the SAME window-local space the surface rect uses —
     * the only way to read "does the surface reach the bottom of the client". */
    client_local = rects.client;
    OffsetRect( &client_local, -rects.visible.left, -rects.visible.top );

    dprintf( 2, "[overlay-flush] #%d hwnd=%p parent=%p child=%d own-surface=1 "
             "style=%08x ex=%08x win={%d,%d,%d,%d} client={%d,%d,%d,%d} "
             "visible={%d,%d,%d,%d} surf={%d,%d,%d,%d} client-local={%d,%d,%d,%d} "
             "dirty={%d,%d,%d,%d} -> clipped={%d,%d,%d,%d}%s%s rev=ml1110\n",
             n, hwnd, parent, is_child, (unsigned)style, (unsigned)ex_style,
             (int)rects.window.left, (int)rects.window.top,
             (int)rects.window.right, (int)rects.window.bottom,
             (int)rects.client.left, (int)rects.client.top,
             (int)rects.client.right, (int)rects.client.bottom,
             (int)rects.visible.left, (int)rects.visible.top,
             (int)rects.visible.right, (int)rects.visible.bottom,
             (int)surf.left, (int)surf.top, (int)surf.right, (int)surf.bottom,
             (int)client_local.left, (int)client_local.top,
             (int)client_local.right, (int)client_local.bottom,
             (int)dirty->left, (int)dirty->top, (int)dirty->right, (int)dirty->bottom,
             (int)clipped.left, (int)clipped.top, (int)clipped.right, (int)clipped.bottom,
             IsRectEmpty( &clipped ) ? "  <-- DAMAGE ENTIRELY OUTSIDE THE SURFACE" : "",
             (client_local.bottom > surf.bottom || client_local.right > surf.right)
                 ? "  <-- SURFACE DOES NOT COVER THE WHOLE CLIENT (cropped to the virtual screen)" : "" );
}

/* ml505 probe. This hook was a pure stub: wine hands the driver the
 * surface's VISIBLE REGION here — the rects left after sibling and child
 * occlusion — and we discarded all of it.
 *
 * That matters now. The Steam login window has THREE full-size children
 * (0x1011c/0x10122/0x10136), all WS_CLIPSIBLINGS, all at the parent's exact
 * rect, and none of them presents: they all paint into the parent's ONE
 * surface. If sibling clipping is not being applied, each paints the whole
 * rect in turn and the surface flips between whatever each draws — which is
 * exactly the two-state alternation measured in ml503/ml504.
 *
 * So log what wine actually computes. count==0 with no rects means "fully
 * visible, no clipping"; a real region means clipping IS being computed and
 * the fault lies elsewhere. Either answer narrows it. */
static void winios_surface_set_clip( struct window_surface *surface, const RECT *rects, UINT count )
{
    static unsigned clip_calls;
    unsigned n = ++clip_calls;
    if (n <= 64 || (n % 256) == 0)
    {
        dprintf( 2, "[surf-clip] #%u surface=%p hwnd=%p count=%u%s rev=ml505\n",
                 n, surface, surface ? surface->hwnd : NULL, count,
                 count ? "" : "  (NO CLIP = fully visible)" );
        for (UINT i = 0; i < count && i < 6; i++)
            dprintf( 2, "[surf-clip]    rect[%u] = {%d,%d,%d,%d}\n", i,
                     (int)rects[i].left, (int)rects[i].top,
                     (int)rects[i].right, (int)rects[i].bottom );
    }
}

static BOOL winios_surface_flush( struct window_surface *surface, const RECT *rect, const RECT *dirty,
                                  const BITMAPINFO *color_info, const void *color_bits, BOOL shape_changed,
                                  const BITMAPINFO *shape_info, const void *shape_bits )
{
    /* ml505: attribute the paint. All three children share this ONE surface,
     * so if they paint on different threads the mach thread id separates
     * them — and a single thread painting alternating content rules the
     * sibling theory out just as firmly. */
    {
        static unsigned fl_n;
        unsigned n = ++fl_n;
        if (n <= 200 || (n % 200) == 0)
            dprintf( 2, "[surf-flush] #%u surface=%p hwnd=%p mach_tid=%u "
                     "rect={%d,%d,%d,%d} dirty={%d,%d,%d,%d} rev=ml505\n",
                     n, surface, surface ? surface->hwnd : NULL,
                     (unsigned)pthread_mach_thread_np( pthread_self() ),
                     (int)rect->left, (int)rect->top, (int)rect->right, (int)rect->bottom,
                     (int)dirty->left, (int)dirty->top, (int)dirty->right, (int)dirty->bottom );
    }

    if (winios_surface_present && color_bits)
    {
        int surf_w = color_info->bmiHeader.biWidth;
        int surf_h = color_info->bmiHeader.biHeight;
        if (surf_h < 0) surf_h = -surf_h;
        /* Direct launch: never hand the app the GDI surface of the window
         * that hosts the presented Metal layer — see winios_direct_overlay.
         * Answers 0 in desktop mode, so nothing changes there. */
        if (winios_overlay_skip_hwnd && winios_overlay_skip_hwnd( surface->hwnd )) return TRUE;
        winios_overlay_log_first( surface->hwnd, surf_w, surf_h );
        winios_overlay_log_flush( surface, dirty );
        /* ml1028: propagate the snapshot allocation result. dce.c only calls
         * reset_bounds() when we return TRUE, so returning FALSE keeps the
         * dirty region and the frame is repainted on a later flush instead of
         * the copy throwing an uncaught ObjC exception and killing us. */
        if (!winios_surface_present( surface->hwnd,
                                     dirty->left, dirty->top,
                                     dirty->right - dirty->left, dirty->bottom - dirty->top,
                                     surf_w, surf_h, surf_w * 4, color_bits ))
            return FALSE;
    }
    return TRUE;
}

static void winios_surface_destroy( struct window_surface *surface )
{
    /* Layer teardown happens on pDestroyWindow, not here — surfaces are
     * recreated on every resize and dropping the layer would flicker. */
}

static const struct window_surface_funcs winios_surface_funcs =
{
    winios_surface_set_clip,
    winios_surface_flush,
    winios_surface_destroy
};

static BOOL winios_CreateWindowSurface( HWND hwnd, BOOL layered, const RECT *surface_rect,
                                        struct window_surface **window_surface )
{
    char buffer[FIELD_OFFSET( BITMAPINFO, bmiColors[256] )];
    BITMAPINFO *info = (BITMAPINFO *)buffer;
    struct window_surface *previous;

    /* ml1090: NEVER give the DESKTOP window a surface in a direct launch.
     *
     * The desktop window is now sized to the virtual screen even without a
     * shell (winstation_ios.c, [desktop-rect]) so that every CenterWindow
     * helper and DS_CENTER dialog has a screen to centre on. A screen-sized
     * window with a GDI surface is a screen-sized opaque backdrop, and the
     * overlay would draw it straight over the presented game image — the
     * exact failure winios_ensure_compositor refuses to allow in this mode.
     * The desktop is a coordinate system here, never a painted surface. */
    if (winios_direct_overlay() && hwnd == get_desktop_window()) return FALSE;

    if ((previous = *window_surface) && previous->funcs == &winios_surface_funcs
        && EqualRect( &previous->rect, surface_rect )) return TRUE;

    memset( info, 0, sizeof(*info) );
    info->bmiHeader.biSize        = sizeof(info->bmiHeader);
    info->bmiHeader.biWidth       = surface_rect->right;
    info->bmiHeader.biHeight      = -surface_rect->bottom; /* top-down */
    info->bmiHeader.biPlanes      = 1;
    info->bmiHeader.biBitCount    = 32;
    info->bmiHeader.biSizeImage   = surface_rect->right * surface_rect->bottom * 4;
    info->bmiHeader.biCompression = BI_RGB;

    *window_surface = window_surface_create( sizeof(struct window_surface), &winios_surface_funcs,
                                             hwnd, surface_rect, info, 0 );

    /* ml750: window_surface_create() returns NULL when the backing DIB
     * cannot be allocated. Dropping `previous` then leaves the window with
     * NO surface at all: nothing ever flushes, so the window is invisible
     * for the rest of its life even though it is WS_VISIBLE and on the
     * taskbar. Keep whatever the window already had and say so loudly --
     * a stale surface still paints, a NULL one never can. */
    if (!*window_surface)
    {
        static unsigned fail_n;
        dprintf( 2, "[surf-create] #%u hwnd=%p rect={%d,%d,%d,%d} bytes=%u "
                 "ALLOCATION FAILED -- keeping previous surface %p (window would be invisible) rev=ml750\n",
                 ++fail_n, hwnd, (int)surface_rect->left, (int)surface_rect->top,
                 (int)surface_rect->right, (int)surface_rect->bottom,
                 (unsigned)info->bmiHeader.biSizeImage, previous );
        *window_surface = previous;
        return TRUE;
    }

    if (previous) window_surface_release( previous );

    /* ml1110: tell the app side WHERE in the window these bits live, before
     * any flush of this surface can reach it — see the extern's own comment.
     * Both modes: the crop is not direct-launch-specific, and desktop mode's
     * per-window layers scale the same contents the same way. */
    if (winios_window_surface_rect)
        winios_window_surface_rect( hwnd, (int)surface_rect->left, (int)surface_rect->top,
                                    (int)surface_rect->right, (int)surface_rect->bottom );

    {
        /* ml505: was capped at 16 GLOBALLY, so a window created late (the
         * login popup) never appeared here at all. Which hwnds get their own
         * surface — and which do not — is exactly the question: children that
         * never get one are painting into their parent's. */
        static unsigned cnt;
        unsigned n = ++cnt;
        if (n <= 96 || (n % 64) == 0)
            dprintf( 2, "[surf-create] #%u hwnd=%p rect={%d,%d,%d,%d} layered=%d "
                     "prev=%p -> %p%s rev=ml505\n",
                     n, hwnd, (int)surface_rect->left, (int)surface_rect->top,
                     (int)surface_rect->right, (int)surface_rect->bottom, layered,
                     previous, *window_surface,
                     previous ? "  (RECREATED — old content dropped)" : "  (first)" );
    }
    return TRUE;
}

/* pWindowPosChanged wrapper: dereference window_rects HERE (Winios.m
 * cannot include wine headers) and forward plain ints for the layer
 * frame; chain to the Winios.m hook afterwards. */
static void winios_drv_window_pos_changed( HWND hwnd, HWND insert_after, HWND owner_hint, UINT swp_flags,
                                           const struct window_rects *new_rects, struct window_surface *surface )
{
    /* Desktop mode: the full-screen compositor. Direct launch: the
     * transparent overlay inside the presented layer (winios_direct_overlay).
     * Neither wakes the desktop compositor outside desktop mode — the app
     * side keeps that gate, so its backdrop can still never cover a game. */
    if (winios_window_frame && (winios_desktop_mode() || winios_direct_overlay()))
    {
        RECT vr = new_rects->visible, cr = new_rects->client;
        const RECT *v = &vr, *c = &cr;
        int visible = !IsRectEmpty( v ) && !(swp_flags & SWP_HIDEWINDOW);
        /* ml1690: a CHILD window's rects arrive in its parent's client
         * coordinates, but every window layer is a sibling under the one
         * compositor root, framed in desktop pixels. So a child with its own
         * layer -- the embedded browser view of a sign-in dialog, drawn through
         * a swapchain -- was placed at the desktop's origin instead of inside
         * its dialog. Map child rects to the desktop first.
         * MADEIRA_CHILD_LAYER_SCREEN=0 restores parent-relative placement. */
        {
            static int enabled = -1;
            HWND parent = NtUserGetAncestor( hwnd, GA_PARENT );
            if (enabled < 0) { const char *e = getenv( "MADEIRA_CHILD_LAYER_SCREEN" ); enabled = !(e && e[0] == '0'); }
            if (enabled && parent && parent != get_desktop_window())
            {
                UINT dpi = get_thread_dpi();
                map_window_points( parent, 0, (POINT *)&vr, 2, dpi );
                map_window_points( parent, 0, (POINT *)&cr, 2, dpi );
            }
        }
        winios_window_frame( hwnd, v->left, v->top, v->right - v->left, v->bottom - v->top, visible,
                             c->left, c->top, c->right - c->left, c->bottom - c->top );

        /* ml1690: children do not get a WindowPosChanged when only their parent
         * moves (their parent-relative rects are unchanged), so their layers
         * would stay where the dialog used to be. Re-send the direct children's
         * desktop rects whenever a top-level window moves or resizes. */
        if (!(swp_flags & SWP_NOMOVE) || !(swp_flags & SWP_NOSIZE))
        {
            HWND parent = NtUserGetAncestor( hwnd, GA_PARENT );
            const char *e = getenv( "MADEIRA_CHILD_LAYER_SCREEN" );
            if (!(e && e[0] == '0') && (!parent || parent == get_desktop_window()))
            {
                HWND *list = list_window_children( hwnd );
                UINT dpi = get_thread_dpi();
                int i;
                for (i = 0; list && list[i] && i < 64; i++)
                {
                    RECT wr, cl;
                    DWORD style = NtUserGetWindowLongW( list[i], GWL_STYLE );
                    if (!NtUserGetWindowRect( list[i], &wr, dpi ) || !NtUserGetClientRect( list[i], &cl, dpi )) continue;
                    map_window_points( list[i], 0, (POINT *)&cl, 2, dpi );
                    winios_window_frame( list[i], wr.left, wr.top, wr.right - wr.left, wr.bottom - wr.top,
                                         (style & WS_VISIBLE) && !IsRectEmpty( &wr ),
                                         cl.left, cl.top, cl.right - cl.left, cl.bottom - cl.top );
                    {
                        static unsigned logged;
                        if (logged < 60)
                        {
                            logged++;
                            dprintf( 2, "[child-layer] ml1730 parent=%p flags=%#x child=%p window={%d,%d,%d,%d} "
                                        "client={%d,%d,%d,%d} vis=%d\n", hwnd, swp_flags, list[i],
                                     (int)wr.left, (int)wr.top, (int)wr.right, (int)wr.bottom,
                                     (int)cl.left, (int)cl.top, (int)cl.right, (int)cl.bottom,
                                     (style & WS_VISIBLE) ? 1 : 0 );
                        }
                    }
                }
                free( list );
            }
        }
    }

    /* ml1110 — THE OTHER HALF OF "WHY IS THE CLIENT AREA BLANK": the windows
     * that never flush at all. A CHILD window gets NO surface of its own
     * (get_default_window_surface returns NULL for it and the caller falls back
     * to the parent's), so it paints into an ancestor's bits and the only trace
     * it ever leaves is this hook. The existing [win-pos] family deliberately
     * drops children with an empty visible rect — which is exactly the shape a
     * client-covering paint-box child can have here — so a child could get an
     * overlay layer created for it and appear in no other line in the log.
     * First two events per window, direct launch only; `surface=(none)` is the
     * "paints into an ancestor's surface" case stated outright. */
    {
        static struct winios_diag_table pos_diag;
        int n = winios_overlay_diag_n( &pos_diag, hwnd, 4 );
        if (n)
        {
            /* First window event in a direct launch: the state every
             * self-centring dialog is about to read. */
            winios_log_screen_routes( "first-window-event" );
            const RECT *v = &new_rects->visible, *w = &new_rects->window, *c = &new_rects->client;
            HWND parent = NtUserGetAncestor( hwnd, GA_PARENT );
            int is_child = parent && parent != get_desktop_window();
            dprintf( 2, "[overlay-win] #%d hwnd=%p parent=%p child=%d style=%08x ex=%08x "
                     "after=%p swp=%08x win={%d,%d,%d,%d} client={%d,%d,%d,%d} "
                     "visible={%d,%d,%d,%d} surface=%s rev=ml1110\n",
                     n, hwnd, parent, is_child,
                     (unsigned)get_window_long( hwnd, GWL_STYLE ),
                     (unsigned)get_window_long( hwnd, GWL_EXSTYLE ),
                     insert_after, (unsigned)swp_flags,
                     (int)w->left, (int)w->top, (int)w->right, (int)w->bottom,
                     (int)c->left, (int)c->top, (int)c->right, (int)c->bottom,
                     (int)v->left, (int)v->top, (int)v->right, (int)v->bottom,
                     surface ? "own" : "(none) — paints into an ancestor's surface" );
        }
    }
    /* ml505: z-order and geometry churn. If the three same-rect siblings are
     * being reordered, the topmost changes and the surface shows whichever
     * painted last — an alternation with no Chromium involvement at all.
     * insert_after names the z-order move; surface tells us which windows
     * share one. Skip empty rects (the 1x1 IME/message windows) so the
     * signal is not buried. */
    if (!IsRectEmpty( &new_rects->visible ))
    {
        static unsigned pos_n;
        unsigned n = ++pos_n;
        /* ml529: 200 was too tight — the Steam login popup's events land at
         * #190-200, i.e. exactly where the log ran out, which made a
         * swp=0 signature indistinguishable from absence. */
        if (n <= 1200 || (n % 128) == 0)
        {
            const RECT *v = &new_rects->visible;
            dprintf( 2, "[win-pos] #%u hwnd=%p after=%p flags=%08x vis={%d,%d,%d,%d} "
                     "surface=%p rev=ml505\n", n, hwnd, insert_after, (unsigned)swp_flags,
                     (int)v->left, (int)v->top, (int)v->right, (int)v->bottom, surface );
            /* ml853: name the window. A dialog nobody can see (nothing is
             * presenting) is otherwise just a rectangle; the class and the
             * text of every window, children included, make it readable
             * from the log. Static controls carry a message box's body. */
            {
                WCHAR clsW[64], txtW[200];
                char cls[64], txt[200];
                UNICODE_STRING us = { 0, sizeof(clsW), clsW };
                int j, tn;
                cls[0] = 0;
                if (NtUserGetClassName( hwnd, FALSE, &us ) > 0)
                {
                    for (j = 0; j < us.Length / (int)sizeof(WCHAR) && j < 63; j++)
                        cls[j] = (clsW[j] >= 32 && clsW[j] < 127) ? (char)clsW[j] : '?';
                    cls[j] = 0;
                }
                tn = NtUserInternalGetWindowText( hwnd, txtW, ARRAY_SIZE(txtW) );
                for (j = 0; j < tn && j < 199; j++)
                    txt[j] = (txtW[j] >= 32 && txtW[j] < 127) ? (char)txtW[j] : '?';
                txt[j] = 0;
                if (cls[0] || txt[0])
                    dprintf( 2, "[win-name] #%u hwnd=%p class='%s' text=\"%s\" rev=ml853\n", n, hwnd, cls, txt );
            }
        }
    }
    /* ml750: an EMPTY visible rect used to be filtered out here (to keep the
     * 1x1 IME/message windows from burying the signal) -- which is precisely
     * why a top-level window collapsing to 0x0 left NO trace in the log at
     * all: [win-pos] fell silent, the compositor got a zero frame, and the
     * only surviving evidence was a 128x128 surface (get_surface_rect()
     * clamps an empty rect up to the 128px minimum) and a zero-size Metal
     * layer. Degenerate rects are rare and always interesting, so log them
     * unconditionally, with the window rect and style that produced them. */
    else
    {
        /* ml780: an empty visible rect fires constantly for ordinary
         * zero-size CHILD controls (e.g. a toolbar/rebar child window with
         * no area) -- 40+ lines per session with no diagnostic value. Only
         * a top-level window collapsing to 0x0 is interesting, so gate the
         * whole diagnostic on "no WS_CHILD" before even touching the
         * throttle counter. */
        UINT style = get_window_long( hwnd, GWL_STYLE );
        if (!(style & WS_CHILD) && (style & WS_VISIBLE))
        {
            static unsigned degen_n;
            unsigned n = ++degen_n;
            if (n <= 64 || (n % 64) == 0)
            {
                const RECT *w = &new_rects->window, *c = &new_rects->client;
                dprintf( 2, "[win-pos] #d%u hwnd=%p after=%p flags=%08x vis=EMPTY "
                         "win={%d,%d,%d,%d} client={%d,%d,%d,%d} style=%08x surface=%p"
                         "%s rev=ml750\n",
                         n, hwnd, insert_after, (unsigned)swp_flags,
                         (int)w->left, (int)w->top, (int)w->right, (int)w->bottom,
                         (int)c->left, (int)c->top, (int)c->right, (int)c->bottom,
                         (unsigned)style, surface,
                         (style & WS_VISIBLE) ? "  <-- DEGENERATE, WS_VISIBLE: nothing can be shown" : "" );

                /* A WS_VISIBLE top-level window with no area almost always means
                 * the application sized itself from a display query that came back
                 * empty. Print what this driver would have told it, so the next log
                 * says immediately whether the geometry the application read was
                 * wrong or whether it invented the zero itself. */
                HWND parent = NtUserGetAncestor( hwnd, GA_PARENT );
                if ((style & WS_VISIBLE) && (!parent || parent == get_desktop_window()))
                {
                    RECT mon = get_primary_monitor_rect( get_thread_dpi() );
                    RECT virt = get_virtual_screen_rect( get_thread_dpi(), MDT_DEFAULT );
                    dprintf( 2, "[win-pos] #d%u    driver would report: primary monitor={%d,%d,%d,%d} "
                             "virtual screen={%d,%d,%d,%d} rev=ml750\n", n,
                             (int)mon.left, (int)mon.top, (int)mon.right, (int)mon.bottom,
                             (int)virt.left, (int)virt.top, (int)virt.right, (int)virt.bottom );
                }
            }
        }
    }

    /* iOS: synthesize the expose/damage-driven repaint a real windowing system
     * delivers. Every other display driver gets an Expose (x11drv), a
     * drawRect/needsDisplay (macdrv) or a damage event when a window becomes
     * visible or when its backing surface is (re)created, and answers it with
     * NtUserRedrawWindow( RDW_INVALIDATE ) — that is what puts the window's
     * update region into the server, which is the ONLY source of the queue's
     * QS_PAINT bit and therefore of WM_PAINT (server get_message only reports
     * WM_PAINT while queue->paint_count is non-zero).
     *
     * winios.drv has no such event: the surface IS the presented buffer. So
     * nothing ever asked the application to paint, and a window whose contents
     * the runtime just dropped stayed empty forever. Two cases hit this:
     *   - the show path took a route that carries SWP_NOREDRAW (the server then
     *     skips expose_window() and the frame/client invalidation entirely, see
     *     window.c set_window_pos: `if (swp_flags & SWP_NOREDRAW) goto done`),
     *     e.g. when ShowWindow() degenerates to a WS_VISIBLE style toggle plus
     *     update_window_state() because the parent looks invisible;
     *   - CreateWindowSurface replaced the surface ("RECREATED — old content
     *     dropped" above): the new buffer is blank and only the application can
     *     refill it.
     * apply_window_pos() already computes exactly the signal we need:
     * SWP_FRAMECHANGED is forced whenever the surface pointer changed, and
     * SWP_SHOWWINDOW marks the window going visible.
     *
     * Surface-less windows (GPU/client-surface presented, e.g. the D3D path)
     * are deliberately left alone: they do not paint through GDI. */
    if (surface && !IsRectEmpty( &new_rects->visible ) && !(swp_flags & SWP_HIDEWINDOW) &&
        (swp_flags & (SWP_SHOWWINDOW | SWP_FRAMECHANGED)) &&
        (get_window_long( hwnd, GWL_STYLE ) & WS_VISIBLE))
    {
        /* MADEIRA-TEMP: one line per newly shown surface-backed window, to
         * settle WHY the show path carried SWP_NOREDRAW. A window that reaches
         * here WITHOUT SWP_SHOWWINDOW was made visible by the WS_VISIBLE style
         * toggle in show_window() (window.c:4855-4859), which happens only when
         * is_window_visible(parent) is FALSE — parent_vis/parent_style/parent
         * vs desktop/msgwin below say which of the three possible reasons it is
         * (parent is the message window, parent handle is unresolvable, or the
         * desktop style query failed). Remove once diagnosed. */
        if (!(swp_flags & SWP_SHOWWINDOW))
        {
            static unsigned diag_n;
            if (diag_n++ < 8)
            {
                /* ml1090: RESOLVE THE DESKTOP FIRST, IN ITS OWN STATEMENT.
                 *
                 * get_win_ptr() only maps a handle to WND_DESKTOP when
                 * is_desktop_window() says so, and that test reads THIS
                 * THREAD's thread_info->top_window — which get_desktop_window()
                 * is what fills in. As one argument list the evaluation order
                 * is unspecified, and clang evaluated the style query first: on
                 * a thread that had not yet resolved the desktop, log 77 printed
                 * parent=0x10020 desktop=0x10020 parent_style=00000000
                 * parent_vis=0 — the same handle answered as "the desktop" and
                 * as a style-less foreign window in one line, which cost real
                 * time to disbelieve. */
                HWND desktop = get_desktop_window();
                HWND msgwin = get_hwnd_message_parent();
                HWND parent = NtUserGetAncestor( hwnd, GA_PARENT );
                DWORD parent_style = get_window_long( parent, GWL_STYLE );
                BOOL parent_vis = is_window_visible( parent );

                dprintf( 2, "MADEIRA-TEMP [paint-diag] hwnd=%p swp=%08x parent=%p desktop=%p "
                         "msgwin=%p parent_style=%08x parent_vis=%d\n", hwnd, (unsigned)swp_flags,
                         parent, desktop, msgwin, (unsigned)parent_style, parent_vis );
            }
        }
        NtUserRedrawWindow( hwnd, NULL, 0, RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN );
    }

    if (winios_pWindowPosChanged)
        winios_pWindowPosChanged( hwnd, insert_after, owner_hint, swp_flags, new_rects, surface );
}
#endif

static INT nulldrv_AbortDoc( PHYSDEV dev )
{
    return 0;
}

static BOOL nulldrv_Arc( PHYSDEV dev, INT left, INT top, INT right, INT bottom,
                         INT xstart, INT ystart, INT xend, INT yend )
{
    return TRUE;
}

static BOOL nulldrv_Chord( PHYSDEV dev, INT left, INT top, INT right, INT bottom,
                           INT xstart, INT ystart, INT xend, INT yend )
{
    return TRUE;
}

static BOOL nulldrv_CreateCompatibleDC( PHYSDEV orig, PHYSDEV *pdev )
{
    if (!user_driver->dc_funcs.pCreateCompatibleDC) return TRUE;
    return user_driver->dc_funcs.pCreateCompatibleDC( NULL, pdev );
}

static BOOL nulldrv_CreateDC( PHYSDEV *dev, LPCWSTR device, LPCWSTR output,
                              const DEVMODEW *devmode )
{
    assert(0);  /* should never be called */
    return FALSE;
}

static BOOL nulldrv_DeleteDC( PHYSDEV dev )
{
    assert(0);  /* should never be called */
    return TRUE;
}

static BOOL nulldrv_DeleteObject( PHYSDEV dev, HGDIOBJ obj )
{
    return TRUE;
}

static BOOL nulldrv_Ellipse( PHYSDEV dev, INT left, INT top, INT right, INT bottom )
{
    return TRUE;
}

static INT nulldrv_EndDoc( PHYSDEV dev )
{
    return 0;
}

static INT nulldrv_EndPage( PHYSDEV dev )
{
    return 0;
}

static BOOL nulldrv_EnumFonts( PHYSDEV dev, LOGFONTW *logfont, font_enum_proc proc, LPARAM lParam )
{
    return TRUE;
}

static INT nulldrv_ExtEscape( PHYSDEV dev, INT escape, INT in_size, const void *in_data,
                              INT out_size, void *out_data )
{
    return 0;
}

static BOOL nulldrv_ExtFloodFill( PHYSDEV dev, INT x, INT y, COLORREF color, UINT type )
{
    return TRUE;
}

static BOOL nulldrv_FontIsLinked( PHYSDEV dev )
{
    return FALSE;
}

static UINT nulldrv_GetBoundsRect( PHYSDEV dev, RECT *rect, UINT flags )
{
    return DCB_RESET;
}

static BOOL nulldrv_GetCharABCWidths( PHYSDEV dev, UINT first, UINT count, WCHAR *chars, ABC *abc )
{
    return FALSE;
}

static BOOL nulldrv_GetCharABCWidthsI( PHYSDEV dev, UINT first, UINT count, WORD *indices, LPABC abc )
{
    return FALSE;
}

static BOOL nulldrv_GetCharWidth( PHYSDEV dev, UINT first, UINT count,
                                  const WCHAR *chars, INT *buffer )
{
    return FALSE;
}

static BOOL nulldrv_GetCharWidthInfo( PHYSDEV dev, void *info )
{
    return FALSE;
}

static INT nulldrv_GetDeviceCaps( PHYSDEV dev, INT cap )
{
    int bpp;

    switch (cap)
    {
    case DRIVERVERSION:   return 0x4000;
    case TECHNOLOGY:      return DT_RASDISPLAY;
    case HORZSIZE:        return muldiv( NtGdiGetDeviceCaps( dev->hdc, HORZRES ), 254,
                                         NtGdiGetDeviceCaps( dev->hdc, LOGPIXELSX ) * 10 );
    case VERTSIZE:        return muldiv( NtGdiGetDeviceCaps( dev->hdc, VERTRES ), 254,
                                         NtGdiGetDeviceCaps( dev->hdc, LOGPIXELSY ) * 10 );
    case HORZRES:
    {
        DC *dc = get_nulldrv_dc( dev );
        RECT rect;
        int ret;

        if (dc->display[0])
        {
            rect = get_display_rect( dc->display );
            if (!IsRectEmpty( &rect )) return rect.right - rect.left;
        }

        ret = get_system_metrics( SM_CXSCREEN );
        return ret ? ret : 640;
    }
    case VERTRES:
    {
        DC *dc = get_nulldrv_dc( dev );
        RECT rect;
        int ret;

        if (dc->display[0])
        {
            rect = get_display_rect( dc->display );
            if (!IsRectEmpty( &rect )) return rect.bottom - rect.top;
        }

        ret = get_system_metrics( SM_CYSCREEN );
        return ret ? ret : 480;
    }
    case BITSPIXEL:
    {
        UNICODE_STRING display;
        DC *dc;

        if (NtGdiGetDeviceCaps( dev->hdc, TECHNOLOGY ) == DT_RASDISPLAY)
        {
            dc = get_nulldrv_dc( dev );
            RtlInitUnicodeString( &display, dc->display );
            return get_display_depth( &display );
        }
        return 32;
    }
    case PLANES:          return 1;
    case NUMBRUSHES:      return -1;
    case NUMPENS:         return -1;
    case NUMMARKERS:      return 0;
    case NUMFONTS:        return 0;
    case PDEVICESIZE:     return 0;
    case CURVECAPS:       return (CC_CIRCLES | CC_PIE | CC_CHORD | CC_ELLIPSES | CC_WIDE |
                                  CC_STYLED | CC_WIDESTYLED | CC_INTERIORS | CC_ROUNDRECT);
    case LINECAPS:        return (LC_POLYLINE | LC_MARKER | LC_POLYMARKER | LC_WIDE |
                                  LC_STYLED | LC_WIDESTYLED | LC_INTERIORS);
    case POLYGONALCAPS:   return (PC_POLYGON | PC_RECTANGLE | PC_WINDPOLYGON | PC_SCANLINE |
                                  PC_WIDE | PC_STYLED | PC_WIDESTYLED | PC_INTERIORS);
    case TEXTCAPS:        return (TC_OP_CHARACTER | TC_OP_STROKE | TC_CP_STROKE |
                                  TC_CR_ANY | TC_SF_X_YINDEP | TC_SA_DOUBLE | TC_SA_INTEGER |
                                  TC_SA_CONTIN | TC_UA_ABLE | TC_SO_ABLE | TC_RA_ABLE | TC_VA_ABLE);
    case CLIPCAPS:        return CP_RECTANGLE;
    case RASTERCAPS:      return (RC_BITBLT | RC_BITMAP64 | RC_GDI20_OUTPUT | RC_DI_BITMAP | RC_DIBTODEV |
                                  RC_BIGFONT | RC_STRETCHBLT | RC_FLOODFILL | RC_STRETCHDIB | RC_DEVBITS |
                                  (NtGdiGetDeviceCaps( dev->hdc, SIZEPALETTE ) ? RC_PALETTE : 0));
    case ASPECTX:         return 36;
    case ASPECTY:         return 36;
    case ASPECTXY:        return (int)(hypot( NtGdiGetDeviceCaps( dev->hdc, ASPECTX ),
                                              NtGdiGetDeviceCaps( dev->hdc, ASPECTY )) + 0.5);
    case CAPS1:           return 0;
    case SIZEPALETTE:     return 0;
    case NUMRESERVED:     return 20;
    case PHYSICALWIDTH:   return 0;
    case PHYSICALHEIGHT:  return 0;
    case PHYSICALOFFSETX: return 0;
    case PHYSICALOFFSETY: return 0;
    case SCALINGFACTORX:  return 0;
    case SCALINGFACTORY:  return 0;
    case VREFRESH:
    {
        UNICODE_STRING display;
        DEVMODEW devmode;
        DC *dc;

        if (NtGdiGetDeviceCaps( dev->hdc, TECHNOLOGY ) != DT_RASDISPLAY)
            return 0;

        dc = get_nulldrv_dc( dev );

        memset( &devmode, 0, sizeof(devmode) );
        devmode.dmSize = sizeof(devmode);
        RtlInitUnicodeString( &display, dc->display );
        if (NtUserEnumDisplaySettings( &display, ENUM_CURRENT_SETTINGS, &devmode, 0 ) &&
            devmode.dmDisplayFrequency)
            return devmode.dmDisplayFrequency;
        return 1;
    }
    case DESKTOPHORZRES:
        if (NtGdiGetDeviceCaps( dev->hdc, TECHNOLOGY ) == DT_RASDISPLAY)
        {
            RECT rect = get_virtual_screen_rect( 0, MDT_DEFAULT );
            return rect.right - rect.left;
        }
        return NtGdiGetDeviceCaps( dev->hdc, HORZRES );
    case DESKTOPVERTRES:
        if (NtGdiGetDeviceCaps( dev->hdc, TECHNOLOGY ) == DT_RASDISPLAY)
        {
            RECT rect = get_virtual_screen_rect( 0, MDT_DEFAULT );
            return rect.bottom - rect.top;
        }
        return NtGdiGetDeviceCaps( dev->hdc, VERTRES );
    case BLTALIGNMENT:    return 0;
    case SHADEBLENDCAPS:  return 0;
    case COLORMGMTCAPS:   return 0;
    case LOGPIXELSX:
    case LOGPIXELSY:      return get_system_dpi();
    case NUMCOLORS:
        bpp = NtGdiGetDeviceCaps( dev->hdc, BITSPIXEL );
        /* Newer versions of Windows return -1 for 8-bit and higher */
        return (bpp > 4) ? -1 : (1 << bpp);
    case COLORRES:
        /* The observed correspondence between BITSPIXEL and COLORRES is:
         * BITSPIXEL: 8  -> COLORRES: 18
         * BITSPIXEL: 16 -> COLORRES: 16
         * BITSPIXEL: 24 -> COLORRES: 24
         * BITSPIXEL: 32 -> COLORRES: 24 */
        bpp = NtGdiGetDeviceCaps( dev->hdc, BITSPIXEL );
        return (bpp <= 8) ? 18 : min( 24, bpp );
    default:
        FIXME("(%p): unsupported capability %d, will return 0\n", dev->hdc, cap );
        return 0;
    }
}

static BOOL nulldrv_GetDeviceGammaRamp( PHYSDEV dev, void *ramp )
{
    RtlSetLastWin32Error( ERROR_INVALID_PARAMETER );
    return FALSE;
}

static DWORD nulldrv_GetFontData( PHYSDEV dev, DWORD table, DWORD offset, LPVOID buffer, DWORD length )
{
    return FALSE;
}

static BOOL nulldrv_GetFontRealizationInfo( PHYSDEV dev, void *info )
{
    return FALSE;
}

static DWORD nulldrv_GetFontUnicodeRanges( PHYSDEV dev, LPGLYPHSET glyphs )
{
    return 0;
}

static DWORD nulldrv_GetGlyphIndices( PHYSDEV dev, LPCWSTR str, INT count, LPWORD indices, DWORD flags )
{
    return GDI_ERROR;
}

static DWORD nulldrv_GetGlyphOutline( PHYSDEV dev, UINT ch, UINT format, LPGLYPHMETRICS metrics,
                                      DWORD size, LPVOID buffer, const MAT2 *mat )
{
    return GDI_ERROR;
}

static DWORD nulldrv_GetImage( PHYSDEV dev, BITMAPINFO *info, struct gdi_image_bits *bits,
                               struct bitblt_coords *src )
{
    return ERROR_NOT_SUPPORTED;
}

static DWORD nulldrv_GetKerningPairs( PHYSDEV dev, DWORD count, LPKERNINGPAIR pairs )
{
    return 0;
}

static UINT nulldrv_GetOutlineTextMetrics( PHYSDEV dev, UINT size, LPOUTLINETEXTMETRICW otm )
{
    return 0;
}

static UINT nulldrv_GetTextCharsetInfo( PHYSDEV dev, LPFONTSIGNATURE fs, DWORD flags )
{
    return DEFAULT_CHARSET;
}

static BOOL nulldrv_GetTextExtentExPoint( PHYSDEV dev, LPCWSTR str, INT count, INT *dx )
{
    return FALSE;
}

static BOOL nulldrv_GetTextExtentExPointI( PHYSDEV dev, const WORD *indices, INT count, INT *dx )
{
    return FALSE;
}

static INT nulldrv_GetTextFace( PHYSDEV dev, INT size, LPWSTR name )
{
    INT ret = 0;
    LOGFONTW font;
    DC *dc = get_nulldrv_dc( dev );

    if (NtGdiExtGetObjectW( dc->hFont, sizeof(font), &font ))
    {
        ret = lstrlenW( font.lfFaceName ) + 1;
        if (name)
        {
            lstrcpynW( name, font.lfFaceName, size );
            ret = min( size, ret );
        }
    }
    return ret;
}

static BOOL nulldrv_GetTextMetrics( PHYSDEV dev, TEXTMETRICW *metrics )
{
    return FALSE;
}

static BOOL nulldrv_LineTo( PHYSDEV dev, INT x, INT y )
{
    return TRUE;
}

static BOOL nulldrv_MoveTo( PHYSDEV dev, INT x, INT y )
{
    return TRUE;
}

static BOOL nulldrv_PaintRgn( PHYSDEV dev, HRGN rgn )
{
    return TRUE;
}

static BOOL nulldrv_PatBlt( PHYSDEV dev, struct bitblt_coords *dst, DWORD rop )
{
    return TRUE;
}

static BOOL nulldrv_Pie( PHYSDEV dev, INT left, INT top, INT right, INT bottom,
                         INT xstart, INT ystart, INT xend, INT yend )
{
    return TRUE;
}

static BOOL nulldrv_PolyPolygon( PHYSDEV dev, const POINT *points, const INT *counts, UINT polygons )
{
    return TRUE;
}

static BOOL nulldrv_PolyPolyline( PHYSDEV dev, const POINT *points, const DWORD *counts, DWORD lines )
{
    return TRUE;
}

static DWORD nulldrv_PutImage( PHYSDEV dev, HRGN clip, BITMAPINFO *info,
                               const struct gdi_image_bits *bits, struct bitblt_coords *src,
                               struct bitblt_coords *dst, DWORD rop )
{
    return ERROR_SUCCESS;
}

static UINT nulldrv_RealizeDefaultPalette( PHYSDEV dev )
{
    return 0;
}

static UINT nulldrv_RealizePalette( PHYSDEV dev, HPALETTE palette, BOOL primary )
{
    return 0;
}

static BOOL nulldrv_Rectangle( PHYSDEV dev, INT left, INT top, INT right, INT bottom )
{
    return TRUE;
}

static BOOL nulldrv_ResetDC( PHYSDEV dev, const DEVMODEW *devmode )
{
    return FALSE;
}

static BOOL nulldrv_RoundRect( PHYSDEV dev, INT left, INT top, INT right, INT bottom,
                               INT ell_width, INT ell_height )
{
    return TRUE;
}

static HBITMAP nulldrv_SelectBitmap( PHYSDEV dev, HBITMAP bitmap )
{
    return bitmap;
}

static HBRUSH nulldrv_SelectBrush( PHYSDEV dev, HBRUSH brush, const struct brush_pattern *pattern )
{
    return brush;
}

static HFONT nulldrv_SelectFont( PHYSDEV dev, HFONT font, UINT *aa_flags )
{
    return font;
}

static HPEN nulldrv_SelectPen( PHYSDEV dev, HPEN pen, const struct brush_pattern *pattern )
{
    return pen;
}

static COLORREF nulldrv_SetBkColor( PHYSDEV dev, COLORREF color )
{
    return color;
}

static UINT nulldrv_SetBoundsRect( PHYSDEV dev, RECT *rect, UINT flags )
{
    return DCB_RESET;
}

static COLORREF nulldrv_SetDCBrushColor( PHYSDEV dev, COLORREF color )
{
    return color;
}

static COLORREF nulldrv_SetDCPenColor( PHYSDEV dev, COLORREF color )
{
    return color;
}

static void nulldrv_SetDeviceClipping( PHYSDEV dev, HRGN rgn )
{
}

static BOOL nulldrv_SetDeviceGammaRamp( PHYSDEV dev, void *ramp )
{
    RtlSetLastWin32Error( ERROR_INVALID_PARAMETER );
    return FALSE;
}

static COLORREF nulldrv_SetPixel( PHYSDEV dev, INT x, INT y, COLORREF color )
{
    return color;
}

static COLORREF nulldrv_SetTextColor( PHYSDEV dev, COLORREF color )
{
    return color;
}

static INT nulldrv_StartDoc( PHYSDEV dev, const DOCINFOW *info )
{
    return 0;
}

static INT nulldrv_StartPage( PHYSDEV dev )
{
    return 1;
}

static BOOL nulldrv_UnrealizePalette( HPALETTE palette )
{
    return FALSE;
}

const struct gdi_dc_funcs null_driver =
{
    nulldrv_AbortDoc,                   /* pAbortDoc */
    nulldrv_AbortPath,                  /* pAbortPath */
    nulldrv_AlphaBlend,                 /* pAlphaBlend */
    nulldrv_AngleArc,                   /* pAngleArc */
    nulldrv_Arc,                        /* pArc */
    nulldrv_ArcTo,                      /* pArcTo */
    nulldrv_BeginPath,                  /* pBeginPath */
    nulldrv_BlendImage,                 /* pBlendImage */
    nulldrv_Chord,                      /* pChord */
    nulldrv_CloseFigure,                /* pCloseFigure */
    nulldrv_CreateCompatibleDC,         /* pCreateCompatibleDC */
    nulldrv_CreateDC,                   /* pCreateDC */
    nulldrv_DeleteDC,                   /* pDeleteDC */
    nulldrv_DeleteObject,               /* pDeleteObject */
    nulldrv_Ellipse,                    /* pEllipse */
    nulldrv_EndDoc,                     /* pEndDoc */
    nulldrv_EndPage,                    /* pEndPage */
    nulldrv_EndPath,                    /* pEndPath */
    nulldrv_EnumFonts,                  /* pEnumFonts */
    nulldrv_ExtEscape,                  /* pExtEscape */
    nulldrv_ExtFloodFill,               /* pExtFloodFill */
    nulldrv_ExtTextOut,                 /* pExtTextOut */
    nulldrv_FillPath,                   /* pFillPath */
    nulldrv_FillRgn,                    /* pFillRgn */
    nulldrv_FontIsLinked,               /* pFontIsLinked */
    nulldrv_FrameRgn,                   /* pFrameRgn */
    nulldrv_GetBoundsRect,              /* pGetBoundsRect */
    nulldrv_GetCharABCWidths,           /* pGetCharABCWidths */
    nulldrv_GetCharABCWidthsI,          /* pGetCharABCWidthsI */
    nulldrv_GetCharWidth,               /* pGetCharWidth */
    nulldrv_GetCharWidthInfo,           /* pGetCharWidthInfo */
    nulldrv_GetDeviceCaps,              /* pGetDeviceCaps */
    nulldrv_GetDeviceGammaRamp,         /* pGetDeviceGammaRamp */
    nulldrv_GetFontData,                /* pGetFontData */
    nulldrv_GetFontRealizationInfo,     /* pGetFontRealizationInfo */
    nulldrv_GetFontUnicodeRanges,       /* pGetFontUnicodeRanges */
    nulldrv_GetGlyphIndices,            /* pGetGlyphIndices */
    nulldrv_GetGlyphOutline,            /* pGetGlyphOutline */
    nulldrv_GetImage,                   /* pGetImage */
    nulldrv_GetKerningPairs,            /* pGetKerningPairs */
    nulldrv_GetNearestColor,            /* pGetNearestColor */
    nulldrv_GetOutlineTextMetrics,      /* pGetOutlineTextMetrics */
    nulldrv_GetPixel,                   /* pGetPixel */
    nulldrv_GetSystemPaletteEntries,    /* pGetSystemPaletteEntries */
    nulldrv_GetTextCharsetInfo,         /* pGetTextCharsetInfo */
    nulldrv_GetTextExtentExPoint,       /* pGetTextExtentExPoint */
    nulldrv_GetTextExtentExPointI,      /* pGetTextExtentExPointI */
    nulldrv_GetTextFace,                /* pGetTextFace */
    nulldrv_GetTextMetrics,             /* pGetTextMetrics */
    nulldrv_GradientFill,               /* pGradientFill */
    nulldrv_InvertRgn,                  /* pInvertRgn */
    nulldrv_LineTo,                     /* pLineTo */
    nulldrv_MoveTo,                     /* pMoveTo */
    nulldrv_PaintRgn,                   /* pPaintRgn */
    nulldrv_PatBlt,                     /* pPatBlt */
    nulldrv_Pie,                        /* pPie */
    nulldrv_PolyBezier,                 /* pPolyBezier */
    nulldrv_PolyBezierTo,               /* pPolyBezierTo */
    nulldrv_PolyDraw,                   /* pPolyDraw */
    nulldrv_PolyPolygon,                /* pPolyPolygon */
    nulldrv_PolyPolyline,               /* pPolyPolyline */
    nulldrv_PolylineTo,                 /* pPolylineTo */
    nulldrv_PutImage,                   /* pPutImage */
    nulldrv_RealizeDefaultPalette,      /* pRealizeDefaultPalette */
    nulldrv_RealizePalette,             /* pRealizePalette */
    nulldrv_Rectangle,                  /* pRectangle */
    nulldrv_ResetDC,                    /* pResetDC */
    nulldrv_RoundRect,                  /* pRoundRect */
    nulldrv_SelectBitmap,               /* pSelectBitmap */
    nulldrv_SelectBrush,                /* pSelectBrush */
    nulldrv_SelectFont,                 /* pSelectFont */
    nulldrv_SelectPen,                  /* pSelectPen */
    nulldrv_SetBkColor,                 /* pSetBkColor */
    nulldrv_SetBoundsRect,              /* pSetBoundsRect */
    nulldrv_SetDCBrushColor,            /* pSetDCBrushColor */
    nulldrv_SetDCPenColor,              /* pSetDCPenColor */
    nulldrv_SetDIBitsToDevice,          /* pSetDIBitsToDevice */
    nulldrv_SetDeviceClipping,          /* pSetDeviceClipping */
    nulldrv_SetDeviceGammaRamp,         /* pSetDeviceGammaRamp */
    nulldrv_SetPixel,                   /* pSetPixel */
    nulldrv_SetTextColor,               /* pSetTextColor */
    nulldrv_StartDoc,                   /* pStartDoc */
    nulldrv_StartPage,                  /* pStartPage */
    nulldrv_StretchBlt,                 /* pStretchBlt */
    nulldrv_StretchDIBits,              /* pStretchDIBits */
    nulldrv_StrokeAndFillPath,          /* pStrokeAndFillPath */
    nulldrv_StrokePath,                 /* pStrokePath */
    nulldrv_UnrealizePalette,           /* pUnrealizePalette */

    GDI_PRIORITY_NULL_DRV               /* priority */
};


/**********************************************************************
 * Null user driver
 *
 * These are fallbacks for entry points that are not implemented in the real driver.
 */

static BOOL nulldrv_ActivateKeyboardLayout( HKL layout, UINT flags )
{
    return TRUE;
}

static void nulldrv_Beep(void)
{
}

static UINT nulldrv_GetKeyboardLayoutList( INT size, HKL *layouts )
{
    return ~0; /* use default implementation */
}

static INT nulldrv_GetKeyNameText( LONG lparam, LPWSTR buffer, INT size )
{
    return -1; /* use default implementation */
}

static UINT nulldrv_MapVirtualKeyEx( UINT code, UINT type, HKL layout )
{
    return -1; /* use default implementation */
}

static BOOL nulldrv_RegisterHotKey( HWND hwnd, UINT modifiers, UINT vk )
{
    return TRUE;
}

static INT nulldrv_ToUnicodeEx( UINT virt, UINT scan, const BYTE *state, LPWSTR str,
                                int size, UINT flags, HKL layout )
{
    return -2; /* use default implementation */
}

static void nulldrv_UnregisterHotKey( HWND hwnd, UINT modifiers, UINT vk )
{
}

static SHORT nulldrv_VkKeyScanEx( WCHAR ch, HKL layout )
{
    return -256; /* use default implementation */
}

static const KBDTABLES *nulldrv_KbdLayerDescriptor( HKL layout )
{
    return NULL;
}

static void nulldrv_ReleaseKbdTables( const KBDTABLES *tables )
{
}

static UINT nulldrv_ImeProcessKey( HIMC himc, UINT wparam, UINT lparam, const BYTE *state )
{
    return 0;
}

static void nulldrv_NotifyIMEStatus( HWND hwnd, UINT status )
{
}

static BOOL nulldrv_SetIMECompositionRect( HWND hwnd, RECT rect )
{
    return FALSE;
}

static LRESULT nulldrv_DesktopWindowProc( HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam )
{
    return default_window_proc( hwnd, msg, wparam, lparam, FALSE );
}

static void nulldrv_DestroyCursorIcon( HCURSOR cursor )
{
}

static void nulldrv_SetCursor( HWND hwnd, HCURSOR cursor )
{
}

static BOOL nulldrv_GetCursorPos( LPPOINT pt )
{
    return TRUE;
}

static BOOL nulldrv_SetCursorPos( INT x, INT y )
{
    return TRUE;
}

static BOOL nulldrv_ClipCursor( const RECT *clip, BOOL reset )
{
    return TRUE;
}

static LRESULT nulldrv_NotifyIcon( HWND hwnd, UINT msg, NOTIFYICONDATAW *data )
{
    return -1;
}

static void nulldrv_CleanupIcons( HWND hwnd )
{
}

static void nulldrv_SystrayDockInit( HWND hwnd )
{
}

static BOOL nulldrv_SystrayDockInsert( HWND hwnd, UINT cx, UINT cy, void *icon )
{
    return FALSE;
}

static void nulldrv_SystrayDockClear( HWND hwnd )
{
}

static BOOL nulldrv_SystrayDockRemove( HWND hwnd )
{
    return FALSE;
}

static void nulldrv_UpdateClipboard(void)
{
}

static LONG nulldrv_ChangeDisplaySettings( LPDEVMODEW displays, LPCWSTR primary_name, HWND hwnd,
                                           DWORD flags, LPVOID lparam )
{
    return DISP_CHANGE_SUCCESSFUL;
}

static UINT nulldrv_UpdateDisplayDevices( const struct gdi_device_manager *manager, void *param )
{
    return STATUS_NOT_IMPLEMENTED;
}

#ifdef WINE_IOS
/* winios.drv: register a single 1024×768 monitor matching the values
 * sysparams_ios.c returns for SM_CXSCREEN/CYSCREEN. Wine uses this for
 * EnumDisplayDevices, EnumDisplayMonitors, GetDeviceCaps, and the
 * registry-backed monitor records. Without it, Wine derives broken
 * geometry from the (zero-initialized) winstation monitor list. */
/* NOTE: This is wired into winios_user_driver.pUpdateDisplayDevices but
 * is currently DORMANT on iOS. sysparams_ios.c:lock_display_devices has
 * an `is_service_process()` shortcut that bypasses Wine's full display
 * enumeration and uses a hardcoded `virtual_monitor` (also 1024x768).
 * This implementation is ready for when we remove that shortcut to
 * support real games' EnumDisplayDevices/ChangeDisplaySettings calls. */
static UINT winios_UpdateDisplayDevices( const struct gdi_device_manager *manager, void *param )
{
    /* Single virtual GPU: vendor 0x1002 (AMD) + a placeholder device id —
     * Wine's user32/dxgi only check vendor/device for filter logic; the
     * exact values don't matter for our render path. */
    struct pci_id pci_id = { .vendor = 0x1002, .device = 0x67df, .subsystem = 0, .revision = 0 };
    manager->add_gpu( "winios GPU", &pci_id, NULL, param );

    /* Single source/adapter, attached + primary. */
    manager->add_source( "winios0", 0x00000005 /* DISPLAY_DEVICE_ATTACHED|PRIMARY */,
                         96 /* dpi */, param );

    /* Single monitor at (0,0)–(1024,768). */
    struct gdi_monitor monitor = {
        .rc_monitor = { 0, 0, 1024, 768 },
        .rc_work    = { 0, 0, 1024, 768 },
        .edid       = NULL,
        .edid_len   = 0,
        .hdr_enabled = FALSE,
    };
    manager->add_monitor( &monitor, param );

    /* Single 1024×768×32 mode at 60 Hz. */
    DEVMODEW current = { .dmSize = sizeof(current) };
    current.dmFields = DM_BITSPERPEL | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
    current.dmBitsPerPel = 32;
    current.dmPelsWidth = 1024;
    current.dmPelsHeight = 768;
    current.dmDisplayFrequency = 60;
    manager->add_modes( &current, 1, &current, param );

    return STATUS_SUCCESS;
}
#endif

static BOOL nulldrv_CreateDesktop( const WCHAR *name, UINT width, UINT height )
{
    return TRUE;
}

static BOOL nodrv_CreateWindow( HWND hwnd )
{
    static int warned;
    HWND parent = NtUserGetAncestor( hwnd, GA_PARENT );

    /* HWND_MESSAGE windows don't need a graphics driver */
    if (!parent || parent == UlongToHandle( NtUserGetThreadInfo()->msg_window )) return TRUE;
    if (warned++) return FALSE;

    ERR_(winediag)( "Application tried to create a window, but no driver could be loaded.\n" );
    if (driver_load_error[0]) ERR_(winediag)( "%s\n", debugstr_w(driver_load_error) );
    return FALSE;
}

static BOOL nulldrv_CreateWindow( HWND hwnd )
{
    return TRUE;
}

static void nulldrv_DestroyWindow( HWND hwnd )
{
}

static void nulldrv_FlashWindowEx( FLASHWINFO *info )
{
}

static void nulldrv_GetDC( HDC hdc, HWND hwnd, HWND top_win, const RECT *win_rect,
                           const RECT *top_rect, DWORD flags )
{
}

static BOOL nulldrv_ProcessEvents( DWORD mask )
{
    return FALSE;
}

static void nulldrv_ReleaseDC( HWND hwnd, HDC hdc )
{
}

static BOOL nulldrv_ScrollDC( HDC hdc, INT dx, INT dy, HRGN update )
{
    RECT rect;

    NtGdiGetAppClipBox( hdc, &rect );
    return NtGdiBitBlt( hdc, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
                        hdc, rect.left - dx, rect.top - dy, SRCCOPY, 0, 0 );
}

static void nulldrv_SetCapture( HWND hwnd, UINT flags )
{
}

static void nulldrv_SetDesktopWindow( HWND hwnd )
{
}

static void nulldrv_ActivateWindow( HWND hwnd, HWND previous )
{
}

static void nulldrv_SetLayeredWindowAttributes( HWND hwnd, COLORREF key, BYTE alpha, DWORD flags )
{
}

static void nulldrv_SetParent( HWND hwnd, HWND parent, HWND old_parent )
{
}

static void nulldrv_SetWindowRgn( HWND hwnd, HRGN hrgn, BOOL redraw )
{
}

static void nulldrv_SetWindowIcons( HWND hwnd, HICON icon, const ICONINFO *ii, HICON icon_small, const ICONINFO *ii_small )
{
}

static void nulldrv_SetWindowStyle( HWND hwnd, INT offset, STYLESTRUCT *style )
{
}

static void nulldrv_SetWindowText( HWND hwnd, LPCWSTR text )
{
}

static UINT nulldrv_ShowWindow( HWND hwnd, INT cmd, RECT *rect, UINT swp )
{
    return ~0; /* use default implementation */
}

static LRESULT nulldrv_SysCommand( HWND hwnd, WPARAM wparam, LPARAM lparam, const POINT *pos )
{
    return -1;
}

static void nulldrv_UpdateLayeredWindow( HWND hwnd, BYTE alpha, UINT flags )
{
}

static LRESULT nulldrv_WindowMessage( HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam )
{
    return 0;
}

static BOOL nulldrv_WindowPosChanging( HWND hwnd, UINT swp_flags, BOOL shaped, const struct window_rects *rects )
{
    return TRUE;
}

static BOOL nulldrv_GetWindowStyleMasks( HWND hwnd, UINT style, UINT ex_style, UINT *style_mask, UINT *ex_style_mask )
{
    return FALSE;
}

static BOOL nulldrv_GetWindowStateUpdates( HWND hwnd, UINT *state_cmd, UINT *swp_flags, RECT *rect, HWND *foreground )
{
    return FALSE;
}

static BOOL nulldrv_CreateWindowSurface( HWND hwnd, BOOL layered, const RECT *surface_rect, struct window_surface **surface )
{
    return FALSE;
}

static void nulldrv_MoveWindowBits( HWND hwnd, const struct window_rects *old_rects,
                                    const struct window_rects *new_rects, const RECT *valid_rects )
{
}

static void nulldrv_WindowPosChanged( HWND hwnd, HWND insert_after, HWND owner_hint, UINT swp_flags,
                                      const struct window_rects *new_rects, struct window_surface *surface )
{
}

static BOOL nulldrv_SystemParametersInfo( UINT action, UINT int_param, void *ptr_param, UINT flags )
{
    return FALSE;
}

static LRESULT nulldrv_WintabProc( HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam, void *buffer )
{
    return 0;
}

static UINT nulldrv_VulkanInit( UINT version, void *vulkan_handle, const struct vulkan_driver_funcs **driver_funcs )
{
    return STATUS_NOT_IMPLEMENTED;
}

static UINT nulldrv_OpenGLInit( UINT version, const struct opengl_funcs *opengl_funcs, const struct opengl_driver_funcs **driver_funcs )
{
    return STATUS_NOT_IMPLEMENTED;
}

static void nulldrv_ThreadDetach( void )
{
}

static const WCHAR guid_key_prefixW[] =
{
    '\\','R','e','g','i','s','t','r','y',
    '\\','M','a','c','h','i','n','e',
    '\\','S','y','s','t','e','m',
    '\\','C','u','r','r','e','n','t','C','o','n','t','r','o','l','S','e','t',
    '\\','C','o','n','t','r','o','l',
    '\\','V','i','d','e','o','\\','{'
};
static const WCHAR guid_key_suffixW[] = {'}','\\','0','0','0','0'};

static BOOL load_desktop_driver( HWND hwnd )
{
    static const WCHAR guid_nullW[] = {'0','0','0','0','0','0','0','0','-','0','0','0','0','-','0','0','0','0','-',
                                       '0','0','0','0','-','0','0','0','0','0','0','0','0','0','0','0','0',0};
    WCHAR key[ARRAYSIZE(guid_key_prefixW) + 40 + ARRAYSIZE(guid_key_suffixW)], *ptr;
    char buf[4096];
    KEY_VALUE_PARTIAL_INFORMATION *info = (void *)buf;
    ATOM_BASIC_INFORMATION *abi = (ATOM_BASIC_INFORMATION *)buf;
    BOOL ret = FALSE;
    HKEY hkey;
    DWORD size;
    UINT guid_atom;

    static const WCHAR prop_nameW[] =
        {'_','_','w','i','n','e','_','d','i','s','p','l','a','y','_','d','e','v','i','c','e',
         '_','g','u','i','d',0};

    user_check_not_lock();

    asciiz_to_unicode( driver_load_error, "The explorer process failed to start." );  /* default error */
    /* wait for graphics driver to be ready */
    send_message( hwnd, WM_NULL, 0, 0 );

    guid_atom = HandleToULong( NtUserGetProp( hwnd, prop_nameW ));
    memcpy( key, guid_key_prefixW, sizeof(guid_key_prefixW) );
    ptr = key + ARRAYSIZE(guid_key_prefixW);
    if (NtQueryInformationAtom( guid_atom, AtomBasicInformation, buf, sizeof(buf), NULL ))
    {
        wcscpy( ptr, guid_nullW );
        ptr += ARRAY_SIZE(guid_nullW) - 1;
    }
    else
    {
        memcpy( ptr, abi->Name, abi->NameLength );
        ptr += abi->NameLength / sizeof(WCHAR);
    }
    memcpy( ptr, guid_key_suffixW, sizeof(guid_key_suffixW) );
    ptr += ARRAY_SIZE(guid_key_suffixW);

    if (!(hkey = reg_open_key( NULL, key, (ptr - key) * sizeof(WCHAR) ))) return FALSE;

    if ((size = query_reg_ascii_value( hkey, "GraphicsDriver", info, sizeof(buf) )))
    {
        static const WCHAR nullW[] = {'n','u','l','l',0};
        TRACE( "trying driver %s\n", debugstr_wn( (const WCHAR *)info->Data,
                                                  info->DataLength / sizeof(WCHAR) ));
        if (info->DataLength != sizeof(nullW) || memcmp( info->Data, nullW, sizeof(nullW) ))
        {
            void *ret_ptr;
            ULONG ret_len;
            ret = !KeUserModeCallback( NtUserLoadDriver, info->Data, info->DataLength, &ret_ptr, &ret_len );
        }
        else
        {
            __wine_set_user_driver( &null_user_driver, WINE_GDI_DRIVER_VERSION );
            ret = TRUE;
        }
    }
    else if ((size = query_reg_ascii_value( hkey, "DriverError", info, sizeof(buf) )))
    {
        memcpy( driver_load_error, info->Data, min( info->DataLength, sizeof(driver_load_error) ));
        driver_load_error[ARRAYSIZE(driver_load_error) - 1] = 0;
    }

    NtClose( hkey );
    return ret;
}

/**********************************************************************
 * Lazy loading user driver
 *
 * Initial driver used before another driver is loaded.
 * Each entry point simply loads the real driver and chains to it.
 */

static void load_display_driver(void)
{
    USEROBJECTFLAGS flags;
    HWINSTA winstation;

    if (is_service_process() || !load_desktop_driver( get_desktop_window() ) || user_driver == &lazy_load_driver)
    {
        winstation = NtUserGetProcessWindowStation();
        if (!NtUserGetObjectInformation( winstation, UOI_FLAGS, &flags, sizeof(flags), NULL )
            || (flags.dwFlags & WSF_VISIBLE))
        {
#ifdef WINE_IOS
            /* iOS: leave pCreateWindow as the always-success nulldrv path
             * (set by __wine_set_user_driver via SET_USER_FUNC fallback).
             * The nodrv_CreateWindow returns FALSE for any non-HWND_MESSAGE
             * window, which would abort CreateWindowEx. We don't want that
             * — winios.drv (below) takes over actual window/input bridging. */
#else
            null_user_driver.pCreateWindow = nodrv_CreateWindow;
#endif
        }

#ifdef WINE_IOS
        /* Wire up winios.drv slots from the weak externs above. Slots
         * with no implementation linked (weak ref == NULL) stay NULL
         * and SET_USER_FUNC falls back to nulldrv_*. Real impls live
         * in app/Madeira/Winios/Winios.m and link in via Madeira.app. */
        if (winios_pCreateWindow)        winios_user_driver.pCreateWindow        = winios_pCreateWindow;
        if (winios_pDestroyWindow)       winios_user_driver.pDestroyWindow       = winios_pDestroyWindow;
        if (winios_pProcessEvents)       winios_user_driver.pProcessEvents       = winios_pProcessEvents;
        /* ml — installed unconditionally now (was desktop-mode only): see
         * winios_drv_set_cursor's own comment above. winios_pSetCursor
         * (Winios.m's old empty stub) is no longer wired to anything. */
        winios_user_driver.pSetCursor            = winios_drv_set_cursor;
        if (winios_pDestroyCursorIcon)   winios_user_driver.pDestroyCursorIcon   = winios_pDestroyCursorIcon;
        if (winios_pShowWindow)          winios_user_driver.pShowWindow          = winios_pShowWindow;
        /* window-pos wrapper dereferences window_rects on this side and
         * forwards plain ints to Winios.m's layer compositor */
        /* Always install the wrapper, even with no app-side hook linked: it
         * also carries the expose-equivalent repaint request (see
         * winios_drv_window_pos_changed), which must not depend on Winios.m. */
        winios_user_driver.pWindowPosChanged = winios_drv_window_pos_changed;
        /* GDI window surfaces → app compositor. Desktop mode composites them
         * into its own view; a direct launch draws them in the overlay inside
         * the presented layer (see winios_direct_overlay). Without this hook
         * a window gets win32u's offscreen surface, whose flush goes nowhere —
         * which is precisely why a directly-launched dialog was invisible. */
        if (winios_desktop_mode())
        {
            winios_user_driver.pCreateWindowSurface = winios_CreateWindowSurface;
            dprintf( 2, "[winios] desktop mode: window-surface compositing ENABLED\n" );
        }
        else if (winios_direct_overlay())
        {
            winios_user_driver.pCreateWindowSurface = winios_CreateWindowSurface;
            dprintf( 2, "[overlay] direct launch: window-surface compositing ENABLED "
                        "(MADEIRA_DIRECT_OVERLAY=0 to disable)\n" );
        }
        winios_user_driver.pUpdateDisplayDevices = winios_UpdateDisplayDevices;
        __wine_set_user_driver( &winios_user_driver, WINE_GDI_DRIVER_VERSION );
#else
        __wine_set_user_driver( &null_user_driver, WINE_GDI_DRIVER_VERSION );
#endif
    }
}

static const struct user_driver_funcs *load_driver(void)
{
    load_display_driver();
    update_display_cache( FALSE );
    return user_driver;
}

void init_display_driver(void)
{
    if (user_driver == &lazy_load_driver) load_display_driver();
}

/**********************************************************************
 *           get_display_driver
 */
const struct gdi_dc_funcs *get_display_driver(void)
{
    if (user_driver == &lazy_load_driver) load_driver();
    return &user_driver->dc_funcs;
}

static BOOL loaderdrv_ActivateKeyboardLayout( HKL layout, UINT flags )
{
    return load_driver()->pActivateKeyboardLayout( layout, flags );
}

static void loaderdrv_Beep(void)
{
    load_driver()->pBeep();
}

static INT loaderdrv_GetKeyNameText( LONG lparam, LPWSTR buffer, INT size )
{
    return load_driver()->pGetKeyNameText( lparam, buffer, size );
}

static UINT loaderdrv_GetKeyboardLayoutList( INT size, HKL *layouts )
{
    return load_driver()->pGetKeyboardLayoutList( size, layouts );
}

static UINT loaderdrv_MapVirtualKeyEx( UINT code, UINT type, HKL layout )
{
    return load_driver()->pMapVirtualKeyEx( code, type, layout );
}

static INT loaderdrv_ToUnicodeEx( UINT virt, UINT scan, const BYTE *state, LPWSTR str,
                                        int size, UINT flags, HKL layout )
{
    return load_driver()->pToUnicodeEx( virt, scan, state, str, size, flags, layout );
}

static BOOL loaderdrv_RegisterHotKey( HWND hwnd, UINT modifiers, UINT vk )
{
    return load_driver()->pRegisterHotKey( hwnd, modifiers, vk );
}

static void loaderdrv_UnregisterHotKey( HWND hwnd, UINT modifiers, UINT vk )
{
    load_driver()->pUnregisterHotKey( hwnd, modifiers, vk );
}

static SHORT loaderdrv_VkKeyScanEx( WCHAR ch, HKL layout )
{
    return load_driver()->pVkKeyScanEx( ch, layout );
}

static const KBDTABLES *loaderdrv_KbdLayerDescriptor( HKL layout )
{
    return load_driver()->pKbdLayerDescriptor( layout );
}

static void loaderdrv_ReleaseKbdTables( const KBDTABLES *tables )
{
    return load_driver()->pReleaseKbdTables( tables );
}

static UINT loaderdrv_ImeProcessKey( HIMC himc, UINT wparam, UINT lparam, const BYTE *state )
{
    return load_driver()->pImeProcessKey( himc, wparam, lparam, state );
}

static void loaderdrv_NotifyIMEStatus( HWND hwnd, UINT status )
{
    return load_driver()->pNotifyIMEStatus( hwnd, status );
}

static BOOL loaderdrv_SetIMECompositionRect( HWND hwnd, RECT rect )
{
    return load_driver()->pSetIMECompositionRect( hwnd, rect );
}

static LONG loaderdrv_ChangeDisplaySettings( LPDEVMODEW displays, LPCWSTR primary_name, HWND hwnd,
                                             DWORD flags, LPVOID lparam )
{
    return load_driver()->pChangeDisplaySettings( displays, primary_name, hwnd, flags, lparam );
}

static void loaderdrv_SetCursor( HWND hwnd, HCURSOR cursor )
{
    load_driver()->pSetCursor( hwnd, cursor );
}

static BOOL loaderdrv_GetCursorPos( POINT *pt )
{
    return load_driver()->pGetCursorPos( pt );
}

static BOOL loaderdrv_SetCursorPos( INT x, INT y )
{
    return load_driver()->pSetCursorPos( x, y );
}

static BOOL loaderdrv_ClipCursor( const RECT *clip, BOOL reset )
{
    return load_driver()->pClipCursor( clip, reset );
}

static LRESULT loaderdrv_NotifyIcon( HWND hwnd, UINT msg, NOTIFYICONDATAW *data )
{
    return load_driver()->pNotifyIcon( hwnd, msg, data );
}

static void loaderdrv_CleanupIcons( HWND hwnd )
{
    load_driver()->pCleanupIcons( hwnd );
}

static void loaderdrv_SystrayDockInit( HWND hwnd )
{
    load_driver()->pSystrayDockInit( hwnd );
}

static BOOL loaderdrv_SystrayDockInsert( HWND hwnd, UINT cx, UINT cy, void *icon )
{
    return load_driver()->pSystrayDockInsert( hwnd, cx, cy, icon );
}

static void loaderdrv_SystrayDockClear( HWND hwnd )
{
    load_driver()->pSystrayDockClear( hwnd );
}

static BOOL loaderdrv_SystrayDockRemove( HWND hwnd )
{
    return load_driver()->pSystrayDockRemove( hwnd );
}

static LRESULT nulldrv_ClipboardWindowProc( HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam )
{
    return 0;
}

static void loaderdrv_UpdateClipboard(void)
{
    load_driver()->pUpdateClipboard();
}

static UINT loaderdrv_UpdateDisplayDevices( const struct gdi_device_manager *manager, void *param )
{
    return load_driver()->pUpdateDisplayDevices( manager, param );
}

static BOOL loaderdrv_CreateDesktop( const WCHAR *name, UINT width, UINT height )
{
    return load_driver()->pCreateDesktop( name, width, height );
}

static BOOL loaderdrv_CreateWindow( HWND hwnd )
{
    return load_driver()->pCreateWindow( hwnd );
}

static void loaderdrv_GetDC( HDC hdc, HWND hwnd, HWND top_win, const RECT *win_rect,
                             const RECT *top_rect, DWORD flags )
{
    load_driver()->pGetDC( hdc, hwnd, top_win, win_rect, top_rect, flags );
}

static void loaderdrv_FlashWindowEx( FLASHWINFO *info )
{
    load_driver()->pFlashWindowEx( info );
}

static void loaderdrv_SetDesktopWindow( HWND hwnd )
{
    load_driver()->pSetDesktopWindow( hwnd );
}

static void loaderdrv_SetLayeredWindowAttributes( HWND hwnd, COLORREF key, BYTE alpha, DWORD flags )
{
    load_driver()->pSetLayeredWindowAttributes( hwnd, key, alpha, flags );
}

static void loaderdrv_SetWindowRgn( HWND hwnd, HRGN hrgn, BOOL redraw )
{
    load_driver()->pSetWindowRgn( hwnd, hrgn, redraw );
}

static void loaderdrv_UpdateLayeredWindow( HWND hwnd, BYTE alpha, UINT flags )
{
    load_driver()->pUpdateLayeredWindow( hwnd, alpha, flags );
}

static LRESULT loaderdrv_WintabProc( HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam, void *buffer )
{
    return load_driver()->pWintabProc( hwnd, msg, wparam, lparam, buffer );
}

static UINT loaderdrv_VulkanInit( UINT version, void *vulkan_handle, const struct vulkan_driver_funcs **driver_funcs )
{
    return load_driver()->pVulkanInit( version, vulkan_handle, driver_funcs );
}

static UINT loaderdrv_OpenGLInit( UINT version, const struct opengl_funcs *opengl_funcs, const struct opengl_driver_funcs **driver_funcs )
{
    return load_driver()->pOpenGLInit( version, opengl_funcs, driver_funcs );
}

static const struct user_driver_funcs lazy_load_driver =
{
    { NULL },
    /* keyboard functions */
    loaderdrv_ActivateKeyboardLayout,
    loaderdrv_Beep,
    loaderdrv_GetKeyNameText,
    loaderdrv_GetKeyboardLayoutList,
    loaderdrv_MapVirtualKeyEx,
    loaderdrv_RegisterHotKey,
    loaderdrv_ToUnicodeEx,
    loaderdrv_UnregisterHotKey,
    loaderdrv_VkKeyScanEx,
    loaderdrv_KbdLayerDescriptor,
    loaderdrv_ReleaseKbdTables,
    loaderdrv_ImeProcessKey,
    loaderdrv_NotifyIMEStatus,
    loaderdrv_SetIMECompositionRect,
    /* cursor/icon functions */
    nulldrv_DestroyCursorIcon,
    loaderdrv_SetCursor,
    loaderdrv_GetCursorPos,
    loaderdrv_SetCursorPos,
    loaderdrv_ClipCursor,
    /* systray functions */
    loaderdrv_NotifyIcon,
    loaderdrv_CleanupIcons,
    loaderdrv_SystrayDockInit,
    loaderdrv_SystrayDockInsert,
    loaderdrv_SystrayDockClear,
    loaderdrv_SystrayDockRemove,
    /* clipboard functions */
    nulldrv_ClipboardWindowProc,
    loaderdrv_UpdateClipboard,
    /* display modes */
    loaderdrv_ChangeDisplaySettings,
    loaderdrv_UpdateDisplayDevices,
    /* windowing functions */
    loaderdrv_CreateDesktop,
    loaderdrv_CreateWindow,
    nulldrv_DesktopWindowProc,
    nulldrv_DestroyWindow,
    loaderdrv_FlashWindowEx,
    loaderdrv_GetDC,
    nulldrv_ProcessEvents,
    nulldrv_ReleaseDC,
    nulldrv_ScrollDC,
    nulldrv_SetCapture,
    loaderdrv_SetDesktopWindow,
    nulldrv_ActivateWindow,
    loaderdrv_SetLayeredWindowAttributes,
    nulldrv_SetParent,
    loaderdrv_SetWindowRgn,
    nulldrv_SetWindowIcons,
    nulldrv_SetWindowStyle,
    nulldrv_SetWindowText,
    nulldrv_ShowWindow,
    nulldrv_SysCommand,
    loaderdrv_UpdateLayeredWindow,
    nulldrv_WindowMessage,
    nulldrv_WindowPosChanging,
    nulldrv_GetWindowStyleMasks,
    nulldrv_GetWindowStateUpdates,
    nulldrv_CreateWindowSurface,
    nulldrv_MoveWindowBits,
    nulldrv_WindowPosChanged,
    /* system parameters */
    nulldrv_SystemParametersInfo,
    /* wintab support */
    loaderdrv_WintabProc,
    /* vulkan support */
    loaderdrv_VulkanInit,
    /* opengl support */
    loaderdrv_OpenGLInit,
    /* thread management */
    nulldrv_ThreadDetach,
};

const struct user_driver_funcs *user_driver = &lazy_load_driver;

/******************************************************************************
 *	     __wine_set_user_driver   (win32u.so)
 */
void __wine_set_user_driver( const struct user_driver_funcs *funcs, UINT version )
{
    struct user_driver_funcs *driver, *prev;

    if (version != WINE_GDI_DRIVER_VERSION)
    {
        ERR( "version mismatch, driver wants %u but win32u has %u\n",
             version, WINE_GDI_DRIVER_VERSION );
        return;
    }

    if (!funcs)
    {
        prev = InterlockedExchangePointer( (void **)&user_driver, (void *)&lazy_load_driver );
        if (prev != &lazy_load_driver)
            free( prev );
        return;
    }

    driver = malloc( sizeof(*driver) );
    *driver = *funcs;

#define SET_USER_FUNC(name) \
    do { if (!driver->p##name) driver->p##name = nulldrv_##name; } while(0)

    SET_USER_FUNC(ActivateKeyboardLayout);
    SET_USER_FUNC(Beep);
    SET_USER_FUNC(GetKeyNameText);
    SET_USER_FUNC(GetKeyboardLayoutList);
    SET_USER_FUNC(MapVirtualKeyEx);
    SET_USER_FUNC(RegisterHotKey);
    SET_USER_FUNC(ToUnicodeEx);
    SET_USER_FUNC(UnregisterHotKey);
    SET_USER_FUNC(VkKeyScanEx);
    SET_USER_FUNC(KbdLayerDescriptor);
    SET_USER_FUNC(ReleaseKbdTables);
    SET_USER_FUNC(ImeProcessKey);
    SET_USER_FUNC(NotifyIMEStatus);
    SET_USER_FUNC(SetIMECompositionRect);
    SET_USER_FUNC(DestroyCursorIcon);
    SET_USER_FUNC(SetCursor);
    SET_USER_FUNC(GetCursorPos);
    SET_USER_FUNC(SetCursorPos);
    SET_USER_FUNC(ClipCursor);
    SET_USER_FUNC(NotifyIcon);
    SET_USER_FUNC(CleanupIcons);
    SET_USER_FUNC(SystrayDockInit);
    SET_USER_FUNC(SystrayDockInsert);
    SET_USER_FUNC(SystrayDockClear);
    SET_USER_FUNC(SystrayDockRemove);
    SET_USER_FUNC(ClipboardWindowProc);
    SET_USER_FUNC(UpdateClipboard);
    SET_USER_FUNC(ChangeDisplaySettings);
    SET_USER_FUNC(UpdateDisplayDevices);
    SET_USER_FUNC(CreateDesktop);
    SET_USER_FUNC(CreateWindow);
    SET_USER_FUNC(DesktopWindowProc);
    SET_USER_FUNC(DestroyWindow);
    SET_USER_FUNC(FlashWindowEx);
    SET_USER_FUNC(GetDC);
    SET_USER_FUNC(ProcessEvents);
    SET_USER_FUNC(ReleaseDC);
    SET_USER_FUNC(ScrollDC);
    SET_USER_FUNC(SetCapture);
    SET_USER_FUNC(SetDesktopWindow);
    SET_USER_FUNC(ActivateWindow);
    SET_USER_FUNC(SetLayeredWindowAttributes);
    SET_USER_FUNC(SetParent);
    SET_USER_FUNC(SetWindowRgn);
    SET_USER_FUNC(SetWindowIcons);
    SET_USER_FUNC(SetWindowStyle);
    SET_USER_FUNC(SetWindowText);
    SET_USER_FUNC(ShowWindow);
    SET_USER_FUNC(SysCommand);
    SET_USER_FUNC(UpdateLayeredWindow);
    SET_USER_FUNC(WindowMessage);
    SET_USER_FUNC(WindowPosChanging);
    SET_USER_FUNC(GetWindowStyleMasks);
    SET_USER_FUNC(GetWindowStateUpdates);
    SET_USER_FUNC(CreateWindowSurface);
    SET_USER_FUNC(MoveWindowBits);
    SET_USER_FUNC(WindowPosChanged);
    SET_USER_FUNC(SystemParametersInfo);
    SET_USER_FUNC(WintabProc);
    SET_USER_FUNC(VulkanInit);
    SET_USER_FUNC(OpenGLInit);
    SET_USER_FUNC(ThreadDetach);
#undef SET_USER_FUNC

    prev = InterlockedCompareExchangePointer( (void **)&user_driver, driver, (void *)&lazy_load_driver );
    if (prev != &lazy_load_driver)
    {
        /* another thread beat us to it */
        free( driver );
        driver = prev;
    }
}

/******************************************************************************
 *		NtGdiExtEscape   (win32u.@)
 *
 * Access capabilities of a particular device that are not available through GDI.
 */
INT WINAPI NtGdiExtEscape( HDC hdc, WCHAR *driver, int driver_id, INT escape, INT input_size,
                           const char *input, INT output_size, char *output )
{
    PHYSDEV physdev;
    INT ret;
    DC * dc = get_dc_ptr( hdc );

    if (!dc) return 0;
    update_dc( dc );
    physdev = GET_DC_PHYSDEV( dc, pExtEscape );
    ret = physdev->funcs->pExtEscape( physdev, escape, input_size, input, output_size, output );
    release_dc_ptr( dc );
    return ret;
}

static void nulldrv_surface_destroy( struct client_surface *client )
{
}

static void nulldrv_surface_detach( struct client_surface *client )
{
}

static void nulldrv_surface_update( struct client_surface *client )
{
}

static void nulldrv_surface_present( struct client_surface *client, HDC hdc )
{
}

static const struct client_surface_funcs nulldrv_surface_funcs =
{
    .destroy = nulldrv_surface_destroy,
    .detach = nulldrv_surface_detach,
    .update = nulldrv_surface_update,
    .present = nulldrv_surface_present,
};

struct client_surface *nulldrv_client_surface_create( HWND hwnd )
{
    return client_surface_create( sizeof(struct client_surface), &nulldrv_surface_funcs, hwnd );
}

/* ml1920: same-task controller snapshots supplied by the app. */
#include "../../app/Madeira/Winios/WiniosGamepad.h"

/* Byte-for-byte XINPUT_STATE (a DWORD packet number followed by
 * XINPUT_GAMEPAD). Not #included from xinput.h: that is a PE-side SDK header
 * and this is the unix half of win32u. */
struct ios_xinput_gamepad
{
    WORD  buttons;
    BYTE  left_trigger;
    BYTE  right_trigger;
    SHORT thumb_lx, thumb_ly, thumb_rx, thumb_ry;
};

struct ios_xinput_state
{
    DWORD packet_number;
    struct ios_xinput_gamepad gamepad;
};

/* Byte-for-byte XINPUT_CAPABILITIES. */
struct ios_xinput_caps
{
    BYTE  type;
    BYTE  sub_type;
    WORD  flags;
    struct ios_xinput_gamepad gamepad;
    WORD  left_motor_speed, right_motor_speed;
};

C_ASSERT( sizeof(struct ios_xinput_state) == 16 );
C_ASSERT( sizeof(struct ios_xinput_caps) == 20 );
C_ASSERT( sizeof(struct winios_gamepad) == 20 );

/***********************************************************************
 *           ios_gamepad_query
 *
 * The body of NtUserCallTwoParam_GetGamepadState. `index` is the XInput user
 * index (0-3) and `op` selects the payload; see NtUserGamepadOp_* in
 * wine/include/ntuser.h. Returns 1 when a pad is connected in that slot and
 * `buffer` was filled, 0 otherwise — which is also what an upstream,
 * non-Madeira win32u returns for a code it does not know, so xinput1_3's
 * runtime probe falls back to the existing HID path.
 */
ULONG_PTR ios_gamepad_query( UINT index, UINT op, void *buffer )
{
    struct winios_gamepad pad;

    if (!buffer || index >= 4) return 0;
    if (!winios_gamepad_get_state( index, &pad )) return 0;

    switch (op)
    {
    case 0:   /* NtUserGamepadOp_State */
    {
        struct ios_xinput_state *state = buffer;

        state->packet_number        = pad.packet;
        state->gamepad.buttons      = pad.buttons;
        state->gamepad.left_trigger  = pad.left_trigger;
        state->gamepad.right_trigger = pad.right_trigger;
        state->gamepad.thumb_lx     = pad.lx;
        state->gamepad.thumb_ly     = pad.ly;
        state->gamepad.thumb_rx     = pad.rx;
        state->gamepad.thumb_ry     = pad.ry;
        return 1;
    }
    case 1:   /* NtUserGamepadOp_Caps */
    {
        struct ios_xinput_caps *caps = buffer;

        /* XINPUT_DEVTYPE_GAMEPAD / XINPUT_DEVSUBTYPE_GAMEPAD. The `gamepad`
         * member of XINPUT_CAPABILITIES is not a reading — it is a MASK of
         * what the device can report, which is why every field is saturated
         * rather than copied from `pad`. 0xf3ff is every XINPUT_GAMEPAD_* bit
         * except the two reserved gaps; the thumbs report 16-bit resolution
         * (low bits clear, as real XInput reports them) and the triggers 8. */
        caps->type     = 1;
        caps->sub_type = 1;
        /* Controller rumble is not implemented by this transport. */
        caps->flags    = 0;
        caps->gamepad.buttons       = 0xf3ff;
        caps->gamepad.left_trigger  = 0xff;
        caps->gamepad.right_trigger = 0xff;
        caps->gamepad.thumb_lx = caps->gamepad.thumb_ly = (SHORT)0xffc0;
        caps->gamepad.thumb_rx = caps->gamepad.thumb_ry = (SHORT)0xffc0;
        caps->left_motor_speed = caps->right_motor_speed = 0;
        return 1;
    }
    default:
        return 0;
    }
}
