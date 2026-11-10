#!/usr/bin/env python3
"""Every pseudo-process gets the "Message" window class; no Wine runs.

init_user (build/win32u-unix/class_ios.c) runs once per iOS process, so the
desktop and "Message" classes it registers exist only in the session's first
pseudo-process.  The wineserver keeps classes per process, so a later process
(a game the Dock starts) failed CreateWindow(L"Message", ..., HWND_MESSAGE)
with ERROR_INVALID_HANDLE, and winmm's devices thread with it (waveOut games
silent).  register_builtin_classes() runs once per pseudo-process and must
register the Message class before the other builtins, inside its lock and
after the already-done check.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
src = (root / "build/win32u-unix/class_ios.c").read_text()

start = src.index("void register_builtin_classes(void)\n{")
body = src[start:src.index("\n}\n", start)]

reg = body.index("register_builtin( &message_builtin_class );")
assert reg < body.index("register_builtins();"), "Message class must come with the per-process builtins"
assert body.index("pthread_mutex_lock( &builtin_lock );") < reg, "inside the lock"
assert body.index("return;") < reg, "after the already-registered check, so once per process"
assert src.index("message_builtin_class =") < start, "descriptor defined before use"

# init_user still registers both classes for the session process.
init_user = src[src.index("static void init_user(void)"):]
init_user = init_user[:init_user.index("\n}\n")]
assert "register_desktop_class();" in init_user

print("PASS: the Message class is registered once per pseudo-process with the builtins")
