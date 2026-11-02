#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Three audio endpoint switches in build/ntdll-unix/audio_null_ios.c:
  env.MADEIRA_AUDIO_RESUME = 1     the endpoint starts again after an iOS interruption, and while it is held
                                   stopped each stream's ring plays out by the clock
  env.MADEIRA_AUDIO_GAIN = 10..200 the title's volume at the output, in percent
  env.MADEIRA_AUDIO_PERIOD_MS = n  the shared-mode engine period, 1..200 ms

Static anchors only: each value's parse and default, the resume gate on the session-event entry point and the
drain, the gain's one-comparison fast path before the clamp, the period's fall-back to 10 ms, and the log lines.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'build/ntdll-unix/audio_null_ios.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(start):
    b = src[src.index(start):]
    return b[:b.index('\n}\n')]

# resume
r = body('static int ios_audio_resume_on(void)')
check('getenv("MADEIRA_AUDIO_RESUME");' in r and "return e && e[0] == '1' && !e[1];" in r, 'resume: exactly "1" turns it on')
ev = body('int madeira_audio_session_event(int what)')
check('if (!ios_audio_resume_on()) return -1;' in ev, 'resume: with the switch off the session event does nothing (-1)')
check('if (what == 0) {' in ev and 'ios_dev_suspend_locked();' in ev and 'AudioOutputUnitStop(g_dev.au);' in ev,
      'resume: an interruption stops the endpoint and marks it held')
check('if (g_dev.au && any && !g_dev.running) {' in ev and 'err = AudioOutputUnitStart(g_dev.au);' in ev
      and 'atomic_store_explicit(&g_dev_suspended, 0, memory_order_release);' in ev,
      'resume: the session coming back starts the endpoint again and clears the hold')
check('if (!atomic_load_explicit(&g_dev_suspended, memory_order_relaxed) || !s->started || !ios_stream_is_live(s)) {'
      in body('static void ios_stream_drain(struct ios_stream *s)'),
      'resume: the drain does nothing unless the endpoint is held')
check(re.search(r'if \(atomic_load_explicit\(&g_dev_suspended, memory_order_acquire\)\)\s*ios_stream_drain\(s\);', src) is not None,
      "resume: each stream's timer loop drains its ring while the endpoint is held")
check(src.count('ios_dev_suspend_locked();') >= 2 and 'if (ios_audio_resume_on()) {' in body('static void ios_dev_start(void)'),
      'resume: a failed endpoint start is held only with the switch')

# gain
check('static _Atomic int g_gain_permille = 1000;' in src, 'gain: default 1000 per mille (unchanged)')
p = body('static int ios_audio_gain_parse(const char *e)')
check('if (n == 0 || *e != \'\\0\' || v < 10 || v > 200) return 1000;' in p and 'return v * 10;' in p,
      'gain: digits only, 10..200 percent; anything else leaves the level unchanged')
g = body('static void ios_audio_gain_init(void)')
check('getenv("MADEIRA_AUDIO_GAIN");' in g and 'if (read_once) return;' in g and 'MADEIRA_AUDIO_GAIN=%s: the game\'s volume is %s\\n"' in g,
      'gain: read once, logged when set')
check('if (gain != 1000) ios_apply_gain(out, total, gain);' in src
      and src.index('if (gain != 1000) ios_apply_gain(out, total, gain);') < src.index('if (out[k] > 1.0f) { out[k] = 1.0f; clamped++; }'),
      'gain: one comparison at 100 %, applied before the full-scale clamp')
check('if (percent >= 10 && percent <= 200) atomic_store_explicit(&g_gain_permille, percent * 10, memory_order_relaxed);'
      in body('void madeira_audio_set_gain_percent(int percent)'), 'gain: the app-side setter takes the same range')

# period
per = body('static REFERENCE_TIME ios_engine_period(void) {')
check('const char *e = getenv( "MADEIRA_AUDIO_PERIOD_MS" );' in per and 'REFERENCE_TIME hns = 100000;' in per
      and 'if (ms >= 1 && ms <= 200) hns = (REFERENCE_TIME)(ms * 10000);' in per,
      'period: 1..200 ms sets it outright; default 10 ms')
check('if (us > 0 && us * 20 > hns) hns = us * 20;' in per and '"[audio] engine period %.2f ms (io slice %s us)' in per,
      'period: otherwise two I/O slices if larger; the period is logged once as [audio]')
check('REFERENCE_TIME period = ios_engine_period();' in body('static NTSTATUS ios_get_device_period(void *args) {'),
      'period: GetDevicePeriod reports it')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    for key in ('env.MADEIRA_AUDIO_RESUME', 'env.MADEIRA_AUDIO_GAIN', 'env.MADEIRA_AUDIO_PERIOD_MS'):
        check(f'key: "{key}"' in text, f'the config catalog documents {key}')

print(f'check-audio-switches: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
