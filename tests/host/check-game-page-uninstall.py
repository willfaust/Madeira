#!/usr/bin/env python3
"""Uninstall on a Steam game's own page (SteamUninstallSection), not only on its Steam page.
Read from the sources.

1. Game details shows the section for a Steam game, as its last card,
   and closes the page without saving once the game is uninstalled.
2. Same rule as the Steam page's button: only a game Madeira downloaded (Dock's own library
   folder), not while a download runs; the same question before anything is deleted.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
lib = (root / "app/Madeira/Library.swift").read_text(encoding="utf-8")
steam = (root / "app/Madeira/SteamGames.swift").read_text(encoding="utf-8")
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


# Game details is the New look page (LibraryDetail.newLookPage): it decides as SteamUninstallSection does,
# and Uninstall is the last card, after Get Help, on its own.
help_card = lib[lib.index("@ViewBuilder private var lookHelp: some View {"):]
help_card = help_card[:help_card.index("/// A row's name and, under it, what it does")]
check("Game details shows it for a Steam game, as its last card, after Get Help",
      'lookRow("gp-uninstall", last: true, press: { confirmSteamUninstall = true })' in help_card
      and "if steamUninstallable != nil {" in help_card
      and help_card.index('lookRow("gp-help"') < help_card.index('lookRow("gp-uninstall"')
      and "SteamInstallPaths.isManaged(library: installed.library)" in lib and "steam.downloads[appID] == nil" in lib)
check("Game details asks first, then uninstalls and closes",
      help_card.index("isPresented: $confirmSteamUninstall") < help_card.index("if let installed = steamUninstallable { steam.uninstall(installed) }")
      < help_card.index("leaving = true; closePage()"))
start = steam.index("struct SteamUninstallSection: View {")
view = steam[start:steam.index("\n}\n", start)]
check("only a game Madeira manages, with no download running",
      "SteamInstallPaths.isManaged(library: $0.library)" in view and "managed, steam.downloads[appID] == nil" in view)
check("asks first, then uninstalls and closes the page",
      'confirmationDialog("Uninstall \\(entry.title)? Its downloaded files are deleted from where it is installed.' in view
      and view.index("steam.uninstall(installed)") < view.index("uninstalled()"))
check("the Steam page keeps its own button", 'Button("Uninstall", role: .destructive) { confirmUninstall = true }' in steam[steam.index("struct SteamEntrySection: View {"):])

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
