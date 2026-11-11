#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""The store sections (app/Madeira/NewLook.swift and SteamGames.swift), on the host.

Source checks that the Stores tab lists every store's section and Other games, and that the
Steam section keeps its parts: title, sign-in card, downloading games, empty text, Not installed
(folding on its own) and the installed games folded below; Other games is the games you added
with Add a game; pull to refresh on the Library tab; the texts and remembered states.
The old zoomable grid, store tabs, collapsible titles and MADEIRA_LIBRARY_COLLAPSE/TABS
switches were removed with the old design.
The rules behind the groups and the sort are compiled and run by
check-steam-games.py.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def between(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i)]


library = (app / 'Library.swift').read_text()
newlook = (app / 'NewLook.swift').read_text()
games = (app / 'SteamGames.swift').read_text()
docs = (root / 'docs/LIBRARY.md').read_text()
steam_docs = (root / 'docs/STEAM_LIBRARY.md').read_text()

section = between(games, 'struct SteamGamesSection: View {', 'struct SteamSignInCard: View {')
body = between(section, '    var body: some View {', '    private func cell(')

# ------------------------------------------------------------------ the Stores tab
content = between(newlook, '    @ViewBuilder private var content: some View {\n        switch store {', '    /// Other games:')
for case, view in (('steam', 'SteamGamesSection'), ('epic', 'EpicGamesSection'), ('gog', 'GOGGamesSection'),
                   ('itch', 'ItchGamesSection'), ('ea', 'EAGamesSection')):
    require(f'case .{case}: {view}(search: ""' in content, f'Stores: the {case} page is its own section')
require('case .other: otherGames' in content, 'Stores: Other games is the last page')
require('case steam, epic, gog, itch, ea, other' in newlook, 'Stores: Other games comes after every store')
require('.refreshable { await refresh() }' in newlook
        and 'NewLookScrollPage(refresh: { await SteamGamesSection.refresh() }' in library,
        'pull down on the Library tab refreshes the Steam section (and the other stores)')

# ------------------------------------------------------------------ Other games
others = between(newlook, '    private var otherGames: some View {', '/// The new look\'s question over every tab')
require('title: L("Add a game")' in others and 'action: add' in others, 'Other games: Add a game button')
require('"Import a game\'s folder, a .zip or .7z, or an .exe, or choose one already on this device."' in others
        and 'if games.isEmpty {' in others, 'Other games: empty text')
require('NewLookStore.other.prefix' in others and 'open(game.entry)' in others, 'Other games: the games you added, each opens its page')
added = between(newlook, 'static func added()', 'static func all(search:')
require('entry.desktop != true' in added and 'entry.listedInLibrary' in added and 'entry.steamAppID == nil' in added,
        'Other games: the games you added (no Steam game, no desktop)')

# ------------------------------------------------------------------ Steam and Not installed
require('LibrarySectionHeader(title: "", count: nil)' in body and 'LibrarySectionHeader(title: "Steam"' not in body,
        'Steam: no title row of its own (the store page names the store); the spinner and Workshop stay')
require('if steam.refreshing { ProgressView().accessibilityLabel("Refreshing Steam library") }' in body,
        'Steam: a progress indicator while the library refreshes')
require('@AppStorage("madeiraSteamShowUninstalled") private var showUninstalled = true' in section and
        '@AppStorage("madeiraNewLookSteamShowInstalled") private var showInstalled = false' in section,
        'Steam: remembered states (Not installed open by default, installed folded away at first)')
require('collapsible' not in section, 'Steam: no collapsible title any more')
order = [body.index('LibrarySectionHeader(title: "", count: nil)'), body.index('SteamSignInCard { showSignIn = true }'),
         body.index('LibraryCells(items: top, layout: layout, width: width)'),
         body.index('"Pull down to load your Steam library."'), body.index('Text("Not installed").font(.headline)'),
         body.index('LibraryCells(items: groups.notInstalled, layout: layout, width: width)'),
         body.index('NewLookInstalledHeader(id: "steam-installed"')]
require(order == sorted(order), 'Steam order: spinner row, sign-in, downloading, empty text, Not installed, installed (folded)')
require('let fold = part == .all' in body and 'let top = fold ? groups.downloading : groups.downloading + installed' in body,
        'Steam: the store page lists downloading games first and folds the installed ones below')
require('"No Windows games were found in this Steam library."' in body, 'Steam: empty-library text')
require('} else if signedIn && !steam.refreshing && groups.notInstalled.isEmpty && installed.isEmpty && search.isEmpty {' in body,
        'Steam: the empty text only when signed in, loaded, nothing owned to install and no search')
require('if part != .installed && signedIn && !groups.notInstalled.isEmpty {' in body and 'if showUninstalled {' in body
        and '.accessibilityValue(showUninstalled ? "Shown" : "Hidden")' in body,
        'Not installed: signed in, folds on its own')
require('let items = SteamGamesRules.items(installed: model.games, owned: owned, search: search)' in body and
        'SteamGamesRules.groups(items, downloading: Set(steam.downloads.keys))' in body and
        'SteamGamesRules.sorted(groups.installed, by: sort, recorded: recorded)' in body,
        "Steam: the search, the groups and the sort apply")
card = between(games, 'struct SteamSignInCard: View {', '// MARK: - Artwork')
require('"Sign in to Steam"' in card and '"See your Steam games here and install them without leaving Madeira."' in card,
        'the sign-in card')
cell = between(games, 'struct SteamGameCell: View {', '/// Progress, speed and the state of one download.')
require('if list && dense {' in cell and '} else if list {' in cell, "Steam cards: the list and compact list rows")

# ------------------------------------------------------------------ docs
require('**Other games**' in docs and '**Not installed**' in docs, 'docs/LIBRARY.md: the sections')
require('Pull down' in steam_docs, 'docs/STEAM_LIBRARY.md: pull down to refresh')

if failures:
    print(f'check-library-sections: {failures} FAILED')
    sys.exit(1)
print('check-library-sections: PASS')
