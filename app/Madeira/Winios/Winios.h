/* Winios.h — registration entry point for the iOS user_driver.
 *
 * winios.drv is Madeira's iOS-side replacement for Wine's per-platform
 * display drivers (winemac.drv, winex11.drv, etc.). It plugs into the
 * win32u-unix `__wine_set_user_driver` extension point, providing the
 * minimum-viable pieces of the user_driver_funcs interface that real
 * games need: window lifecycle (CreateWindow → UIView/CAMetalLayer),
 * event pump (PeekMessage → drained UIKit events), display device
 * description, and touch→mouse input.
 *
 * Most slots in the driver struct are intentionally left NULL.
 * __wine_set_user_driver's SET_USER_FUNC fallback fills missing slots
 * with the always-success nulldrv_* stubs in win32u/driver.c, which is
 * fine for everything DXMT-rendered games need (they own the actual
 * graphics surface via CAMetalLayer; we just bridge windowing/input).
 *
 * Lifecycle: load_display_driver() in build/win32u-unix/driver_ios.c
 * calls winios_drv_register() at first user_driver lazy-load, replacing
 * the current null_user_driver registration on iOS.
 */
#ifndef WINIOS_DRV_H
#define WINIOS_DRV_H

#include "WiniosGamepad.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Build the driver-funcs struct and register it via __wine_set_user_driver.
 * Idempotent: safe to call repeatedly; first call wins. */
void winios_drv_register(void);

/* Touch → mouse bridge. Called by Madeira Swift's UIKit gesture
 * handlers; events are queued to a thread-safe ring buffer and drained
 * inside winios_pProcessEvents. (x, y) are in logical 1024×768 pixels
 * — Swift side handles iOS-pixel → logical-pixel scaling. */
void winios_post_touch_down(int x, int y);
void winios_post_touch_move(int x, int y);
void winios_post_touch_up(int x, int y);

/* Key press bridge (VK codes: RETURN=0x0D SPACE=0x20 ESCAPE=0x1B).
 * down=1 press, down=0 release. */
void winios_post_key(int vk, int down);

/* S2 desktop compositor placement. Called by the Swift presentation
 * placeholder (MetalBackedView) with its bounds in UIWindow coords —
 * the wine virtual desktop renders aspect-fit inside this frame, like
 * the games' Metal layer, instead of covering the whole phone screen.
 * Safe to call before or after the compositor exists; main-thread
 * dispatch inside. */
void winios_set_compositor_frame(double x, double y, double w, double h);
void winios_set_desktop_rect(double x, double y, double w, double h, int set);

/* S2 trackpad pointer. (x, y) are ABSOLUTE wine-desktop pixels (the
 * Swift trackpad engine owns the cursor position); flags are raw
 * MOUSEEVENTF_* combos; data carries the wheel delta for
 * MOUSEEVENTF_WHEEL. Events queue to the same ring the touch bridge
 * uses. A MOVE event also repositions the compositor's cursor layer. */
void winios_pointer(int x, int y, unsigned int flags, unsigned int data);

/* Reposition the rendered cursor arrow (desktop px). Usually implied
 * by winios_pointer(MOVE); exposed for initial placement. */
void winios_cursor_move(int x, int y);

/* Library front end hooks. How many GDI window images the desktop
 * compositor has shown (a desktop session's first frame); hide or show the
 * compositor view (1 when there was one to change); and a window point
 * (points, main thread) to desktop pixels through the compositor's own
 * mapping (0 when there is no desktop). */
unsigned long long winios_surface_present_count(void);
int winios_compositor_set_hidden(int hidden);

/* Game-mode windows (Winios.m). The window a game session's swapchain
 * presents from (IOSDisplayShim) is never drawn as a GDI window; a Wine
 * session start clears the overlay. */
void winios_note_game_metal_hwnd(void *hwnd);
void winios_session_reset(void);
int winios_desktop_point_from_window(double wx, double wy, int *px, int *py);

/* Top-level window census, for the starting screen of a Madeira Dock start
 * (DockStartScreen.swift). A Dock start is a desktop session, and the
 * starting screen used to go away on the desktop's first GDI frame, so the
 * user watched the Dock host's console window instead of the game. The app
 * keeps the starting screen until a window of the started game is up, and
 * needs to know, per top-level window: is it shown, how big, has it put a
 * frame on screen, and which program owns it.
 *
 * Fed from the driver hooks on the window's own Wine thread (WindowPosChanged,
 * the GDI flush, DestroyWindow, the desktop-mode swapchain), so nothing polls
 * win32u. Costs one atomic load per hook while off; the app turns it on only
 * for a Dock start's starting screen. `image` is the owning process's
 * executable path as the server recorded it, lower case, without the NT
 * "\??\" prefix ("" when it could not be read). Only top-level windows are
 * listed. */
#define WINIOS_CENSUS_MAX 64
#define WINIOS_CENSUS_IMAGE 264
struct winios_census_window {
    unsigned long long hwnd;
    int x, y, w, h;               /* visible rect, desktop pixels */
    unsigned int pid;             /* owning Windows process id, 0 = unknown */
    unsigned int presents;        /* GDI frames this window put on screen */
    unsigned char visible;        /* WS_VISIBLE, not minimized, non-empty rect */
    unsigned char metal;          /* a D3D swapchain presents into it (DXMT) */
    unsigned char shown_once;     /* has been shown at least once */
    unsigned char restore_sent;   /* born minimized; SC_RESTORE posted */
    char image[WINIOS_CENSUS_IMAGE];
};

/* Main thread. on=1 starts an empty census (and forgets cached process paths,
 * whose ids a new session may reuse); on=0 stops and empties it. */
void winios_window_census_enable(int on);

/* Main thread. Copies up to `max` entries; returns how many were copied. */
int winios_window_census(struct winios_census_window *out, int max);

#ifdef __cplusplus
}
#endif

#endif

/* ml649: runtime diagnostic switch (defined in ntdll-unix/virtual_ios.c, which
 * links into the same Mach-O). Default OFF = quiet/fast. Toggling live lets
 * loud and quiet be compared inside ONE run, same scene, same thermal state —
 * something two separate builds can never give you. */
void madeira_set_diag_enabled(int on);
int  madeira_get_diag_enabled(void);
