#!/usr/bin/env python3
"""Get Help: the in-app button, the answer sheet, Apply and Undo (get-help).

Source checks:
1. GetHelp.swift talks to the live server's two calls (/help, /feedback) with the
   x-madeira-key header and the request fields the Worker reads.
2. The key comes from the build's Info.plist (MadeiraGetHelpKey), never from the source.
3. Game details has a Get Help row the controller ring reaches ("help" in padItems and
   padPress), its sheet reloads the game's config when it closes, and Advanced has Undo.
4. LogTrail offers Get Help when a game stopped by itself, or Madeira closed while it ran
   (not after the background, not when the player quit), and keeps the game's path for it.
5. Both files are in the Xcode project, the switches are in the config catalog, and every
   new text has all six languages.

With swiftc (--require-swift makes it required), GetHelp.swift is compiled with a test
main and run: the report clip, the request body, answers and errors from the server,
Apply (adds once, skips what is already set, never touches other lines) and Undo
(takes out exactly what Apply added, also after the player edited the config).
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
core = (app / 'GetHelp.swift').read_text()
view = (app / 'GetHelpView.swift').read_text()
lib = (app / 'Library.swift').read_text()
trail = (app / 'LogTrail.swift').read_text()
pbx = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
catalog = (app / 'ConfigCatalog.generated.swift').read_text()
strings = json.loads((app / 'Localizable.xcstrings').read_text(encoding='utf-8'))['strings']
failures = []


def check(cond, what):
    print(('PASS: ' if cond else 'FAIL: ') + what)
    if not cond:
        failures.append(what)


# 1. The server's contract (get-help-server/worker/src/index.ts).
check('https://madeira-get-help.camhocnote4.workers.dev' in core, 'the live server address')
check('urlRequest("help"' in view and 'urlRequest("feedback"' in view, '/help and /feedback')
check('"x-madeira-key"' in core, 'the x-madeira-key header')
for field in ['install_id', 'game', 'app_version', 'reason', 'report', 'keep_report', 'keep_policy']:
    check(re.search(rf'var {field}: ', core) is not None, f'request field {field}')
check('maxReport = 60_000' in core, 'reports are clipped under the server\'s 64 KB')

# 2. No key in the source.
check('infoDictionary?["MadeiraGetHelpKey"]' in view, 'the key is read from Info.plist MadeiraGetHelpKey')
check(not re.search(r'x-madeira-key[^\n]*"[A-Za-z0-9]{20,}"', core + view), 'no key written in the source')

# 3. Game details.
check('+ (GetHelp.enabled ? ["help"] : [])' in lib, 'the ring reaches Get Help')
check('case "help": getHelp = true' in lib, 'A on the ring opens Get Help')
check('detailRow("help", last: true) { GetHelpRow { getHelp = true }' in lib and 'lookRow("gp-help", last: true, press: { getHelp = true })' in lib,
      'the Get Help row on Game details (details-rebuild row; the new look\'s page too)')
check('.getHelpSheet($getHelp, entry: entry) { reloadBCD() }' in lib, 'the page reads the config again after the sheet')
check('GetHelpUndoSection(windowsPath: entry.windowsPath' in lib, 'Undo Get Help on the Advanced page')
check('guard !NewLook.enabled, path.isEmpty, !getHelp, !leaving' in lib and 'guard !NewLook.enabled, !getHelp, !leaving, !findCover' in lib
      and 'guard !getHelp, !leaving, !findCover, !importCover, !remove, !confirmReset, !confirmSteamUninstall' in lib, 'the page leaves the controller to the sheet while it is open')
check('.modifier(GetHelpOffer(play: play))' in lib, 'the library shows the offer (and starts Play Again)')
# 3b. (get-help-auto) Get Help opens by itself after a launch error, and walks through the answer.
check('.modifier(GetHelpStartScreen())' in lib, 'the starting screen hosts its own Get Help sheet')
check('.onChange(of: dockStart.failure)' in view and 'onStartScreen: true)' in view, '"Madeira Dock stopped" opens Get Help by itself')
check('launchGetHelp(entry)' in lib and lib.count('launchGetHelp(entry)') == 2, 'both starting screens have the Get Help button')
check('if !getHelpInstead(words, entry: entry) { error = words }' in lib, 'a failed start opens Get Help instead of the alert')
check('if !getHelpInstead(report, entry: activeEntry) { error = report }' in lib, 'a Windows error opens Get Help instead of the alert')
check('guard GetHelp.enabled, GetHelp.offers else { return false }' in view, 'env.MADEIRA_GET_HELP_OFFER = 0 keeps the old alerts')
check('if shared.shownJustNow(title)' in view, 'the "<game> Stopped" offer does not ask again after Get Help opened')
check('model.stopStartToLibrary()' in view, 'closing Get Help over the starting screen goes back to the library')
check('case step(String), apply([GetHelpCore.ConfigLine]), last' in view, 'the answer is a walkthrough')
check('" log.txt"' in view and 'DiscordLog.file(title: entry?.title' in (root / 'app/Madeira/LogsView.swift').read_text(), 'Save copy for Discord and Share Logs make a .txt, not a .zip')
check('ClaudeHelpButton(entry: entry)' not in lib and 'ClaudeHelpButton(' not in view, 'the Get Help sheet offers Save copy for Discord, not Get Help from Claude (Cameron, Nov 8)')
check('var title = "Save copy for Discord"' in view and '"Want to talk about it? Save copy for Discord"' in view and 'use Get Help from Claude' not in core, 'the button is "Save copy for Discord" and the messages name it')

# 4. The offer.
check('GetHelpCenter.stopped(title: title, windowsPath: windowsPath' in trail, '[game-end] offers Get Help')
check('if reason == nil, code.hasPrefix("Windows error")' in trail, 'not when the player quit or stopped it')
check('if fields["background"] == nil, let game = fields["game"]' in trail, '[last-run] offers it, not after the background')
check('lines.append("path=\\(windowsPath)")' in trail, 'the open-game marker keeps the path')

# 5. Project, catalog, languages.
for name in ['GetHelp.swift', 'GetHelpView.swift']:
    check(pbx.count(f'/* {name} */') >= 2 and pbx.count(f'/* {name} in Sources */') == 2, f'{name} is in the Xcode project')
for key in ['env.MADEIRA_GET_HELP"', 'env.MADEIRA_GET_HELP_OFFER"']:
    check(f'key: "{key}' in catalog, f'the catalog lists {key[:-1]}')
langs = {'de', 'es', 'ko', 'pt-BR', 'ru', 'zh-Hans'}
texts = set(re.findall(r'(?:Text|Button|Label|Toggle|NavigationLink|navigationTitle)\("([^"\\]*(?:\\\([^)]*\)[^"\\]*)*)"', view + lib))
texts |= set(re.findall(r'L\("([^"]+)"\)', view))
texts |= set(re.findall(r'static let \w+Message = "([^"]+)"', core)) | set(re.findall(r'static let notMadeiraAnswer = "([^"]+)"', core))
ours = [t for t in texts if t and ('Get Help' in t or t in view)]
missing = []
for t in sorted(ours):
    key = re.sub(r'\\\([^)]*\)', '%@', t)
    if key.startswith('\\(') or key in ('%@', '%@.'):
        continue
    if not re.search(re.escape('"' + t + '"'), view) and 'Get Help' not in t:
        continue
    entry = strings.get(key)
    if entry is None or set(entry.get('localizations', {})) < langs:
        missing.append(key)
check(not missing, f'every new text has six languages (missing: {missing})')

# (game-log-pick) Get Help reads only the named game's last run, from whichever log has it.
helper = (app / 'ClaudeHelp.swift').read_text()
check('static func gameRunLog(title: String, in docs: URL) -> URL?' in helper
      and '"madeira-log.txt", "madeira-log.prev.txt", LogSummary.gameLogName' in helper
      and '.sorted { modified($0) > modified($1) }' in helper, 'all three logs are searched, newest file first')
check('ClaudeHelp.logFor(title: title, in: docs)' in view and 'logFor(title: entry?.title, in: docs)' in helper,
      'Get Help and Get Help from Claude both read the named game\'s run')
check('guard let title, !title.isEmpty else { return chosenLog(in: docs) }' in helper, 'with no game (Settings), the old choice stays')
check('phase = .failed(L(GetHelp.noRunMessage))' in view and 'noRun = true' in view and 'if !noRun {' in view,
      'no run of the game: plain words, and no Try Again or Discord log that would send nothing')
check(strings.get("We couldn't find a log of this game. Play it once until it goes wrong, then tap Get Help again.", {}).get('localizations', {}).keys() >= langs,
      'the no-log words have six languages')

# A Python mirror of ClaudeHelp.lastRun(of:in:).
def last_run(title, lines):
    for i in range(len(lines) - 1, -1, -1):
        k = lines[i].find('[run-start] #')
        if k < 0: continue
        rest = lines[i][k + len('[run-start] #'):]
        num = ''
        for ch in rest:
            if ch.isdigit(): num += ch
            else: break
        if not num or rest[len(num) + 1:].strip() != title.strip(): continue
        end = len(lines) - 1
        for j in range(i + 1, len(lines)):
            if f'[run-end] #{num}' in lines[j]: end = j; break
        run = lines[i:end + 1]
        return run, any('Running full Wine sequence' in l or '[WineProc] Target exe: ' in l for l in run)
    return None
log = ['[10:00:00.000] [INFO] [run-start] #1 Stardew Valley', 'Running full Wine sequence', 'stardew line', '[run-end] #1',
       '[10:05:00.000] [INFO] [run-start] #2 7 Days to Die', '[WineProc] Target exe: 7dLauncher.exe', 'E C8 Failed to mprotect', '[run-end] #2',
       '[10:09:00.000] [INFO] [run-start] #3 Stardew Valley', 'held for a restart']
r = last_run('7 Days to Die', log)
check(r and r[0][0].endswith('#2 7 Days to Die') and r[0][-1] == '[run-end] #2' and r[1], "the named game's run, start to end, nothing of other games")
r = last_run('Stardew Valley', log)
check(r and r[0][0].endswith('#3 Stardew Valley') and not r[1], 'the newest run of that game; a held start is marked as not started')
check(last_run('Slay the Spire 2', log) is None, 'a game with no run: nothing')
check(last_run('7 Days', log) is None, 'a title must match exactly, not by its start')

# (keep-reports-30) Reports are kept 30 days unless the player opts out; the screen says so.
check('Text("Your logs go to Sentry, with all personal details taken out.")' in view
      and "Don't keep my report" not in view and 'dontKeep' not in view, 'the first screen says reports and logs are kept; no opt-out switch (Cameron, Nov 8)')
check('keep_report: true)' in view and 'var keep_policy: Int = 2' in core, 'the report is kept unless the player opted out, and the server is told the screen says so')
check('"get-help-consented-2"' in view, 'players who agreed to the old screen see the new one once')
check('7 days' not in view, 'no screen still promises "only 7 days, only if ticked"')

# (fix-check) "Did the fix work?" after the next play since Apply, sent to the results log.
check('GetHelp.watchFix(requestID: id, windowsPath: windowsPath' in view and 'if case .added = result' in view,
      'only a real Apply (lines added) waits for the next play, with the answer\'s id')
check('stopWatching(windowsPath)' in view[view.index('static func undo('):], 'Undo stops the question')
check('urlRequest("result", key: key' in view and '"request_id": check.requestID' in view and '"worked"' in view
      and '"ran_seconds"' in view and '"ended"' in view, 'POST /result sends only the id, the answer, how long and how it ended')
check('GetHelpCenter.gameFinished(windowsPath: windowsPath' in trail, "LogTrail's [game-end] tells Get Help a game run ended")
check('started > check.appliedAt' in view, 'only a run that started after Apply counts')
check('if ended == "crash"' in view and 'worked: nil' in view, 'after a crash it does not ask (the Stopped offer follows) but still sends the result')
check('center.fixAsk != nil && center.offer == nil && model.error == nil && model.current == nil && center.open == nil' in view,
      'the question waits for the library, behind any other alert or sheet')
check('if worked == false' in view and 'reason: "player")' in view[view.index('private func answerFix('):], 'No opens Get Help again for the next step')
check('Button("Not Sure", role: .cancel)' in view, 'Not Sure is the cancel button (no answer is sent as unknown)')

# Compile and run.
swiftc = shutil.which('swiftc')
if not swiftc:
    print('SKIP: swiftc not found' + (' (required)' if '--require-swift' in sys.argv else ''))
    if '--require-swift' in sys.argv:
        failures.append('swiftc required')
else:
    test = r'''
import Foundation
var bad = 0
func expect(_ c: Bool, _ what: String) { print((c ? "PASS: " : "FAIL: ") + what); if !c { bad += 1 } }

// Clip: small reports stay; big ones keep the start and the end, under the limit in UTF-16 units.
expect(GetHelpCore.clip("short") == "short", "a short report is sent whole")
let big = "START\n" + String(repeating: "é line ✓\n", count: 20_000) + "THE END"
let clipped = GetHelpCore.clip(big)
expect(clipped.utf16.count <= GetHelpCore.maxReport, "a big report fits the server (\(clipped.utf16.count))")
expect(clipped.hasPrefix("START") && clipped.hasSuffix("THE END") && clipped.contains("left out here"), "start and end kept")

// The body the Worker reads.
let req = GetHelpCore.Request(install_id: UUID().uuidString, game: "Pizza Tower", app_version: "v0.2.0", reason: "crash", report: big, keep_report: false)
let body = try! JSONSerialization.jsonObject(with: GetHelpCore.body(req)) as! [String: Any]
expect(Set(body.keys) == ["install_id", "game", "app_version", "reason", "report", "keep_report", "keep_policy", "upload"], "request fields")
expect((body["keep_policy"] as? Int) == 2, "keep_policy 2: the screen says reports are kept 30 days")
expect((body["report"] as! String).utf16.count <= 60_000, "body report clipped")
expect((body["keep_report"] as? Bool) == false, "keep_report is a JSON bool")
let r = GetHelpCore.urlRequest("help", key: "k", body: Data())
expect(r.url?.absoluteString == "https://madeira-get-help.camhocnote4.workers.dev/help" && r.httpMethod == "POST"
       && r.value(forHTTPHeaderField: "x-madeira-key") == "k", "POST /help with the key header")

// Answers.
func outcome(_ json: String) -> GetHelpCore.Outcome { GetHelpCore.outcome(data: json.data(using: .utf8), status: 200, error: nil) }
let ok = outcome(#"{"ok":true,"request_id":"6f1c2b9e-0000-4000-8000-000000000000","kind":"answer","answer":" The JIT pool filled up. ","steps":["Close Madeira", " "],"config":{"lines":[{"key":"pool","value":"256","plain":"Give the game more memory"},{"key":"bad key","value":"1","plain":"x"},{"key":"x","value":"1\n2","plain":"y"}],"text":"pool = 256"},"confidence":"high"}"#)
if case .answer(let a) = ok {
    expect(a.answer == "The JIT pool filled up.", "answer trimmed")
    expect(a.steps == ["Close Madeira"], "empty steps dropped")
    expect(a.config?.lines.map(\.key) == ["pool"], "unsafe lines dropped in the app too")
} else { expect(false, "an answer is an answer") }
let none = outcome(#"{"ok":true,"request_id":"6f1c2b9e-0000-4000-8000-000000000000","kind":"answer","answer":"We don't know this one yet.","steps":[],"config":null,"confidence":"low"}"#)
if case .answer(let a) = none { expect(a.config == nil, "no settings: no config") } else { expect(false, "no-config answer") }
expect(outcome(#"{"ok":false,"error":"limit","message":"You've used Get help a lot today."}"#) == .failed("You've used Get help a lot today."), "the server's message is shown as is")
expect(outcome("<html>502</html>") == .failed(GetHelpCore.badAnswerMessage), "a broken reply has plain words")
expect(outcome(#"{"ok":true,"answer":"  "}"#) == .failed(GetHelpCore.badAnswerMessage), "an empty answer has plain words")
expect(GetHelpCore.outcome(data: nil, status: nil, error: URLError(.notConnectedToInternet)) == .failed(GetHelpCore.offlineMessage), "offline")
expect(GetHelpCore.outcome(data: nil, status: nil, error: URLError(.timedOut)) == .failed(GetHelpCore.slowMessage), "timed out")

// Apply and Undo.
let pool = GetHelpCore.ConfigLine(key: "pool", value: "256", plain: "Give the game more memory")
let fence = GetHelpCore.ConfigLine(key: "fence-chain", value: "6", plain: "Smoother frames")
let original = "# mine\npool = 128\nenv.FEX_MULTIBLOCK = 1\n"
let a1 = GetHelpCore.apply([pool, fence], to: original, date: "Nov 7, 2026")!
expect(a1.text.hasPrefix(original), "Apply keeps every line the game had")
expect(GetHelpCore.values(a1.text)["pool"] == "256" && GetHelpCore.values(a1.text)["fence-chain"] == "6", "the new lines win")
expect(a1.added.first?.hasPrefix("# Get Help added these on Nov 7, 2026") == true, "a comment says Get Help added them")
expect(GetHelpCore.undo(a1.added, from: a1.text) == original, "Undo gives back the exact config")
expect(GetHelpCore.apply([pool], to: a1.text, date: "x") == nil, "a setting already there is not added again")
let edited = a1.text + "dxmt = d3d11.mipClampBC=1\n"
let u = GetHelpCore.undo(a1.added, from: edited)
expect(u == original + "dxmt = d3d11.mipClampBC=1\n", "Undo after an edit keeps the player's new line")
let fresh = GetHelpCore.apply([pool], to: "", date: "d")!
expect(GetHelpCore.values(fresh.text) == ["pool": "256"] && !fresh.text.hasPrefix("\n"), "Apply to an empty config")
expect(GetHelpCore.undo(fresh.added, from: fresh.text) == "", "Undo empties it again (the file is removed)")
let noNewline = GetHelpCore.apply([pool], to: "a = 1", date: "d")!
expect(noNewline.text.hasPrefix("a = 1\n\n"), "a config without a last newline")
expect(GetHelpCore.undo(noNewline.added, from: noNewline.text) == "a = 1\n", "and back")
expect(!GetHelpCore.safe(.init(key: "a=b", value: "1", plain: "")) && !GetHelpCore.safe(.init(key: "a", value: "", plain: "")), "unsafe keys and empty values refused")
let rec = GetHelpCore.Record(game: "Pizza Tower", date: "d", added: a1.added)
expect(try! JSONDecoder().decode(GetHelpCore.Record.self, from: JSONEncoder().encode(rec)) == rec, "the Undo record round-trips")

print(bad == 0 ? "ALL SWIFT CHECKS PASS" : "\(bad) SWIFT CHECK(S) FAILED")
exit(bad == 0 ? 0 : 1)
'''
    with tempfile.TemporaryDirectory() as tmp:
        main = Path(tmp) / 'main.swift'
        main.write_text(test)
        exe = Path(tmp) / 'get-help-check'
        build = subprocess.run([swiftc, '-O', str(app / 'GetHelp.swift'), str(main), '-o', str(exe)],
                               capture_output=True, text=True)
        check(build.returncode == 0, 'GetHelp.swift compiles with swiftc' + ('' if build.returncode == 0 else '\n' + build.stderr[-3000:]))
        if build.returncode == 0:
            run = subprocess.run([str(exe)], capture_output=True, text=True)
            print(run.stdout, end='')
            check(run.returncode == 0, 'the Swift checks pass' + ('' if run.returncode == 0 else '\n' + run.stderr[-2000:]))

# discord-full-log (Cameron, Nov 8): Save copy for Discord / Share Logs add the whole scrubbed log, capped at 5 MB.
_view = (root / 'app/Madeira/GetHelpView.swift').read_text()
check('static let maxBytes = 5 * 1024 * 1024' in _view and 'appendFullLog(' in _view and 'PrivacyScrub.line(raw)' in _view,
      'Save copy for Discord adds the whole log, scrubbed, under 5 MB')
check('madeiraShare = 2 * 1024 * 1024' in _view and 'appendFullLog(madeira, to: url' in _view and 'limit: maxBytes - reserve' in _view,
      'Save copy for Discord also adds madeira-log.txt (up to 2 MB kept back for it), still under 5 MB')

# sentry-full-log (Cameron, Nov 8): after a kept answer, one scrubbed zip to POST /upload, under Sentry's 40 MB.
_view2 = (root / 'app/Madeira/GetHelpView.swift').read_text()
_core2 = (root / 'app/Madeira/GetHelp.swift').read_text()
check('static let maxZip = 38 * 1024 * 1024' in _view2 and 'appendingPathComponent("upload")' in _view2
      and '"x-request-id"' in _view2, 'Get Help uploads one zip under 38 MB to /upload with the request id')
check('if let id = answer.request_id, let report {' in _view2 and 'dontKeep' not in _view2, 'the zip always goes, for the answer shown')
check(all(n in _view2 for n in ['"report.txt"', '"game-run.txt"', '"madeira-log.txt"', '"madeira.cfg.txt"', '"game-config.txt"', '"device.txt"', '"files.txt"']),
      'the zip holds the report, both logs, both configs, the device and the file list')
check('PrivacyScrub.line(raw)' in _view2 and 'PrivacyScrub.text(cfg)' in _view2 and 'PrivacyScrub.text(path)' in _view2,
      'every log, config and file name in the zip is scrubbed')
check('var upload: Bool = true' in _core2, 'the /help request says an upload follows')

print(f'\n{len(failures)} failure(s)' if failures else '\nall checks pass')
sys.exit(1 if failures else 0)

