#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""env.MADEIRA_PROF_THREADS: the sampling profiler (env.MADEIRA_PROF) limited to threads by name.

The name test (ios_prof_name_wanted) is taken out of build/ntdll-unix/server_ios.c, compiled with the host
compiler and run on names and filters. Static anchors cover its use: a thread that is not wanted is skipped
before thread_info and before any suspend, and its name is read again once a second (a thread is named after
it starts), so a filtered profile costs one name read a second for every other thread.
"""
import shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'build/ntdll-unix/server_ios.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

a = src.index('static int ios_prof_name_wanted( const char *name, const char *filter )')
fn = src[a:src.index('\n}\n', a) + 3]
main = src[src.index('static void ios_prof_main(void)'):]
main = main[:main.index('\n}\n')]

check('const char *threads_env = getenv( "MADEIRA_PROF_THREADS" );' in main and 'if (threads_env && !*threads_env) threads_env = NULL;' in main,
      'the filter is read once; unset or empty means every thread')
skip = 'if (sl->skip && pass % hz) continue;'
check(skip in main and main.index(skip) < main.index('if (thread_info( sl->port, THREAD_EXTENDED_INFO'),
      'a thread that is not wanted costs no thread_info call, except once a second')
test = 'sl->skip = !ios_prof_name_wanted( sl->name, threads_env );'
check(test in main and main.index('snprintf( sl->name, sizeof(sl->name), "%s", xi.pth_name );') < main.index(test) < main.index('if (thread_suspend( sl->port ) != KERN_SUCCESS) continue;'),
      'the test runs on the current name, before the thread could be suspended')
check('if (sl->skip) { sl->cpu_ns = ~0ull; continue; }' in main, 'a skipped thread loses its CPU baseline, so a later match starts clean')
check('int used, idle, seen, peb_done, skip;' in src and 'memset( &slots[free_slot], 0, sizeof(slots[free_slot]) );' in main,
      'a reused slot starts as wanted')

cc = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')
if not cc:
    print('note: no host C compiler; the name test was not run')
else:
    prog = '#include <stdio.h>\n#include <string.h>\n' + fn + r'''
int main(void) {
    struct { const char *name, *filter; int want; } t[] = {
        { "FMOD mixer thread", NULL, 1 }, { "FMOD mixer thread", "", 1 }, { "Main", "FMOD", 0 },
        { "FMOD mixer thread", "FMOD", 1 }, { "FMOD stream thread", "Main;FMOD", 1 }, { "Main", "Main;FMOD", 1 },
        { "HIGH1", "Main;FMOD", 0 }, { "", "FMOD", 0 }, { "FMOD mixer thread", ";;mixer;", 1 }, { "LOW0", ";", 0 },
        { "audio_client_timer", "FMOD;audio_client;AURemoteIO", 1 }, { "AURemoteIO::IOThread", "FMOD;audio_client;AURemoteIO", 1 },
        { "MadeiraSubmit", "FMOD;audio_client;AURemoteIO", 0 }, { "fmod", "FMOD", 0 },
    };
    unsigned i; int bad = 0;
    for (i = 0; i < sizeof t / sizeof t[0]; i++)
        if (ios_prof_name_wanted( t[i].name, t[i].filter ) != t[i].want) { printf( "wrong: '%s' with '%s'\n", t[i].name, t[i].filter ? t[i].filter : "(null)" ); bad++; }
    return bad;
}
'''
    with tempfile.TemporaryDirectory() as d:
        c = Path(d) / 't.c'; exe = Path(d) / 't'
        c.write_text(prog)
        built = subprocess.run([cc, '-Wall', '-Werror', '-O1', '-o', str(exe), str(c)], capture_output=True, text=True)
        check(built.returncode == 0, 'the name test compiles on its own' + ('' if built.returncode == 0 else ': ' + built.stderr[:400]))
        if built.returncode == 0:
            ran = subprocess.run([str(exe)], capture_output=True, text=True)
            check(ran.returncode == 0, 'names against filters: substring match, parts separated by ";", empty parts ignored, case kept' + ran.stdout)

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    check('key: "env.MADEIRA_PROF_THREADS"' in catalog.read_text(encoding='utf-8'), 'the config catalog documents env.MADEIRA_PROF_THREADS')

print(f'check-prof-threads: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
