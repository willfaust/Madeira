#!/usr/bin/env python3
"""One-time installs leave Microsoft's DirectX redistributable out (env.MADEIRA_INSTALL_SKIP_DIRECTX, on by default).
DXSETUP.exe ended with -9 in each player log that ran it after 0.2.0; Wine has its own d3dx9/d3dx10/d3dx11,
D3DCompiler, XAudio2, X3DAudio and XInput. Read from the sources (check-dock-installers.py runs the Swift when swiftc
is there).
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
src = (root / "app/Madeira/DockInstallers.swift").read_text(encoding="utf-8")
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text(encoding="utf-8")
swift_test = (root / "tests/host/check-dock-installers.py").read_text(encoding="utf-8")
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


start = src.index("    nonisolated static func runnable(")
run = src[start:src.index("\n    }\n", start)]
check("runnable leaves it out with skipDirectX",
      "skipDirectX: Bool = false" in run and 'if skipDirectX && isDirectXRedist(process) { return "Wine\'s own DirectX is used" }' in run)
start = src.index("    nonisolated static func isDirectXRedist(")
det = src[start:src.index("\n    }\n", start)]
check("found by DXSETUP.exe or Steam's CommonRedist DirectX key",
      'file == "dxsetup.exe"' in det and 'key.contains("\\\\commonredist\\\\directx")' in det)
check("the plan passes the switch",
      'let skipDirectX = flag("MADEIRA_INSTALL_SKIP_DIRECTX")' in src and "skipDotNet: skipDotNet, skipDirectX: skipDirectX) })" in src)
check("documented with the other switches", "/// - `MADEIRA_INSTALL_SKIP_DIRECTX`" in src)
check("catalog lists it, on by default", 'key: "env.MADEIRA_INSTALL_SKIP_DIRECTX", title: "", kind: .bool, defaultValue: "1"' in cat)
check("the Swift test covers it", "skipDirectX: true) == \"Wine's own DirectX is used\"" in swift_test)

start = src.index("    static func note(_ all: [DockInstallPlanItem]) -> String? {")
note = src[start:src.index("\n    }\n", start)]
check("the screens leave out what Wine provides",
      '"Wine\'s own .NET is used", "Wine\'s own DirectX is used"' in src
      and "all.filter { !($0.status == .unsupported && $0.reason.map(wineProvides.contains) == true) }" in note)
check("the restart words are untouched", "afterwards restart Madeira and start the game again." in src)

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
