#!/usr/bin/env python3
"""Front end Settings: display rate, swap tier and the sync engine.

1. Swift: compiles the production MadeiraConfig (app/Madeira/MadeiraConfig.swift)
   with HOME pointed at a scratch directory and checks MadeiraConfig.set():
   it keeps comments and other keys, replaces earlier lines for the key,
   removes a key for nil, migrates legacy madeira-*.txt files before creating
   madeira.cfg, and MadeiraConfig.flag() reads env.NAME lines. With the
   production SyncEngine (Library.swift): no key is Fastsync (the default);
   Fastsync removes both keys; Madsync writes inproc-sync = 1 and removes
   env.MADEIRA_FASTSYNC; Wine standard sync writes inproc-sync = 0 and removes
   env.MADEIRA_FASTSYNC; a hand-edited madeira.cfg reads back as the engine
   Wine will run (madsync wins over any MADEIRA_FASTSYNC value).
2. Source checks on app/Madeira/Library.swift and FPSOverlay.swift: the
   defaults are swap tier off, Fastsync and display-rate hold off, the
   Sync engine picker writes through SyncEngine.apply, game details offer the
   Fastsync-only switches greyed out unless Fastsync is chosen, launches export
   them only with Fastsync, and MADEIRA_RUNTIME_SETTINGS=0 hides both sections.

Run from anywhere; needs `swift` on PATH.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
config = (root / 'app/Madeira/MadeiraConfig.swift').read_text()
lib = (root / 'app/Madeira/Library.swift').read_text()
fps = (root / 'app/Madeira/FPSOverlay.swift').read_text()
failures = []


def block(text, header):
    p = text.index(header)
    a = text.index('{', p)
    n, b = 1, a + 1
    while n:
        n += (text[b] == '{') - (text[b] == '}')
        b += 1
    return text[p:b]


def check(cond, what):
    print(('PASS: ' if cond else 'FAIL: ') + what)
    if not cond:
        failures.append(what)


swift = config + '\nfunc L(_ text: String) -> String { text }   // Library.swift\'s lookup; English here\n' + block(lib,'enum SyncEngine: String, CaseIterable, Identifiable') + r'''
var failed = 0
func expect(_ cond: Bool, _ what: String) { print((cond ? "PASS: " : "FAIL: ") + what); if !cond { failed += 1 } }
let docs = MadeiraConfig.documents!
try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
let cfg = docs.appendingPathComponent("madeira.cfg")

// No madeira.cfg, one legacy file: set() migrates it first, so it is not hidden.
try! "2048\n".write(to: docs.appendingPathComponent("madeira-vram-mb.txt"), atomically: true, encoding: .utf8)
expect(!MadeiraConfig.present, "no madeira.cfg at the start")
expect(MadeiraConfig.set("swap-mb", "1024"), "set() creates madeira.cfg")
expect(MadeiraConfig.get("vram-mb") == "2048" && MadeiraConfig.get("swap-mb") == "1024", "legacy value migrated, new key written")

// Comments and other keys survive; the key's earlier lines are replaced.
try! "# my notes\nswap-mb = 4096\nwx = 1\nswap-mb=2048\nenv.MADEIRA_PROMOTE = 0\n".write(to: cfg, atomically: true, encoding: .utf8)
MadeiraConfig.set("swap-mb", "1024")
let text = try! String(contentsOf: cfg, encoding: .utf8)
expect(text.contains("# my notes") && text.contains("wx = 1"), "comments and other keys are kept")
expect(text.components(separatedBy: "swap-mb").count == 2 && MadeiraConfig.get("swap-mb") == "1024", "one line for the key, new value")
expect(!MadeiraConfig.flag("MADEIRA_PROMOTE", fallback: false), "env.MADEIRA_PROMOTE = 0 reads as off")
MadeiraConfig.set("env.MADEIRA_PROMOTE", "1")
expect(MadeiraConfig.flag("MADEIRA_PROMOTE", fallback: false), "env.MADEIRA_PROMOTE = 1 reads as on")
MadeiraConfig.set("env.MADEIRA_PROMOTE", nil)
expect(!MadeiraConfig.flag("MADEIRA_PROMOTE", fallback: false), "removed key: the fallback (off)")
expect(MadeiraConfig.flag("MADEIRA_SOMETHING_ELSE"), "unset flags use their fallback (on)")
MadeiraConfig.set("inproc-sync", "0")
expect(!MadeiraConfig.bool("inproc-sync", default: true), "madsync off is inproc-sync = 0")
MadeiraConfig.set("inproc-sync", nil)
expect(MadeiraConfig.bool("inproc-sync", default: true), "a removed key reads as the default")

// Sync engine: exactly one engine, and the keys Wine reads for it.
expect(SyncEngine.current == .fastsync, "no sync keys: Fastsync (the default)")
SyncEngine.apply(.madsync)
SyncEngine.apply(.fastsync)
expect(MadeiraConfig.get("inproc-sync") == nil && MadeiraConfig.get("env.MADEIRA_FASTSYNC") == nil
       && SyncEngine.current == .fastsync, "Fastsync: both keys removed (the default)")
SyncEngine.apply(.wine)
expect(MadeiraConfig.get("inproc-sync") == "0" && MadeiraConfig.get("env.MADEIRA_FASTSYNC") == nil
       && SyncEngine.current == .wine, "Wine standard sync: inproc-sync = 0, no MADEIRA_FASTSYNC")
SyncEngine.apply(.madsync)
expect(MadeiraConfig.get("inproc-sync") == "1" && MadeiraConfig.get("env.MADEIRA_FASTSYNC") == nil
       && SyncEngine.current == .madsync, "Madsync: inproc-sync = 1, no MADEIRA_FASTSYNC")
let kept = try! String(contentsOf: cfg, encoding: .utf8)
expect(kept.contains("# my notes") && kept.contains("wx = 1"), "engine changes keep comments and other keys")
MadeiraConfig.set("env.MADEIRA_FASTSYNC", "1")
expect(SyncEngine.current == .madsync, "hand-edited: madsync on wins over MADEIRA_FASTSYNC (Wine runs madsync)")
MadeiraConfig.set("inproc-sync", "0")
expect(SyncEngine.current == .fastsync, "hand-edited: inproc-sync = 0 with MADEIRA_FASTSYNC = 1 is Fastsync")
MadeiraConfig.set("env.MADEIRA_FASTSYNC", "0")
expect(SyncEngine.current == .wine, "hand-edited: MADEIRA_FASTSYNC = 0 without madsync is Wine standard sync")
MadeiraConfig.set("env.MADEIRA_FASTSYNC", nil)
expect(SyncEngine.current == .wine, "inproc-sync = 0 without MADEIRA_FASTSYNC stays Wine standard sync (as written before)")
MadeiraConfig.set("inproc-sync", nil)
expect(SyncEngine.current == .fastsync, "neither key: Fastsync")
exit(failed == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory() as tmp:
    sp = Path(tmp) / 'settings.swift'
    sp.write_text(swift)
    home = Path(tmp) / 'home'
    home.mkdir()
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
    r = subprocess.run(['swift', str(sp)], capture_output=True, text=True, env=env)
    sys.stdout.write(r.stdout)
    if r.returncode:
        sys.stdout.write(r.stderr[-4000:])
        failures.append('swift harness')

settings = lib[lib.index('struct RuntimeMemorySyncSettings: View'):lib.index('struct LibraryPointerSettings: View')]
display = lib[lib.index('struct DisplayRateSettings: View'):lib.index('struct RuntimeMemorySyncSettings: View')]
engine = block(lib, 'enum SyncEngine: String, CaseIterable, Identifiable')
detail = lib[lib.index('struct LibraryDetail: View'):lib.index('struct RuntimeMemorySyncSettings: View')]
apply_env = block(lib, 'func applyEnvironment()')
entry = block(lib, 'struct LibraryEntry: Codable, Identifiable')
check('return inproc == nil ? .fastsync : .wine' in engine, 'fastsync is the engine unless madeira.cfg says otherwise')
check('@State private var engine = SyncEngine.current' in settings and 'Picker("Sync engine"' in settings
      and 'SyncEngine.apply(choice)' in settings and 'ForEach(SyncEngine.allCases)' in settings,
      'Settings: the Sync engine picker writes through SyncEngine.apply')
check(['Madsync', 'Fastsync (default)', 'Wine standard sync'] == re.findall(r'case \.\w+: return (?:L\()?"([^"]+)"', engine),
      'the picker offers Madsync, Fastsync (default) and Wine standard sync, in that order')
check('"env.MADEIRA_FASTSYNC"' in settings.split('static let featuredKeys')[1].split(']')[0],
      'All settings leaves env.MADEIRA_FASTSYNC to the picker')
check('var fastSync: Bool?' in entry and 'var semaphoreFastPath: Bool?' in entry,
      'per-game fastsync switches are optional, so older library files decode')
check('Toggle("Fast synchronization"' in detail and 'Toggle("Fast semaphore waits (experimental)"' in detail
      and '.disabled(syncEngine != .fastsync)' in detail and '@State private var syncEngine = SyncEngine.current' in detail,
      'game details: Fast synchronization and Fast semaphore waits, greyed out unless the engine is Fastsync')
check('if syncEngine != .fastsync {' in detail and 'Choose Fastsync in Settings' in detail,
      'game details: a note says where to choose Fastsync')
check('if SyncEngine.current == .fastsync {' in apply_env and 'setenv("MADEIRA_FASTSYNC", fastSync == false ? "0" : mode, 1)' in apply_env
      and 'if let sem = semaphoreFastPath { setenv("MADEIRA_FASTSYNC_SEM", sem ? "1" : "0", 1) }' in apply_env
      and 'else { unsetenv("MADEIRA_FASTSYNC_SEM") }' in apply_env,
      'a launch exports the fastsync switches only when the engine is Fastsync')
check('static let swapChoices = [0, 1024, 2048, 3072, 4096]' in settings and 'mb > 0 ? String(mb) : nil' in settings,
      'swap tier: Off removes swap-mb (off by default)')
check('@State private var hold = ProMotionIntent.holdMaximum' in display
      and 'MadeiraConfig.set("env.MADEIRA_PROMOTE", on ? "1" : nil)' in display, 'display-rate hold writes env.MADEIRA_PROMOTE')
check('static var holdMaximum: Bool { MadeiraConfig.flag("MADEIRA_PROMOTE", fallback: false) }' in fps,
      'display-rate hold is off by default')
# Both sections sit inside the one MADEIRA_RUNTIME_SETTINGS block (each is also
# wrapped in the Settings search filter, settingsShow(...), since main d5a8e0a).
_rt = lib[lib.index('if MadeiraConfig.flag("MADEIRA_RUNTIME_SETTINGS") {'):]
_rt = _rt[:_rt.index('\n            }\n')]
check('DisplayRateSettings()' in _rt and 'RuntimeMemorySyncSettings(' in _rt,
      'MADEIRA_RUNTIME_SETTINGS=0 hides both sections')
print('check-runtime-settings:', 'FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
