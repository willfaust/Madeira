#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""The library page's sections (app/Madeira/Library.swift and SteamGames.swift), on the host.

Source checks that the library page is laid out as the fork's sectioned library:
Steam (the games being downloaded and the games Steam installed, collapsed by the
title), its Not installed group (folding on its own), then Other games (the
games you added, with Add a game); one grid without the Steam section; the
texts; the collapse switch MADEIRA_LIBRARY_COLLAPSE and the remembered states;
search and layout apply to every section; pull to refresh; the log line.
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
games = (app / 'SteamGames.swift').read_text()
docs = (root / 'docs/LIBRARY.md').read_text()
steam_docs = (root / 'docs/STEAM_LIBRARY.md').read_text()

view = between(library, 'struct LibraryView: View {', 'struct ExecutableBrowser: View {')
page = between(view, '    private var library: some View {', '    private func cells(')
section = between(games, 'struct SteamGamesSection: View {', 'struct SteamSignInCard: View {')
body = between(section, '    var body: some View {', '    private func cell(')

# ------------------------------------------------------------------ order of the page
steam_at = page.index('SteamGamesSection(search: search, layout: layout, sort: sort, width: viewport.size.width,')
others_at = page.index('LibrarySectionHeader(title: "Other games"')
# The Desktop button is LibraryView.desktopButton (both grids show it).
require(page.index('desktopButton') < steam_at < others_at and 'Label("Desktop", systemImage: "desktopcomputer")' in view,
        'page order: Desktop, then Steam, then Other games')
require('let steamFirst = MadeiraDock.enabled && SteamGamesSection.hasInstalled' in page[:steam_at]
        and 'part: .installed, open: { selected = $0 })' in page[steam_at:others_at]
        and 'if SteamGamesSection.shown {' in page[steam_at:others_at],
        'Other games is a section exactly when the Steam section is shown; installed Steam games come first')
require('part: steamFirst ? .notInstalled : .all, open: { selected = $0 })' in page[others_at:]
        and 'if MadeiraDock.enabled {' in page[others_at:],
        'Not installed follows Other games; with nothing installed the whole Steam section does')
single = page[others_at:]
require('ContentUnavailableView("Make yourself at home"' in single and single.count('cells(entries, width: viewport.size.width)') == 2,
        'without the Steam section: one grid of the games you added, or the empty-library message')
require('.refreshable { await SteamGamesSection.refresh() }' in page, 'pull down on the library refreshes the Steam section')

# ------------------------------------------------------------------ Other games
others = between(page, 'LibrarySectionHeader(title: "Other games"', '} else if model.entries.filter(')
require('count: entries.count' in others and 'collapsed: SteamGamesSection.collapsible ? $hideOthers : nil' in others,
        'Other games: count and a collapsible title (MADEIRA_LIBRARY_COLLAPSE)')
require('Label("Add a game"' not in others and '{ EmptyView() }' in others and 'browser = true' in page,
        'Other games: no Add a game button of its own; the + in the navigation bar opens the executable browser')
require('"Copy a game\'s folder into Madeira › wine › drive_c with the Files app, then tap + and choose its .exe."' in others
        and '"No other games match your search."' in others, 'Other games: empty and no-match texts')
require(others.index('if hideOthers && SteamGamesSection.collapsible {') < others.index('} else if entries.isEmpty {')
        < others.index('cells(entries, width: viewport.size.width)'), 'Other games: collapsed, empty, then the games')
require('@AppStorage("madeiraLibraryHideOthers") private var hideOthers = false' in view, 'Other games: remembered collapsed state')
entries = between(view, 'private var entries: [LibraryEntry] {', 'var body: some View {')
require('$0.desktop != true' in entries and '$0.steamAppID == nil' in entries
        and 'localizedCaseInsensitiveContains(search)' in entries,
        'Other games: the games you added (no Steam game, no desktop), filtered by the search')
require('LibraryCells(items: items, layout: layout, width: viewportWidth)' in view, "Other games: the library's layout")

# ------------------------------------------------------------------ Steam and Not installed
require('LibrarySectionHeader(title: "Steam", count: installed.count,' in body and
        'collapsed: collapsible ? $hideInstalled : nil)' in body, 'Steam: installed count and a collapsible title')
require('if steam.refreshing { ProgressView().accessibilityLabel("Refreshing Steam library") }' in body,
        'Steam: a progress indicator while the library refreshes')
require('@AppStorage("madeiraLibraryHideInstalled") private var hideInstalled = false' in section and
        '@AppStorage("madeiraSteamShowUninstalled") private var showUninstalled = true' in section,
        'Steam: remembered states (installed shown, Not installed open by default)')
require('static var collapsible: Bool { MadeiraConfig.flag("MADEIRA_LIBRARY_COLLAPSE") }' in section,
        'MADEIRA_LIBRARY_COLLAPSE (on by default) makes the titles collapsible')
order = [body.index('LibrarySectionHeader(title: "Steam"'), body.index('SteamSignInCard { showSignIn = true }'),
         body.index('if hideInstalled && collapsible {'),
         body.index('LibraryCells(items: groups.downloading + installed, layout: layout, width: width)'),
         body.index('"Pull down to load your Steam library."'), body.index('Text("Not installed").font(.headline)'),
         body.index('LibraryCells(items: groups.notInstalled, layout: layout, width: width)')]
require(order == sorted(order), 'Steam order: title, sign-in, downloading + installed, empty text, Not installed')
require('"No Windows games were found in this Steam library."' in body, 'Steam: empty-library text')
require('} else if signedIn && !steam.refreshing && groups.notInstalled.isEmpty && search.isEmpty {' in body,
        'Steam: the empty text only when signed in, loaded, nothing owned to install and no search')
require('if part != .installed && signedIn && !groups.notInstalled.isEmpty {' in body and 'if showUninstalled {' in body
        and '.accessibilityValue(showUninstalled ? "Shown" : "Hidden")' in body,
        'Not installed: signed in, folds on its own, not with the Steam title')
require('let items = SteamGamesRules.items(installed: model.games, owned: owned, search: search)' in body and
        'SteamGamesRules.groups(items, downloading: Set(steam.downloads.keys))' in body and
        'SteamGamesRules.sorted(groups.installed, by: sort, recorded: recorded)' in body,
        "Steam: the search, the groups and the library's Sort by apply")
card = between(games, 'struct SteamSignInCard: View {', '// MARK: - Artwork')
require('"Sign in to Steam"' in card and '"See your Steam games here and install them without leaving Madeira."' in card,
        'the sign-in card')
cell = between(games, 'struct SteamGameCell: View {', '/// Progress, speed and the state of one download.')
require('if list && dense {' in cell and '} else if list {' in cell, "Steam cards: the library's list and compact list rows")
require('SteamGamesSection.shown' in view and '[library-sections] native-steam=' in view, 'log line [library-sections]')
require(re.search(r'\[library-sections\][^"]*\\\((?!SteamOwnedLibrary\.enabled|SteamGamesSection\.)', view) is None,
        'the log line has flags only')

# ------------------------------------------------------------------ docs
require('MADEIRA_LIBRARY_COLLAPSE' in docs and '**Other games**' in docs and '**Not installed**' in docs,
        'docs/LIBRARY.md: the sections and the switch')
require('Pull down' in steam_docs, 'docs/STEAM_LIBRARY.md: pull down to refresh')

if failures:
    print(f'check-library-sections: {failures} FAILED')
    sys.exit(1)
print('check-library-sections: PASS')
