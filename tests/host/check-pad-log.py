#!/usr/bin/env python3
"""Reads a Madeira log and lists where the new look's controller highlight went wrong.

    python3 tests/host/check-pad-log.py madeira-log.txt

Flags (from the "[pad] ..." and "[pad-highlight] ..." lines the app writes):
  NOTHING    presses while the highlight was on nothing (the controller seemed dead), and
             whether a touch was needed to get it back
  STUCK      3 or more moves in a row that went nowhere (usually just the top or bottom row;
             a problem only when the item is in the middle of a page)
  A/B DEAD   A or B pressed while the highlight was on nothing (an A that flips a switch on
             an item writes no line of its own, so only presses on nothing count)
  OPENED ON  where the highlight first landed in each page or sheet that opened, to check it
             starts on the top row
Prints a report; exits 1 when it found NOTHING or A/B DEAD problems.
"""
import re
import sys

if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(2)

line_re = re.compile(r'^\[(\d\d:\d\d:\d\d\.\d+)\] \[\w+\] (.*)$')
pad_re = re.compile(r'^\[pad\] (\S+) \((\w+)\): ring (.*?) on (the library|game page: .*|.*)$')
repeat_re = re.compile(r'^\[log-repeat\] repeated (\d+) more times?: (.*)$')
layer_re = re.compile(r'^\[pad-highlight\] layer (\S+) (opened|closed)$')

events = []  # (time, kind, data)
for raw in open(sys.argv[1], encoding='utf-8', errors='replace'):
    m = line_re.match(raw.rstrip('\n'))
    if not m:
        continue
    time, text = m.groups()
    count = 1
    r = repeat_re.match(text)
    if r:
        count, text = int(r.group(1)), r.group(2)
    p = pad_re.match(text)
    if p:
        button, command, ring, screen = p.groups()
        moved = '->' in ring
        target = ring.split('->')[-1].strip() if moved else ring
        nothing = target.startswith('on nothing') or target == 'nothing' or ring.endswith('-> on nothing') or ring == 'on nothing' or ring.strip() == ''
        for _ in range(count):
            events.append((time, 'pad', dict(button=button, command=command, ring=ring, screen=screen,
                                              moved=moved and not nothing, nothing=nothing, target=target)))
        continue
    l = layer_re.match(text)
    if l:
        events.append((time, 'layer', dict(name=l.group(1), action=l.group(2))))
        continue
    if text.startswith('[tap] '):
        events.append((time, 'tap', dict(text=text)))
    elif text.startswith('[screen] '):
        events.append((time, 'screen', dict(text=text)))

problems = 0
report = {'NOTHING': [], 'STUCK': [], 'A/B DEAD': [], 'OPENED ON': []}
moves = {'up', 'down', 'left', 'right'}

# NOTHING episodes.
i = 0
while i < len(events):
    t, kind, d = events[i]
    if kind == 'pad' and d['nothing']:
        start, n, screen = t, 0, d['screen']
        while i < len(events) and (events[i][1] != 'pad' or events[i][2]['nothing']):
            if events[i][1] == 'pad':
                n += 1
            if events[i][1] in ('tap', 'layer', 'screen'):
                break
            i += 1
        ended = events[i] if i < len(events) else None
        how = ('a touch got it back' if ended and ended[1] == 'tap'
               else f'ended by {ended[1]} {ended[2].get("name", "")}'.strip() if ended else 'never came back in this log')
        report['NOTHING'].append(f'{start}  {n} press(es) on nothing, {screen}; {how}')
        problems += 1
        continue
    i += 1

# STUCK runs.
run, last = [], None
for t, kind, d in events + [(None, 'end', {})]:
    if kind == 'pad' and d['command'] in moves and not d['moved'] and not d['nothing'] and 'hidden' not in d['ring']:
        if last and last['target'] == d['target']:
            run.append(t)
        else:
            run = [t]
        last = d
        continue
    if len(run) >= 3:
        report['STUCK'].append(f'{run[0]}  {len(run)} moves went nowhere from {last["target"]} ({last["screen"]})')
    run, last = [], None if kind != 'pad' else d

# A or B that did nothing: nothing happens in the next 1.5 s (layer change, move, screen change, tap-free page change).
def seconds(t):
    h, m, s = t.split(':')
    return int(h) * 3600 + int(m) * 60 + float(s)
for idx, (t, kind, d) in enumerate(events):
    if kind != 'pad' or d['command'] not in ('accept', 'back') or d['moved']:
        continue
    acted = False
    for t2, k2, d2 in events[idx + 1:]:
        if seconds(t2) - seconds(t) > 1.5:
            break
        if k2 in ('layer', 'screen') or (k2 == 'pad' and d2['screen'] != d['screen']):
            acted = True
            break
    if not acted and d['nothing']:
        report['A/B DEAD'].append(f'{t}  {d["button"]} pressed with the highlight on nothing ({d["screen"]})')
        problems += 1

# Where each opened layer's highlight first landed.
for idx, (t, kind, d) in enumerate(events):
    if kind == 'layer' and d['action'] == 'opened':
        landed = next((e for e in events[idx + 1:] if e[1] == 'pad' and f' in {d["name"]}' in e[2]['ring']), None)
        if landed:
            item = landed[2]['ring'].split('->')[-1].strip() if '->' in landed[2]['ring'] else landed[2]['ring']
            report['OPENED ON'].append(f'{t}  {d["name"]}: first press found {item}')

for name, rows in report.items():
    print(f'{name} ({len(rows)})')
    for row in rows:
        print('  ' + row)
    print()
presses = sum(1 for e in events if e[1] == 'pad')
print(f'{presses} controller presses read; {problems} problem(s).')
sys.exit(1 if problems else 0)
