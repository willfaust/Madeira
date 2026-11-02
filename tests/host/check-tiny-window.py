#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""[win-create] / [tiny-win] and env.MADEIRA_TINY_WINDOW_FIX; no Wine runs.

A 64-bit title opens as a 132x38 window -- Wine's minimum window size -- whose swapchain draws 1024x768,
and nothing ever sizes it. build/win32u-unix/driver_ios.c now logs what each top-level window was asked
for ([win-create]) and, for a swapchain window that stays under 160x120 while a 320x200 or larger picture
is drawn into it for 3 s, says so ([tiny-win]); with env.MADEIRA_TINY_WINDOW_FIX = 1 it also sizes that
window to the virtual screen (twice at most).

Checks: the production decision functions compiled and run on the host (the thresholds, the
switch: exactly "1"); the wiring in driver_ios.c (the poll runs from pProcessEvents, the create wrapper is
registered, nothing is resized unless the switch is on, at most two tries, 3 s of persistence, the screen
must be at least 320x200); the key in the settings catalog (when present).
The host run is skipped when no C compiler is found; the source checks still run.
"""
from pathlib import Path
import os, shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
drv = (root / "build/win32u-unix/driver_ios.c").read_text()

# --- the decision region, compiled and run ---------------------------------------------------------------
def function(signature):
    start = drv.index(signature)
    return drv[start:drv.index("\n}\n", start) + 3] + "\n"


region = (function("static int ios_tiny_fix_enabled(void)")
          + function("static int ios_tiny_window_is_tiny( int client_w, int client_h, int drawable_w, int drawable_h )"))
harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
""" + region + r"""
int main( int argc, char **argv )
{
    int i;
    printf( "%d\n", ios_tiny_fix_enabled() );
    for (i = 1; i + 3 < argc; i += 4)
        printf( "%d\n", ios_tiny_window_is_tiny( atoi( argv[i] ), atoi( argv[i + 1] ), atoi( argv[i + 2] ), atoi( argv[i + 3] ) ) );
    return 0;
}
"""
# (client w, client h, drawable w, drawable h) -> tiny?
cases = [
    (132, 38, 1024, 768, 1),    # a 132x38 client of a popup with a 1024x768 drawable
    (122, 2, 1440, 900, 1),     # the same window while it still had its caption (client 122x2, first drawable 1440x900)
    (126, 6, 1408, 648, 1),     # another title's window (client 126x6) with the picture its video settings name
    (159, 119, 320, 200, 1),    # the edges: one pixel under the client limits, exactly the drawable minimum
    (160, 38, 1024, 768, 0),    # 160 wide is not tiny
    (132, 120, 1024, 768, 0),   # 120 high is not tiny
    (132, 38, 319, 768, 0),     # a drawable under 320 wide: nothing a game means to show larger
    (132, 38, 1024, 199, 0),    # a drawable under 200 high
    (132, 38, 132, 38, 0),      # a small window with a small picture is a small window, not a failure
    (1024, 768, 1024, 768, 0),  # every window of a game that works
    (1408, 648, 1408, 648, 0),
    (0, 0, 1024, 768, 1),       # a zero client area under a big picture is as tiny as it gets
]
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    print("SKIP: the decision functions need a C compiler; source checks only")
else:
    with tempfile.TemporaryDirectory() as t:
        c = Path(t) / "tiny.c"
        c.write_text(harness)
        exe = Path(t) / "tiny"
        subprocess.run([cc, "-std=gnu11", "-Wall", "-Wno-unused-function", "-fsanitize=address,undefined",
                        str(c), "-o", str(exe)], check=True)

        def run(env, args):
            e = {k: v for k, v in os.environ.items() if k != "MADEIRA_TINY_WINDOW_FIX"}
            e.update(env)
            r = subprocess.run([str(exe)] + [str(a) for a in args], capture_output=True, text=True, env=e)
            assert r.returncode == 0, (env, r.returncode, r.stdout, r.stderr)
            return r.stdout.split()

        flat = [v for case in cases for v in case[:4]]
        out = run({}, flat)
        assert out[0] == "0", out                                   # unset: the switch is off
        assert [int(v) for v in out[1:]] == [case[4] for case in cases], (out, cases)
        for value, want in (("1", "1"), ("0", "0"), ("", "0"), ("2", "0"), ("11", "0"), ("true", "0"), ("on", "0")):
            assert run({"MADEIRA_TINY_WINDOW_FIX": value}, [])[0] == want, (value, want)   # exactly "1" turns it on

