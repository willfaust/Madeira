#!/usr/bin/env python3
"""works-now: the "This game works now" button, the once-per-report "Does it work now?" question,
the Get Help first-screen card and the library pill. Host check: source shape + strings (Swift is
typechecked on the PC)."""
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
view = (app / 'GetHelpView.swift').read_text(encoding='utf-8')
lib = (app / 'Library.swift').read_text(encoding='utf-8')
strings = json.loads((app / 'Localizable.xcstrings').read_text(encoding='utf-8'))['strings']
fails = []
def need(ok, what):
    if not ok: fails.append(what)
need('appendingPathComponent("works")' in view, 'sendWorks posts to /works')
need('seconds >= 180' in view and 'ended != "crash"' in view and '!report.asked' in view, 'asked once, after 3 min, not after a crash')
need('GetHelp.noteReport(title: target.title' in view, 'a shown answer notes the report')
need('GetHelp.closeReport(entry.windowsPath)' in view, 'the Advanced button closes the report on success')
need('worksCard' in view and 'GetHelpWorksSection(entry: entry)' in lib, 'first-screen card and Advanced section')
need('texts.append(L("Works now?"))' in lib, 'library pill')
need('Sent to the Madeira team. You don\'t need to send anything else.' in view, 'answer screen says the report was sent')
need('lookAgain(choice)' in view and 'What the player saw: ' in view, 'Not what you saw? asks again')
for key in ["Not what you saw?", "It froze", "It's slow", "Does %@ work now?", "Yes, it works now", "Works now?", "This game works now: send its logs", "Sending…", "Sent. Thank you!", "Sent to the Madeira team. You don't need to send anything else.",
            "Couldn't send. Tap to try again"]:
    loc = strings.get(key, {}).get('localizations', {})
    need(set(loc) >= {'de', 'es', 'ko', 'pt-BR', 'ru', 'zh-Hans'}, 'translated: ' + key)
if fails:
    print('FAIL', *fails, sep='\n  '); sys.exit(1)
print('check-works-now: ok')
