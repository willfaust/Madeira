#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Compile Madeira Dock's production report parser; synthetic reports only.

The host (madeira-dock) writes numeric stages to C:\\madeira-dock.txt.
Only whitelisted numeric fields and a 64-hex client fingerprint may be read;
anything else, partial final lines and oversized files are ignored.
"""
from pathlib import Path
import os, shutil, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
text = (root / 'app/Madeira/MadeiraDock.swift').read_text()
parser = text[text.index('    struct Report {'):text.index('    @MainActor private static var lastReport =')]
host = (root / 'madeira-dock/src/main.c')
checks = r'''
func parse(_ text: String) -> MadeiraDock.Report { MadeiraDock.parseReport(Data(text.utf8)) }
let fingerprint = String(repeating: "a", count: 64)
let report = parse("[steam-host] ml1820 client-sha256=\(fingerprint)\r\n[steam-host] ml1830 session-unsupported-client=1\r\n[steam-host] ml1830 probe-result=30\r\n")
assert(report.result == 30 && report.failure!.contains("client build"))
assert(report.fields["client-sha256"] == fingerprint)
assert(parse("[steam-host] ml1830 probe-result=30\n").failure!.contains("initialize"))
assert(parse("[steam-host] ml1830 probe-result=35\n").failure!.contains("license"))
assert(parse("[steam-host] ml1830 probe-result=0\n").failure == nil)
assert(parse("[steam-host] ml1830 probe-result=30").result == nil)
assert(parse("[steam-host] ml1830 probe-result=30\n[steam-host] ml1830 probe-result=0\n").result == 0)
assert(parse("[steam-host] ml1860 session-client-adapter=202601\n").fields["session-client-adapter"] == "202601")
let transport = parse("[steam-host] ml1870 session-handoff-stage=1\r\n[steam-host] ml1870 session-handoff-error=3\r\n[steam-host] ml1830 probe-result=37\r\n")
assert(transport.fields["session-handoff-stage"] == "1" && transport.fields["session-handoff-error"] == "3")
assert(transport.failure!.contains("sign-in transfer") && transport.failure!.contains("not checked"))
assert(parse("[steam-host] ml1830 session-native-handoff-app-mismatch=1\n[steam-host] ml1830 probe-result=37\n").failure!.contains("different launch"))
assert(parse("[steam-host] ml1990 ceg-result=10\n[steam-host] ml1830 probe-result=49\n").failure!.contains("busy"))
assert(parse("[steam-host] ml1970 launch-client-error=18\n[steam-host] ml1830 probe-result=45\n").failure!.contains("installed"))
assert(parse("[steam-host] ml2011 launch-config-wait=1\n[steam-host] ml1970 launch-client-error=22\n[steam-host] ml1830 probe-result=48\n").failure!.contains("configuration"))
let session = parse("[steam-host] ml1970 launch-client-error=35\n[steam-host] ml2015 launch-session-wait=35\n[steam-host] ml2015 launch-session-gave-up=12\n[steam-host] ml1830 probe-result=45\n")
assert(session.fields["launch-session-wait"] == "35" && session.fields["launch-session-gave-up"] == "12")
assert(session.failure!.contains("still says") && session.failure!.contains("another session"))
assert(parse("[steam-host] ml1970 launch-client-error=35\n[steam-host] ml2015 launch-session-wait=35\n[steam-host] ml1830 probe-result=48\n").failure!.contains("still says"))
let sessionNoWait = parse("[steam-host] ml1970 launch-client-error=35\n[steam-host] ml1830 probe-result=45\n").failure!
assert(sessionNoWait.contains("another session") && !sessionNoWait.contains("still says"))
assert(parse("[steam-host] ml2015 launch-session-wait=35\n[steam-host] ml1970 launch-client-error=22\n[steam-host] ml1830 probe-result=45\n").failure!.contains("configuration"))
assert(parse("[steam-host] ml1970 launch-client-error=99\n[steam-host] ml1830 probe-result=45\n").failure!.contains("code 45"))
let callbacks = parse((1...20).map { "[steam-host] ml1830 session-callback-id=\(100 + $0)\n" }.joined() + "[steam-host] ml1830 session-callback-id=x\n")
assert(callbacks.fields["session-callback-ids"] == (1...16).map { String(100 + $0) }.joined(separator: ","))
assert(callbacks.fields["session-callback-id"] == nil)
let entitled = parse("[steam-host] ml1830 session-requested-app-entitled=1\n[steam-host] ml1830 session-subscription-count=12\n")
assert(entitled.fields["session-requested-app-entitled"] == "1" && entitled.fields["session-subscription-count"] == "12")
assert(parse("[steam-host] ml1830 session-authenticated-online=1\n[steam-host] ml1830 probe-result=34\n").failure!.contains("did not confirm this game's license in time"))
assert(parse("[steam-host] ml1830 probe-result=34\n").failure!.contains("did not finish signing in"))
// Offline start (ml2016): Valve's client decides; each refusal has its own words.
let offline = parse("[steam-host] ml2016 session-offline-abi=1\n[steam-host] ml2016 session-offline-requested=1\n[steam-host] ml2016 session-offline-can=2\n[steam-host] ml1830 probe-result=50\n")
assert(offline.fields["session-offline-can"] == "2" && offline.failure!.contains("nothing saved") && offline.failure!.contains("once while online"))
assert(parse("[steam-host] ml2016 session-offline-abi=0\n[steam-host] ml1830 probe-result=50\n").failure!.contains("client build"))
assert(parse("[steam-host] ml2016 session-offline-logon-result=2\n[steam-host] ml1830 probe-result=51\n").failure!.contains("refused to sign in offline"))
assert(parse("[steam-host] ml2016 session-offline-logon-state=3\n[steam-host] ml1830 probe-result=52\n").failure!.contains("does not list this game"))
assert(parse("[steam-host] ml2016 session-offline-ready=1\n").fields["session-offline-ready"] == "1")
let rejected = "[steam-host] ml1830 account=synthetic\n[steam-host] ml1830 token=synthetic\n[steam-host] ml1830 probe-result=2147483648\n[steam-host] ml1830 probe-result=secret\n[steam-host] ml1830 client-sha256=invalid\n[steam-host] unknown probe-result=0\n[steam-host] ml1830 probe-result=0 secret\n"
assert(parse(rejected).fields.isEmpty)
assert(parse(String(repeating: "x", count: 32769)).fields.isEmpty)
assert(MadeiraDock.parseReport(Data([0xff])).fields.isEmpty)
print("PASS: Dock report completion, CRLF, fingerprints, adapter version, callback IDs, failure reasons (including the session wait and the license wait) and private/malformed field rejection")
'''
with tempfile.TemporaryDirectory(prefix='madeira-dock-report-') as directory:
    source = Path(directory) / 'main.swift'; binary = Path(directory) / 'check'
    source.write_text('import Foundation\nenum MadeiraDock {\n' + parser + '\n}\n' + checks)
    subprocess.run([SWIFTC, str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

# The rounds the parser accepts are the ones the pinned host writes.
if host.exists():
    import re
    written = set(re.findall(r'"(ml\d{4})"', host.read_text())) | set(re.findall(r'\[steam-host\] (ml\d{4})', host.read_text()))
    for path in (root / 'madeira-dock/src').glob('*.c'):
        written |= set(re.findall(r'"(ml\d{4})"', path.read_text()))
    accepted = set(re.findall(r'"(ml\d{4})"', text[text.index('static let reportRounds'):text.index('static func parseReport')]))
    # ml2014 tags only install-scm, emitted by the host's `--start-services` CLI mode before any
    # report file is opened (stderr only). Madeira runs that mode only as its own process in the
    # one-time-install batch (DockInstallers.swift), before the host run, so it never reaches the report.
    main_c = host.read_text()
    assert re.search(r'!strncmp\(stage, "install-scm", 11\) \? "ml2014"', main_c) and main_c.count('"ml2014"') == 1
    assert main_c.index('"--start-services"') < main_c.index('report = _wfopen(')
    uses = sorted(p.name for p in (root / 'app/Madeira').glob('*.swift') if '--start-services' in p.read_text())
    assert uses in ([], ['DockInstallers.swift']), uses
    written -= {'ml2014'}
    assert written <= accepted, f'host rounds not accepted: {sorted(written - accepted)}'
    print(f'PASS: every report round the pinned host writes is accepted ({len(written)})')
else:
    print('SKIP: madeira-dock not checked out; round cross-check not run')

# The live Dock status names the session wait only while the host reports it for refusal 35.
view = (root / 'app/Madeira/MadeiraDockView.swift').read_text()
assert 'report.fields["launch-session-wait"] != nil, report.fields["launch-client-error"] == "35"' in view
assert 'Waiting for Steam to end it (up to 3 minutes)' in view
print('PASS: live Dock status shows the session wait')
