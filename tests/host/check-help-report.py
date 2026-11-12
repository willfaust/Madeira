#!/usr/bin/env python3
"""Get Help from Claude's player report (app/Madeira/HelpReport.swift).

A Python copy of HelpReport.read, using the tag lists and limits read from the
Swift source, run on a made-up session log:
  * key lines keep the tags the guide's section 6 relies on, count repeats
    once with (xN) and leave out periodic diagnostics and harmless DLLs;
  * the tail ends where Wine exited, not at the idle lines after it;
  * a long log stays within the byte budget, keeping its start and its end.

Then, where a Swift compiler is installed, compiles HelpReport.swift,
PrivacyScrub.swift and LogSummary.swift (with Madeira Dock's report parser)
and runs the same checks on the real code (SKIP without one; --require-swift
makes that a failure).

Optional: pass real logs (files or folders) to print the report size for each,
as was done on the 122 logs players posted in Discord (Oct 30 - Nov 5, 2026:
1 to 20 MB each, 20 to 34 KB of report each).
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'app/Madeira/HelpReport.swift').read_text(encoding='utf-8')
summary = (root / 'app/Madeira/LogSummary.swift').read_text(encoding='utf-8')
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def strings(start, end):
    block = src[src.index(start):src.index(end)]
    return re.findall(r'"((?:[^"\\]|\\.)*)"', block)


key_tags = strings('static let keyTags', 'static let noiseTags')
noise_tags = strings('static let noiseTags', 'static let endMarkers')
end_markers = strings('static let endMarkers', 'static let maxKeyLines')
limits = {k: int(v.replace('_', '')) for k, v in re.findall(r'static let (\w+) = ([0-9_]+)\n', src)}
harmless_block = summary[summary.index('static let harmlessDLLs'):summary.index('static let helperPrograms')]
harmless = re.findall(r'"([^"]+)"', harmless_block)
check(len(key_tags) > 30 and len(noise_tags) > 20 and end_markers, 'tag lists read from the Swift source')
check(all(t == t.lower() for t in key_tags + noise_tags + end_markers), 'tags are lower-case (lines are matched lower-cased)')
check(not set(key_tags) & set(noise_tags), 'no tag is both a key line and noise')
check(set(limits) >= {'maxKeyLines', 'keptFromStart', 'maxKeyBytes', 'tailCount', 'maxTailBytes', 'lineWidth'},
      f'limits read ({sorted(limits)})')

num = re.compile(r'0x[0-9A-Fa-f]+|\b(?=[0-9A-Fa-f]*[0-9])[0-9A-Fa-f]{4,}\b|[0-9]+')


def normalized(line):
    if line.startswith('[') and ']' in line and line.index(']') <= 14:
        line = line[line.index(']') + 1:].lstrip(' ')
    return num.sub('#', line)


def clipped(line):
    w = limits['lineWidth']
    return line[:w] + ' ...' if len(line) > w else line


def read(lines):
    entries, index, ring, at_exit, found, noise = [], {}, [], None, 0, 0
    for line in lines:
        lower = line.lower()
        if any(t in lower for t in noise_tags):
            noise += 1
            continue
        ring.append(clipped(line))
        ring = ring[-limits['tailCount']:]
        if any(m in lower for m in end_markers):
            at_exit = list(ring)
        if not any(t in lower for t in key_tags):
            continue
        if '[dll-missing]' in lower and any(h in lower for h in harmless):
            continue
        found += 1
        k = normalized(line)
        if k in index:
            entries[index[k]][1] += 1
        else:
            index[k] = len(entries)
            entries.append([clipped(line), 1])
    key = [t + (f' (x{c})' if c > 1 else '') for t, c in entries]
    mx, start = limits['maxKeyLines'], limits['keptFromStart']
    if len(key) > mx:
        key = key[:start] + [f'... {len(key) - mx} more key lines left out here ...'] + key[-(mx - start):]
    size = sum(len(k.encode()) + 1 for k in key)
    dropped = 0
    while size > limits['maxKeyBytes'] and len(key) > start + 2:
        size -= len(key[start + 1].encode()) + 1
        del key[start + 1]
        dropped += 1
    if dropped:
        key.insert(start + 1, f'... {dropped} more key lines left out here ...')
    tail = at_exit if at_exit is not None else ring
    while sum(len(t.encode()) + 1 for t in tail) > limits['maxTailBytes']:
        tail = tail[1:]
    return key, tail, at_exit is not None, noise


log = ['[14:08:51.586] [INFO] [build] v0.2.0 (5)',
       '[14:08:51.586] [INFO] [device] model=iPhone18,1 idiom=phone os=iOS Version 27.0 ram=11722MB',
       '[14:08:52.000] [INFO] [game-cfg] pool-split=1']
log += [f'[14:09:{i % 60:02d}.000] [xp] 14:09 +{i} dt=325 cpu=137' for i in range(5000)]
log += [f'00f4:err:module:load_dll [dll-missing] L"winemac.drv" status=c0000135' for _ in range(3)]
log += [f'00f4:err:module:load_dll [dll-missing] L"d3dcompiler_47.dll" status=c0000135']
log += [f'D 178 Exception: Code: C0000005 Address: 16D{i:06X} AV WRITE of 121C{i:05X}' for i in range(40)]
log += ['wine: Call from 00000001601F5C9C to unimplemented function COMCTL32.dll.345, aborting',
        '[jit-pool] EXHAUSTED (anon RWX): want=0xf88000 bump=0x151e8000/0x27548000',
        '[WineProc] Wine exited with code 0 (caught by longjmp)']
log += [f'[footprint] rev=ml358 phys={i} MB' for i in range(400)] + [f'idle line {i}' for i in range(30)]
key, tail, at_exit, noise = read(log)
text = '\n'.join(key)
check('[build] v0.2.0' in text and '[device] model=iPhone18,1' in text and '[game-cfg] pool-split=1' in text,
      'build, device and settings lines are kept')
check('[xp]' not in text and noise == 5400, f'periodic diagnostics are left out ({noise} lines)')
check('winemac.drv' not in text and 'd3dcompiler_47.dll' in text, 'harmless missing DLLs are left out, others kept')
check(sum('Exception: Code: C0000005' in k for k in key) == 1 and '(x40)' in text,
      'one exception repeated at 40 addresses is one line with (x40)')
check('unimplemented function COMCTL32.dll.345' in text and '[jit-pool] EXHAUSTED' in text, 'the failure lines are kept')
check(at_exit and tail[-1].startswith('[WineProc] Wine exited') and not any('idle line' in t for t in tail),
      'the tail ends where Wine exited, not at the idle lines after it')

big = ['[build] v0.2.0 (5)'] + [f'0024:err:x:y failed step {"".join("ghijklmnop"[int(d)] for d in str(i))} ' + 'q' * 150 for i in range(3000)] \
      + ['wine: Unhandled page fault on write access to 00000000 at address 00B57AA9']
key, tail, _, _ = read(big)
size = sum(len(k.encode()) + 1 for k in key)
check(size <= limits['maxKeyBytes'] + 200 and key[0] == '[build] v0.2.0 (5)' and 'Unhandled page fault' in key[-1]
      and any('more key lines left out' in k for k in key),
      f'a long log stays within the budget ({size} bytes) and keeps its start and its end')
check(all(len(k) <= limits['lineWidth'] + 4 for k in key + tail), 'long lines are cut')

helper = (root / 'app/Madeira/ClaudeHelp.swift').read_text(encoding='utf-8')
check('LogSummary.Reader()' in src and 'reader.feed(line)' in src and 'LogSummary.text(log.facts' in src,
      "the summary comes from the same pass over the log, so it is always this log's")
check('static func chosenLog' in helper and 'hasSession(current)' in helper,
      "this run's log is used while it has a game in it, else the last game log")


swift_checks = r'''
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
func scrubbed(_ s: String) -> String { PrivacyScrub.line(s) }
assert(scrubbed("signed in as somebody@example.com ok").contains("<email>") || scrubbed("signed in as somebody@example.com ok").contains("<user>"))
assert(!scrubbed("connect to 84.17.33.201:27036 failed").contains("84.17.33.201"))
assert(scrubbed("listening on 127.0.0.1:27060") == "listening on 127.0.0.1:27060")
assert(scrubbed("LocalDevVPN 10.7.1.1") == "LocalDevVPN 10.7.1.1")
assert(scrubbed(#"image=L"C:\users\Tyler\AppData\x.exe""#) == #"image=L"C:\users\<user>\AppData\x.exe""#)
assert(scrubbed(#"C:\\users\\mobile\\AppData"#) == #"C:\\users\\mobile\\AppData"#)
assert(scrubbed("-AUTH_LOGIN=unused -AUTH_PASSWORD=4f0e8c7a1b2d43c5 -AUTH_TYPE=exchange") == "-AUTH_LOGIN=unused -AUTH_PASSWORD=<hidden> -AUTH_TYPE=exchange")
assert(scrubbed("\t\"PersonaName\"\t\t\"Cool Gamer Guy\"") == "\t\"PersonaName\"\t\t\"<hidden>\"")
assert(scrubbed("/Mewgenics/76561198012345678/logs") == "/Mewgenics/<steam-id>/logs")
assert(scrubbed("/var/mobile/Containers/Data/Application/C4650DA9-9FB4-4B3E-93A8-B20433D25453/Documents") == "<app>/Documents")
assert(scrubbed("System.Runtime (6.0.0.0) EOSSDK-Win64-Shipping-1.17.1.3.dll") == "System.Runtime (6.0.0.0) EOSSDK-Win64-Shipping-1.17.1.3.dll")
assert(scrubbed("D 178 Exception: Code: C0000005 Address: 16D71C1B8 AV WRITE of 121C798F8") == "D 178 Exception: Code: C0000005 Address: 16D71C1B8 AV WRITE of 121C798F8")

var lines = ["[14:08:51.586] [INFO] [build] v0.2.0 (5)",
             "[14:08:51.586] [INFO] [device] model=iPhone18,1 idiom=phone ram=11722MB",
             "[14:08:52.000] [INFO] [WineProc] Target exe: C:\\\\madeira\\\\dockhost.exe",
             "[14:08:52.100] [INFO] [steam] user somebody@example.com from 84.17.33.201"]
for i in 0..<3000 { lines.append("[14:09:00.000] [xp] 14:09 +\(i) dt=325") }
for _ in 0..<3 { lines.append("00f4:err:module:load_dll [dll-missing] L\"winemac.drv\" status=c0000135") }
for i in 0..<40 { lines.append("D 178 Exception: Code: C0000005 Address: 16D\(String(i, radix: 16))AB12 AV WRITE of 121C\(i)F") }
lines.append("wine: Call from 00000001601F5C9C to unimplemented function COMCTL32.dll.345, aborting")
lines.append("[WineProc] Wine exited with code 0 (caught by longjmp)")
for i in 0..<300 { lines.append("[footprint] phys=\(i) MB") }
lines.append("idle after the game")
let log = dir.appendingPathComponent("madeira-last-game-log.txt")
try! lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)

let part = HelpReport.read(log)
let key = part.key.joined(separator: "\n")
assert(part.lines == lines.count, "\(part.lines) lines")
assert(key.contains("[build] v0.2.0") && key.contains("unimplemented function COMCTL32.dll.345"))
assert(!key.contains("[xp]") && !key.contains("winemac.drv"))
assert(part.key.filter { $0.contains("Exception: Code: C0000005") }.count == 1 && key.contains("(x40)"))
assert(part.tailEndsAtExit && part.tail.last!.hasPrefix("[WineProc] Wine exited") && !part.tail.contains("idle after the game"))
assert(part.facts.sawSession)

let text = HelpReport.text(build: "v0.2.0 (5)", device: "iPhone18,1, iOS 27.0, 11722 MB RAM", log: part,
                           game: "## Game: this game's config and settings\n# Bits: 64", cfg: "# comment\nMADEIRA_X=1\n\n")
assert(text.contains("Game in this report:") && text.contains("## Key log lines") && text.contains("## Last lines before Wine exited"))
assert(text.contains("MADEIRA_X=1") && !text.contains("# comment"))
assert(!text.contains("somebody@example.com") && !text.contains("84.17.33.201"))
assert(text.utf8.count < HelpReport.maxKeyBytes + HelpReport.maxTailBytes + 8_000)

let copy = dir.appendingPathComponent("copy.txt")
let changed = try! PrivacyScrub.copy(from: log, to: copy)
let copied = try! String(contentsOf: copy, encoding: .utf8)
assert(changed == 1 && copied.contains("<email>") && !copied.contains("84.17.33.201") && copied.contains("[xp] 14:09 +2999"))
var fromMiddle: [String] = []
LogLines.forEach(in: log, fromByte: 10) { fromMiddle.append($0) }
assert(fromMiddle.first == lines[1], "starts at the next whole line")
assert(LogLines.contains(in: log) { $0.contains("unimplemented function") })
assert(!LogLines.contains(in: log) { $0.contains("no such line") })
print("PASS: Swift: PrivacyScrub, LogLines and HelpReport behave as the Python copy does")
'''
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
if not Path(SWIFTC).exists():
    if '--require-swift' in sys.argv:
        check(False, 'Swift compiler available')
    else:
        print('SKIP: Swift compiler unavailable locally')
else:
    dock = (root / 'app/Madeira/MadeiraDock.swift').read_text()
    report = dock[dock.index('    struct Report {'):dock.index('    @MainActor private static var lastReport =')]
    scrub = (root / 'app/Madeira/PrivacyScrub.swift').read_text()
    with tempfile.TemporaryDirectory(prefix='madeira-help-report-') as directory:
        main = Path(directory) / 'main.swift'
        binary = Path(directory) / 'check'
        main.write_text('import Foundation\nenum MadeiraDock {\n' + report + '\n}\n'
                        + summary.replace('import Foundation\n', '', 1) + '\n'
                        + scrub.replace('import Foundation\n', '', 1) + '\n'
                        + src.replace('import Foundation\n', '', 1) + '\n' + swift_checks)
        built = subprocess.run([SWIFTC, str(main), '-o', str(binary)])
        check(built.returncode == 0, 'HelpReport.swift, PrivacyScrub.swift and LogSummary.swift compile together')
        if built.returncode == 0:
            ran = subprocess.run([str(binary), directory])
            check(ran.returncode == 0, 'the Swift checks pass')

args = [a for a in sys.argv[1:] if not a.startswith('--')]
if args:
    files = []
    for arg in args:
        p = Path(arg)
        files += sorted(f for f in p.rglob('*log*.txt')) if p.is_dir() else [p]
    sizes = []
    for f in files:
        if f.stat().st_size < 100_000:
            continue
        with open(f, 'rb') as fh:
            key, tail, _, _ = read(raw.decode('utf-8', 'replace').rstrip('\r\n') for raw in fh)
        n = sum(len(k.encode()) + 1 for k in key + tail)
        sizes.append(n)
        print(f'SIZE {f.stat().st_size // 1024:>7} KB -> {n // 1024:>3} KB  {f.name}')
    if sizes:
        sizes.sort()
        print(f'SIZE {len(sizes)} logs: min {sizes[0] // 1024} KB, median {sizes[len(sizes) // 2] // 1024} KB, max {sizes[-1] // 1024} KB')

print('PASS' if failures == 0 else f'FAIL ({failures})')
sys.exit(1 if failures else 0)
