#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Four audio endpoint switches in build/ntdll-unix/audio_null_ios.c:
  env.MADEIRA_AUDIO_RESUME = 1     the endpoint starts again after an iOS interruption, and while it is held
                                   stopped each stream's ring plays out by the clock
  env.MADEIRA_AUDIO_GAIN = 10..200 the title's volume at the output, in percent
  env.MADEIRA_AUDIO_PERIOD_MS = n  the shared-mode engine period, 1..200 ms
  env.MADEIRA_AUDIO_MIX_RATE = n   the sample rate the shared-mode mix format reports, 8000..96000 Hz

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

# mix rate
mr = body('static UINT32 ios_audio_mix_rate(void) {')
check('const char *e = getenv( "MADEIRA_AUDIO_MIX_RATE" );' in mr
      and 'UINT32 r = (v >= 8000 && v <= 96000) ? (UINT32)v : IOS_AUDIO_SAMPLE_RATE;' in mr,
      'mix rate: 8000..96000 Hz sets it; unset, 0 or out of range keeps 48000')
mf = body('static NTSTATUS ios_get_mix_format(void *args) {')
check('f->nSamplesPerSec = ios_audio_mix_rate();' in mf and 'f->nAvgBytesPerSec = f->nSamplesPerSec * IOS_AUDIO_FRAME_BYTES;' in mf
      and 'IOS_AUDIO_SAMPLE_RATE' not in mf,
      'mix rate: GetMixFormat reports it, with the byte rate that goes with it')
check('g_dev.rate = s->sample_rate ? s->sample_rate : 48000;' in body('static int ios_dev_create_locked(const struct ios_stream *s)'),
      'mix rate: the endpoint is created at the rate of its first client, so iOS converts to the hardware rate')
import shutil, subprocess, tempfile, os
cc = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')
if cc:
    fn = src[src.index('static UINT32 ios_audio_mix_rate(void) {'):]
    fn = fn[:fn.index('\n}\n') + 3]
    prog = ('#include <stdio.h>\n#include <stdlib.h>\ntypedef unsigned int UINT32;\n#define IOS_AUDIO_SAMPLE_RATE 48000u\n' + fn +
            'int main(void) { printf("%u\\n", (unsigned)ios_audio_mix_rate()); return 0; }\n')
    with tempfile.TemporaryDirectory() as d:
        c = os.path.join(d, 't.c'); exe = os.path.join(d, 't')
        open(c, 'w').write(prog)
        built = subprocess.run([cc, '-Wall', '-Werror', '-O1', '-o', exe, c], capture_output=True, text=True)
        check(built.returncode == 0, 'mix rate: the reader compiles on its own' + ('' if built.returncode == 0 else ': ' + built.stderr[:400]))
        if built.returncode == 0:
            def run(v):
                env = dict(os.environ); env.pop('MADEIRA_AUDIO_MIX_RATE', None)
                if v is not None: env['MADEIRA_AUDIO_MIX_RATE'] = v
                return subprocess.run([exe], capture_output=True, text=True, env=env).stdout.split()[-1]
            got = [run(v) for v in (None, '', '0', '24000', '32000', '44100', '96000', '7999', '96001', 'abc', '-24000')]
            check(got == ['48000', '48000', '48000', '24000', '32000', '44100', '96000', '48000', '48000', '48000', '48000'],
                  'mix rate: values in range are taken, everything else is 48000: ' + ' '.join(got))

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    for key in ('env.MADEIRA_AUDIO_RESUME', 'env.MADEIRA_AUDIO_GAIN', 'env.MADEIRA_AUDIO_PERIOD_MS', 'env.MADEIRA_AUDIO_MIX_RATE'):
        check(f'key: "{key}"' in text, f'the config catalog documents {key}')

print(f'check-audio-switches: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
