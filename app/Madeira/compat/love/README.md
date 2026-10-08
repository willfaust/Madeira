# compat/love/ — LuaJIT for LOVE games (not tracked)

`build/luajit-x64/build.sh` builds `lua51.dll` (GC64 LuaJIT, x86-64) here; it
is git-ignored. When a game loads an x64 LuaJIT that needs memory below 2 GB
(LuaJIT 2.0, or 2.1 without GC64), the wineserver maps this build in its place;
the game's own file is not changed (`build/wineserver/luajit_compat.c`).
Without it such games keep their stock LuaJIT, which fails on iOS.
