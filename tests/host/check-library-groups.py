#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""The library's Group by choice (app/Madeira/Library.swift), on the host.

1. Swift: compiles the production LibraryGrouping rules and checks the Last
   played, Installed and None groups, the Sort by order inside them, and the
   stored collapsed state.
2. Source checks: the options menu offers the four choices, Platform keeps the
   sections, the other choices list the games you added and Steam's games in
   one set of groups, and the controller's focus follows the page's order.

Synthetic data only.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
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
docs = (root / 'docs/LIBRARY.md').read_text()
rules = between(library, '// MARK: - Group by rules', '// MARK: - Group by view')
view = between(library, 'struct LibraryView: View {', 'struct ExecutableBrowser: View {')
grouped = between(library, 'struct LibraryGroupedGames<LocalCell: View>: View {', 'struct LibraryView: View {')

# ------------------------------------------------------------------ menu and page
menu = between(view, 'Picker("Group by", selection: $group) {', '}.pickerStyle(.menu)')
require(all(f'.tag("{tag}")' in menu for tag in ['played', 'installed', 'platform', 'none'])
        and all(f'Label("{label}"' in menu for label in ['Last played', 'Installed', 'Platform', 'None']),
        'options menu: Group by Last played, Installed, Platform or None')
require('@AppStorage("madeiraLibraryGroup") private var group = "platform"' in view,
        'Group by is remembered; Platform (the sections) by default')
page = between(view, '    private var library: some View {', '    private func cells(')
require(page.index('if group != "platform" {') < page.index('LibraryGroupedGames(grouping: group, search: search,')
        < page.index('let steamFirst = MadeiraDock.enabled && SteamGamesSection.hasInstalled'),
        'page: the other choices replace the sections, Platform keeps them')
require('let items = focusOrder' in page and 'guard group != "platform" else { return currentTab.shows(.other) ? entries : [] }' in view,
        "controller focus follows the grouped page's order")

# ------------------------------------------------------------------ grouped view
require('SteamGamesRules.items(installed: steamGames.games' in grouped
        and 'LibraryGrouping.Game(entry: entry, position: position)' in grouped,
        'grouped page: the games you added and Steam games together')
require('guard installed || (enabled && steam.signedIn) else { continue }' in grouped,
        'grouped page: not installed Steam games only while signed in')
require('open(library.steamEntry(installed, title: item.name))' in grouped and 'SteamGameSheet(appID: selection.id)' in grouped,
        'grouped page: installed games open Game details, others their download sheet')
require('SteamGamesSection.collapsible ? collapsedBinding(key) : nil' in grouped,
        'grouped page: group titles collapse with MADEIRA_LIBRARY_COLLAPSE')
require('Group by' in docs and 'Last played' in docs, 'docs/LIBRARY.md: Group by')

# ------------------------------------------------------------------ Swift
checks = r'''
import Foundation

@main
struct Checks {
    static var failures = 0
    static func require(_ ok: Bool, _ label: String) {
        print((ok ? "PASS: " : "FAIL: ") + label)
        if !ok { failures += 1 }
    }
    static func main() {
        typealias G = LibraryGrouping
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z")!
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        let a = UUID(), b = UUID()
        let games = [
            G.Game(source: .entry(a), title: "Alpha", installed: true, lastPlayed: ago(0.25), bytes: 10, position: 0),
            G.Game(source: .steam(10), title: "Bravo", installed: true, lastPlayed: ago(3), bytes: 500, position: 2),
            G.Game(source: .steam(20), title: "Charlie", installed: false, lastPlayed: ago(20), bytes: nil, position: nil),
            G.Game(source: .steam(30), title: "Delta", installed: true, lastPlayed: ago(90), bytes: 50, position: 1),
            G.Game(source: .entry(b), title: "Echo", installed: true, lastPlayed: nil, bytes: nil, position: 3),
        ]
        func titles(_ group: G.Group) -> [String] { group.games.map(\.title) }

        let played = G.groups(games, by: "played", sort: "name", now: now, calendar: calendar)
        require(played.map(\.title) == ["Today", "Past 7 days", "Past 30 days", "Earlier", "Never played"],
                "Last played: today, past 7 days, past 30 days, earlier, never played")
        require(played.map(titles) == [["Alpha"], ["Bravo"], ["Charlie"], ["Delta"], ["Echo"]], "Last played: each game in its bucket")
        let yesterdayLate = calendar.startOfDay(for: now).addingTimeInterval(-60)
        let edge = G.groups([G.Game(source: .steam(1), title: "Z", installed: true, lastPlayed: yesterdayLate)], by: "played",
                            sort: "name", now: now, calendar: calendar)
        require(edge.map(\.id) == ["week"], "Last played: a minute before midnight is not today")
        require(G.groups(Array(games.prefix(2)), by: "played", sort: "name", now: now, calendar: calendar).count == 2,
                "empty groups are left out")

        let installed = G.groups(games, by: "installed", sort: "size", now: now, calendar: calendar)
        require(installed.map(\.title) == ["Installed", "Not installed"], "Installed: installed, then not installed")
        require(installed.map(titles) == [["Bravo", "Delta", "Alpha", "Echo"], ["Charlie"]],
                "Installed: Sort by size inside each group, unknown size last")

        let none = G.groups(games, by: "none", sort: "added", now: now, calendar: calendar)
        require(none.count == 1 && none[0].title == nil, "None: one group without a title")
        require(titles(none[0]) == ["Echo", "Bravo", "Delta", "Alpha", "Charlie"],
                "None: Sort by recently added, games without a library entry last")
        require(titles(G.groups(games, by: "none", sort: "played", now: now, calendar: calendar)[0])
                == ["Alpha", "Bravo", "Charlie", "Delta", "Echo"], "Sort by last played, never played last")

        let twins = [G.Game(source: .steam(2), title: "Same", installed: true), G.Game(source: .steam(1), title: "Same", installed: true)]
        require(G.sorted(twins, by: "name").map(\.source) == [.steam(1), .steam(2)]
                && G.sorted(twins.reversed(), by: "name").map(\.source) == [.steam(1), .steam(2)],
                "ties are a total order: the same order whatever the input")

        let stored = G.storing(["played.today", "installed.notInstalled"])
        require(stored == "installed.notInstalled,played.today" && G.collapsed(stored) == ["played.today", "installed.notInstalled"]
                && G.collapsed("").isEmpty, "collapsed groups round-trip through their stored text")

        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all Group by Swift checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-library-groups-') as tmp:
    tmp = Path(tmp)
    (tmp / 'rules.swift').write_text('import Foundation\n'
                                     'func L(_ text: String) -> String { text }   // Library.swift\'s lookup; English here\n' + rules)
    (tmp / 'checks.swift').write_text(checks)
    exe = tmp / 'check'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-o', str(exe),
                            str(tmp / 'rules.swift'), str(tmp / 'checks.swift')], capture_output=True, text=True)
    require(build.returncode == 0, 'production Group by rules compile on the host')
    if build.returncode:
        sys.stdout.write(build.stderr[-4000:])
    else:
        run = subprocess.run([str(exe)], capture_output=True, text=True)
        sys.stdout.write(run.stdout)
        if run.returncode:
            sys.stdout.write(run.stderr[-4000:])
        require(run.returncode == 0, 'Group by Swift checks pass')

if failures:
    print(f'check-library-groups: {failures} FAILED')
    sys.exit(1)
print('check-library-groups: PASS')
