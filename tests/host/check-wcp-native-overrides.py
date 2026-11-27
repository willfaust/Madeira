#!/usr/bin/env python3
"""Host verification for the native .wcp override contract (stock side):

1. The Wine unix half as a component (app side):
   - app/Madeira/UnixHalf.swift names the entry points a component half must
     provide (the 8 madeira_unix_half_wineserver_* exports) and exposes the
     @_cdecl surface the bridges call, including madeira_wcp_dylib_path.
   - app/Madeira/WineServerBridge.m, WineProcessBridge.m, LogStore.swift and
     ContentView.swift route wineserver lifecycle/state through UnixHalf and
     fall back to the linked libwineserver.a when no component provides a half.

2. The Metal Shader Converter IR dylib override:
   - dxmt/src/winemetal/unix/winemetal_unix.c resolves libmadeira_ir_unix.dylib
     via madeira_wcp_dylib_path before falling back to the linked
     madeira_ir_convert.
   - build/dxmt-patches/0002-winemetal-ir-unix-wcp-override.patch is present
     (check-patch-stacks pins it to the tree).

3. The component install contract (WCPComponents.swift, WineProcessBridge.m):
   - the folder tokens (${system32} .. ${sysarm64ec}) a package's layout uses,
     and the per-package "environment" export.

Built artifacts, when present on disk, are checked against the same contract:
a half dylib must export the 8 wineserver entry points, and
libmadeira_ir_unix.dylib must export exactly _madeira_ir_convert.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

WS_EXPORTS = [
    "madeira_unix_half_wineserver_main",
    "madeira_unix_half_wineserver_log_set_file",
    "madeira_unix_half_wineserver_set_nls_dir",
    "madeira_unix_half_wineserver_inject_client_fd",
    "madeira_unix_half_wineserver_foreground_addr",
    "madeira_unix_half_wineserver_ready_addr",
    "madeira_unix_half_wineserver_log_quiet_addr",
    "madeira_unix_half_wineserver_set_ui_log_callback",
]

unix_half_swift = (ROOT / "app/Madeira/UnixHalf.swift").read_text()
for sym in WS_EXPORTS:
    assert f'"{sym}"' in unix_half_swift, f"UnixHalf.swift missing {sym}"
for cdecl in (
    "madeira_unix_half_prepare",
    "madeira_unix_half_start",
    "madeira_unix_half_set_log_file",
    "madeira_unix_half_set_main_i386",
    "madeira_unix_half_live_game_children",
    "madeira_unix_half_wineserver_start",
    "madeira_unix_half_wineserver_set_log_file",
    "madeira_unix_half_wineserver_set_nls_dir_bridge",
    "madeira_unix_half_wineserver_inject_fd",
    "madeira_unix_half_wineserver_set_foreground",
    "madeira_unix_half_wineserver_ready_ptr",
    "madeira_unix_half_symbol",
    "madeira_wcp_dylib_path",
):
    assert f'@_cdecl("{cdecl}")' in unix_half_swift, f"UnixHalf.swift missing @_cdecl {cdecl}"

ws_bridge = (ROOT / "app/Madeira/WineServerBridge.m").read_text()
for fn in (
    "madeira_unix_half_wineserver_start",
    "madeira_unix_half_wineserver_set_log_file",
    "madeira_unix_half_wineserver_set_nls_dir_bridge",
    "madeira_unix_half_wineserver_set_foreground",
    "madeira_unix_half_wineserver_ready_ptr",
):
    assert fn in ws_bridge, f"WineServerBridge.m missing {fn}"
assert "wineserver_set_nls_dir(nlsDir.UTF8String)" in ws_bridge, \
    "WineServerBridge.m must fall back to libwineserver.a when no component half is installed"

proc_bridge = (ROOT / "app/Madeira/WineProcessBridge.m").read_text()
assert "madeira_unix_half_wineserver_inject_fd" in proc_bridge
assert "madeira_unix_half_start" in proc_bridge

log_store = (ROOT / "app/Madeira/LogStore.swift").read_text()
assert "UnixHalf.setWineserverUILogCallback" in log_store

content_view = (ROOT / "app/Madeira/ContentView.swift").read_text()
assert "UnixHalf.setWineserverLogQuiet(1)" in content_view
assert "UnixHalf.setWineserverLogQuiet(0)" in content_view

# The libmadeira_ir_unix.dylib override.
wm_c = (ROOT / "dxmt/src/winemetal/unix/winemetal_unix.c").read_text()
assert '"libmadeira_ir_unix.dylib"' in wm_c
assert '"madeira_wcp_dylib_path"' in wm_c
assert '"madeira_ir_convert"' in wm_c
assert (ROOT / "build/dxmt-patches/0002-winemetal-ir-unix-wcp-override.patch").is_file()

# The install layout contract.
wcp_swift = (ROOT / "app/Madeira/WCPComponents.swift").read_text()
for token in (
    "system32", "syswow64", "sysx64", "sysaa64", "aarch64", "sysarm64ec",
):
    assert token in wcp_swift, f"WCPComponents.swift missing folder token {token}"
assert "environment" in wcp_swift, "WCPComponents.swift must export a package's environment"

# If the dylibs are already built on disk, verify their Mach-O export tables directly.
nt_dylib = ROOT / "build/ntdll-unix/libntdll_unix.dylib"
if nt_dylib.is_file():
    out = subprocess.check_output(["nm", "-gU", str(nt_dylib)], text=True)
    exported = {line.split()[-1] for line in out.splitlines() if len(line.split()) >= 3}
    for sym in WS_EXPORTS:
        assert f"_{sym}" in exported, f"_{sym} not exported by built libntdll_unix.dylib"
    print(f"PASS: built libntdll_unix.dylib exports all {len(WS_EXPORTS)} wineserver entry points ({len(exported)} total)")

ir_dylib = ROOT / "build/dxmt-ios/libmadeira_ir_unix.dylib"
if ir_dylib.is_file():
    out = subprocess.check_output(["nm", "-gU", str(ir_dylib)], text=True)
    exported = sorted({line.split()[-1] for line in out.splitlines() if len(line.split()) >= 3})
    assert exported == ["_madeira_ir_convert"], f"unexpected exports in libmadeira_ir_unix.dylib: {exported}"
    print("PASS: built libmadeira_ir_unix.dylib exports only _madeira_ir_convert")

print("PASS: all native .wcp override invariants verified")
