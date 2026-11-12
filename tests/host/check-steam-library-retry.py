#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Execute the production foreground refresh gate with synthetic session state."""
from pathlib import Path
import subprocess
import os
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/SteamOwnedLibrary.swift').read_text()
games = (root / 'app/Madeira/SteamGames.swift').read_text()


def block(text, header):
    start = text.index(header)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


method = block(source, '    func refreshAfterForeground()')
assert 'steam.reconcileSession(); steam.refreshAfterForeground()' in games
refresh = block(source, '    func refreshLibrary(interactive:')
assert refresh.index('guard Self.enabled') < refresh.index('lastLibraryRefreshAttempt = Date()') < refresh.index('refreshing = true')
swift = '''import Foundation
@MainActor final class Library {
    static var enabled = true
    var loadingCache = false
    var signedIn = true
    var refreshing = false
    var inSession = false
    var libraryUpdated: Date?
    var lastLibraryRefreshAttempt: Date?
    var attempts = 0
    var fail = true
    func refreshLibrary(interactive: Bool) async {
        precondition(!interactive, "foreground recovery must stay non-interactive")
        guard Self.enabled, signedIn, !refreshing, !inSession else { return }
        attempts += 1
        if !fail { libraryUpdated = Date() }
    }
''' + method + '''
}
@main struct Test {
    @MainActor static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
    @MainActor static func main() async {
        let library = Library()
        library.refreshAfterForeground()
        library.refreshAfterForeground()
        await settle()
        precondition(library.attempts == 1, "unloaded cache schedules one attempt, even before its task starts")
        library.refreshAfterForeground()
        await settle()
        precondition(library.attempts == 1, "failed attempt has a cooldown")
        library.lastLibraryRefreshAttempt = Date().addingTimeInterval(-70)
        library.refreshAfterForeground()
        await settle()
        precondition(library.attempts == 2, "failure retries after cooldown")
        library.lastLibraryRefreshAttempt = Date().addingTimeInterval(-70)
        library.fail = false
        library.refreshAfterForeground()
        await settle()
        precondition(library.attempts == 3 && library.libraryUpdated != nil, "later successful retry loads the library")
        library.lastLibraryRefreshAttempt = nil
        library.refreshAfterForeground()
        await settle()
        precondition(library.attempts == 3, "fresh cache does not fetch again")
        library.libraryUpdated = Date().addingTimeInterval(-7 * 3600)
        library.refreshAfterForeground()
        await settle()
        precondition(library.attempts == 4, "stale cache refreshes")
        let warming = Library()
        warming.loadingCache = true
        warming.refreshAfterForeground()
        await settle()
        precondition(warming.attempts == 0 && warming.lastLibraryRefreshAttempt == nil,
                     "activation cannot race the initial cache read into a full fetch")
        warming.libraryUpdated = Date()
        warming.loadingCache = false
        warming.refreshAfterForeground()
        await settle()
        precondition(warming.attempts == 0, "fresh cache avoids the network after the read")
        warming.libraryUpdated = nil
        warming.refreshAfterForeground()
        await settle()
        precondition(warming.attempts == 1, "missing/stale cache still fetches after the read")
        for gate in 0..<4 {
            let blocked = Library()
            if gate == 0 { Library.enabled = false }
            if gate == 1 { blocked.signedIn = false }
            if gate == 2 { blocked.refreshing = true }
            if gate == 3 { blocked.inSession = true }
            blocked.refreshAfterForeground()
            await settle()
            precondition(blocked.attempts == 0 && blocked.lastLibraryRefreshAttempt == nil,
                         "disabled, signed-out, refreshing and active-game states do not reserve an attempt")
            Library.enabled = true
        }
        print("PASS: unloaded/failure recovery, cooldown, coalescing, successful cache, stale cache and four blocking states")
    }
}
'''
private_root = Path.home() / 'tmp'
private_root.mkdir(mode=0o700, exist_ok=True)
private_root.chmod(0o700)
with tempfile.TemporaryDirectory(prefix='pi-steam-retry.', dir=private_root) as tmp:
    env = dict(os.environ, TMPDIR=tmp, TMP=tmp, TEMP=tmp)
    directory = Path(tmp)
    program = directory / 'retry.swift'
    executable = directory / 'retry'
    program.write_text(swift)
    subprocess.run(['swiftc', '-j', '1', '-parse-as-library', str(program), '-o', str(executable)], check=True, env=env)
    subprocess.run([str(executable)], check=True, env=env)
print('check-steam-library-retry: PASS')
