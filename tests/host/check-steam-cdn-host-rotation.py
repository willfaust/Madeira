#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Steam downloads: a content server leaves the chunk rotation only after repeated failures.

Compiles the real ContentHostHealth out of DepotDownloader.swift (extracted by
text, not copied) and drives it the way the downloader does: every chunk asks
for the order with its own seed, takes the first server and reports the result.

  1. no failures: first attempts spread evenly over the servers;
  2. one transient failure on 5 of 6 servers: still spread, none gets 0 (they
     used to collapse onto the one server with no failures);
  3. a server with the demotion count of failures is never first while others
     are healthy, and demoted servers are ordered by failure count;
  4. switch off (env.MADEIRA_STEAM_CDN_ROTATE = 0, which the app passes in as
     `rotates: false`): the old order (failure count first).

Also checks, by text, that the switch is read once in SteamOwnedLibrary (the
downloader has no switches of its own) and handed to both places that create a
ContentHostHealth. Needs swiftc; skipped with a note when it is missing and
not on macOS."""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/SwiftSteam/Content/DepotDownloader.swift').read_text()
library = (root / 'app/Madeira/SteamOwnedLibrary.swift').read_text()


def block(text, header):
    start = text.index(header)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


health = block(source, 'final class ContentHostHealth')
assert 'static var cdnRotationEnabled: Bool { SteamSignIn.flag("MADEIRA_STEAM_CDN_ROTATE", default: true) }' in library, \
    'the kill switch is read in SteamOwnedLibrary, on by default'
assert 'downloader.rotatesContentServers = Self.cdnRotationEnabled' in library, 'the switch is read once, when the downloader is created'
assert source.count('ContentHostHealth(rotates: rotatesContentServers)') == 2, 'both installs (game depots, workshop item) honour the switch'
assert 'MADEIRA_STEAM' not in source, 'the downloader has no switches of its own (check-steam-library)'
assert 'failures[host] == Self.demoteAfter' in health, 'the demotion log uses the shared constant'

swiftc = shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
if not os.path.exists(swiftc):
    if sys.platform == 'darwin':
        print('FAIL swiftc unavailable on the macOS build runner')
        sys.exit(1)
    print('note: swiftc unavailable; check-steam-cdn-host-rotation needs it')
    sys.exit(0)

stubs = '''import Foundation
// What ContentHostHealth takes from the app: its log.
enum SteamLog { static func event(_ line: String) { print(line) } }
'''

driver = '''
let hosts = (1...6).map { "https://cdn\\($0)" }
var failed = false
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failed = true }
}
func sorted(_ counts: [String: Int]) -> String {
    counts.sorted { $0.key < $1.key }.map { "\\($0.key.dropFirst(8))=\\($0.value)" }.joined(separator: " ")
}
// What the downloader does per chunk: ask for the order with the chunk's seed,
// fetch from the first server, report success. 600 chunks over 6 servers.
func firstAttempts(_ h: ContentHostHealth) -> [String: Int] {
    var counts: [String: Int] = [:]
    for seed in 0..<600 {
        let first = h.order(hosts, seed: seed)[0]
        counts[first, default: 0] += 1
        h.recordSuccess(first)
    }
    return counts
}
func fail(_ h: ContentHostHealth, _ index: Int, times: Int) {
    for _ in 0..<times { h.recordFailure(hosts[index], reason: "timeout") }
}

// 1. No failures: even spread.
do {
    let c = firstAttempts(ContentHostHealth())
    print("  no failures:", sorted(c))
    check(hosts.allSatisfy { c[$0] == 100 }, "1. no failures: 100 first attempts on each of 6 servers")
}

// 2. One transient failure on 5 of the 6 servers: no server is starved.
do {
    let h = ContentHostHealth()
    for i in 1..<hosts.count { fail(h, i, times: 1) }
    let c = firstAttempts(h)
    print("  one failure on 5 servers:", sorted(c))
    check(hosts.allSatisfy { (c[$0] ?? 0) > 0 }, "2. one failure on 5 of 6: every server still gets first attempts")
    check(hosts.allSatisfy { (c[$0] ?? 0) >= 50 }, "2. one failure on 5 of 6: spread stays roughly even (each >= 50 of 600)")
}

// 3. A server at the demotion count is never first while the others are healthy.
do {
    let h = ContentHostHealth()
    fail(h, 2, times: ContentHostHealth.demoteAfter)
    var firsts: [String: Int] = [:]
    var lastEvery = true
    for seed in 0..<600 {
        let order = h.order(hosts, seed: seed)
        firsts[order[0], default: 0] += 1
        if order.last != hosts[2] { lastEvery = false }
    }
    print("  cdn3 demoted:", sorted(firsts))
    check((firsts[hosts[2]] ?? 0) == 0, "3. a demoted server is never first while others are healthy")
    check(lastEvery, "3. a demoted server is last in every order")
    // Chunks whose rotation starts on the demoted server go to the next one, which
    // therefore carries two shares; the other four carry one.
    let others = hosts.filter { $0 != hosts[2] }
    check(others.allSatisfy { (firsts[$0] ?? 0) >= 100 } && others.reduce(0, { $0 + (firsts[$1] ?? 0) }) == 600,
          "3. the five healthy servers carry all 600 first attempts, each at least its own 100")
}

// 3b. Below the demotion count a server keeps its rotation place; demoted servers sort by count.
do {
    let h = ContentHostHealth()
    fail(h, 1, times: ContentHostHealth.demoteAfter - 1)
    check(h.order(hosts, seed: 0) == hosts, "3b. just below the demotion count: the seed rotation is unchanged")
    fail(h, 3, times: ContentHostHealth.demoteAfter + 1)
    fail(h, 4, times: ContentHostHealth.demoteAfter)
    let order = h.order(hosts, seed: 0)
    print("  cdn4 at \\(ContentHostHealth.demoteAfter + 1), cdn5 at \\(ContentHostHealth.demoteAfter), cdn2 below:", order.map { String($0.dropFirst(8)) })
    check(order == [hosts[0], hosts[1], hosts[2], hosts[5], hosts[4], hosts[3]],
          "3b. demoted servers go after the others, fewer failures first (cdn5 before cdn4)")
    // Recovery: successes lower a server's count, and it rejoins the rotation below the demotion count.
    h.recordSuccess(hosts[4])
    check(h.order(hosts, seed: 0) == [hosts[0], hosts[1], hosts[2], hosts[4], hosts[5], hosts[3]],
          "3b. a server whose count drops below the demotion count rejoins the rotation")
}

// 4. Switch off (rotates: false): the old order, failure count first.
do {
    let h = ContentHostHealth(rotates: false)
    for i in 1..<hosts.count { fail(h, i, times: 1) }
    var c: [String: Int] = [:]
    for seed in 0..<600 {
        let first = h.order(hosts, seed: seed)[0]
        c[first, default: 0] += 1
        h.recordSuccess(first)
    }
    print("  switch off, one failure on 5 servers:", sorted(c))
    check(c[hosts[0]] == 600, "4. switch off: all 600 first attempts go to the one server with no failures (old order)")
    let g = ContentHostHealth(rotates: false)
    fail(g, 0, times: 1)
    fail(g, 1, times: ContentHostHealth.demoteAfter)
    check(g.order(hosts, seed: 0) == [hosts[2], hosts[3], hosts[4], hosts[5], hosts[0], hosts[1]],
          "4. switch off: servers are ordered by failure count first, then rotation (old order)")
}

print(failed ? "FAILED" : "PASS")
exit(failed ? 1 : 0)
'''

program = stubs + health + '\n' + driver
with tempfile.TemporaryDirectory(prefix='madeira-cdn-rotation-') as tmp:
    directory = Path(tmp)
    swift_file = directory / 'main.swift'
    executable = directory / 'rotation'
    swift_file.write_text(program)
    subprocess.run([swiftc, '-j', '1', str(swift_file), '-o', str(executable)], check=True)
    ok = subprocess.run([str(executable)]).returncode == 0
print('check-steam-cdn-host-rotation: ' + ('PASS' if ok else 'FAIL'))
sys.exit(0 if ok else 1)