# --- the wiring in driver_ios.c ------------------------------------------------------------------------------
poll = drv[drv.index("static void ios_tiny_window_poll(void)"):]
poll = poll[:poll.index("\n}\n") + 3]
assert "if (!winios_swapchain_hwnd_at || !winios_swapchain_drawable || !winios_swapchain_slot_generation) return;" in poll   # a game-mode session never gets here
assert "st->hwnd != hwnd || st->gen != winios_swapchain_slot_generation( i )" in poll       # a reused HWND value is a new window
assert "if ((++ios_tiny_calls & 63) != 0) return;" in poll and "ios_tiny_next_ns = now + 500000000ull;" in poll
assert "get_window_thread( hwnd, NULL ) != GetCurrentThreadId()" in poll                   # only the window's own thread
assert "NtUserGetAncestor( hwnd, GA_PARENT ) != get_desktop_window()" in poll and "WS_CHILD" in poll and "WS_VISIBLE" in poll
assert "!winios_swapchain_drawable( hwnd, &dw, &dh )" in poll
assert "!ios_tiny_window_is_tiny( cw, ch, dw, dh )" in poll
assert "if (now - st->since_ns < 3000000000ull) continue;" in poll                         # three seconds of being tiny
assert "if (!ios_tiny_fix_enabled() || st->tries >= 2) continue;" in poll                  # off: log only; two tries at most
assert poll.index("[tiny-win] hwnd=%p style=%08x: the swapchain draws") < poll.index("NtUserSetWindowPos")
assert poll.index("if (!ios_tiny_fix_enabled() || st->tries >= 2) continue;") < poll.index("NtUserSetWindowPos")
assert "screen.right - screen.left < 320 || screen.bottom - screen.top < 200" in poll
assert "NtUserSetWindowPos( hwnd, 0, screen.left, screen.top, screen.right - screen.left," in poll
assert "SWP_NOZORDER | SWP_NOACTIVATE" in poll
assert poll.count("NtUserSetWindowPos") == 1
events = drv[drv.index("static BOOL winios_drv_process_events( DWORD mask )"):]
events = events[:events.index("\n}\n") + 3]
assert "ios_tiny_window_poll();" in events and "winios_pProcessEvents( mask )" in events
create = drv[drv.index("static BOOL winios_drv_create_window( HWND hwnd )"):]
create = create[:create.index("\n}\n") + 3]
assert "win->normal_rect" in create and "release_win_ptr( win );" in create
assert "WND_DESKTOP" in create and "WND_OTHER_PROCESS" in create
assert "[win-create] hwnd=%p style=%08x ex=%08x requested=" in create
assert "grown to the minimum window size" in create and "cut to the maximum window size" in create
assert "return winios_pCreateWindow ? winios_pCreateWindow( hwnd ) : TRUE;" in create     # the app's hook still runs
assert "NtUserSetWindowPos" not in create                                                    # the create wrapper only logs
assert "if (winios_pCreateWindow)        winios_user_driver.pCreateWindow        = winios_drv_create_window;" in drv

# --- the key ---------------------------------------------------------------------------------------------
catalog = root / "app/Madeira/ConfigCatalog.generated.swift"
if catalog.exists():
    assert 'ConfigOption(key: "env.MADEIRA_TINY_WINDOW_FIX", title: "Size a tiny game window to the screen", kind: .bool, defaultValue: "0"' in catalog.read_text(), \
        "the settings catalog lists env.MADEIRA_TINY_WINDOW_FIX (default 0)"

print("PASS: a swapchain window under 160x120 with a 320x200 or larger picture is the failing signature (the edges, "
      "working games and small-with-small untouched); only an exact 1 turns the resize on; it waits 3 s, runs on the "
      "window's own thread, at most twice, never without the drawable size and a 320x200 screen, and the create wrapper "
      "only logs and chains to the app's hook; the key is in the catalog")
