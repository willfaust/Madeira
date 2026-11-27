#!/usr/bin/env python3
"""The always-on monitors stay off the game's cores (build/ntdll-unix); no Wine runs.

Compiles the production ios_warmer_sweep_cycles (virtual_ios.c) and
ios_xp_name_native (server_ios.c) against stubs:
  - the warmer's map walk and slot/window inventory run every 30 cycles (~1 min)
    by default, MADEIRA_WARMER_SWEEP_CYCLES picks another count, nonsense falls
    back to 30, and 5 brings back the old cadence (walk every 5, inventory
    every 15);
  - a native thread is named once in [xp-names], however often it is busy;
and textually that the warmer still warms every cycle, gates both sweeps on the
helper, reports the walk's time, and that [xp-t] names native rows only.
Needs python3 and a C compiler with pthreads (CC, default cc).
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
virt = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
srv = (root / 'build/ntdll-unix/server_ios.c').read_text()

def function(source, signature):
    body = source[source.index(signature):]
    return body[:body.index('\n}\n') + 3]

sweep = function(virt, 'static unsigned ios_warmer_sweep_cycles( void )')
name = function(srv, 'static void ios_xp_name_native( pthread_t pt, uint64_t tid )')
warmer = function(virt, 'static void *ios_pool_warmer_thread( void *arg )')

harness = r'''
#define _GNU_SOURCE
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int lines;
static char last[256];
static void wine_log_write( const char *fmt, ... )
{
    va_list ap; va_start( ap, fmt ); vsnprintf( last, sizeof(last), fmt, ap ); va_end( ap ); lines++;
}
''' + sweep + name + r'''
int main( int argc, char **argv )
{
    unsigned want = (unsigned)atoi( argv[1] ), c, walks = 0, inventories = 0;
    unsigned every = ios_warmer_sweep_cycles();
    (void)argc;
    if (every != want) { fprintf( stderr, "cycles %u, wanted %u\n", every, want ); return 1; }
    for (c = 1; c <= 300; c++)   /* the warmer's two conditions, ~10 minutes */
    {
        if (c == 2 || (c % ios_warmer_sweep_cycles()) == 0) walks++;
        if (c == 1 || (ios_warmer_sweep_cycles() == 5 ? (c % 15) == 0 : (c % ios_warmer_sweep_cycles()) == 0))
            inventories++;
    }
#ifdef __APPLE__
    pthread_setname_np( "probe-me" );
#else
    pthread_setname_np( pthread_self(), "probe-me" );   /* glibc names a given thread */
#endif
    ios_xp_name_native( pthread_self(), 981493 );
    ios_xp_name_native( pthread_self(), 981493 );
    ios_xp_name_native( pthread_self(), 981492 );
    if (lines != 2 || !strstr( last, "m981492 \"probe-me\"" )) { fprintf( stderr, "names: %d '%s'\n", lines, last ); return 1; }
    printf( "%u %u\n", walks, inventories );
    return 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'cadence.c'
    c.write_text(harness)
    exe = Path(tmp) / 'cadence'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function', '-pthread',
                    str(c), '-o', str(exe)], check=True)
    base = dict(os.environ)
    base.pop('MADEIRA_WARMER_SWEEP_CYCLES', None)
    for value, want, walks, inventories in ((None, 30, 11, 11), ('5', 5, 61, 21), ('60', 60, 6, 6),
                                            ('0', 30, 11, 11), ('junk', 30, 11, 11)):
        env = dict(base, **({'MADEIRA_WARMER_SWEEP_CYCLES': value} if value is not None else {}))
        out = subprocess.run([str(exe), str(want)], capture_output=True, text=True, env=env)
        assert out.returncode == 0, out.stderr
        got = tuple(int(x) for x in out.stdout.split())
        assert got == (walks, inventories), (value, got)
        print(f'PASS: MADEIRA_WARMER_SWEEP_CYCLES={value}: every {want} cycles, {walks} map walks and '
              f'{inventories} inventories in 300 cycles (~10 min)')

# --- textual wiring -----------------------------------------------------------
assert len(re.findall(r'for \(o = (?:0|total - tail); o < (?:head|total); o \+= 0x4000\) \{ (?:if \(IOS_POOL_IN_HOLE\(o\)\) continue; )?sink \+= r[wx]\[o\]; touched\+\+; \}', warmer)) == 4, 'pages are still warmed every cycle'
assert 'if (cycle == 2 || (cycle % ios_warmer_sweep_cycles()) == 0)' in warmer
assert 'if (cycle == 1 || (ios_warmer_sweep_cycles() == 5 ? (cycle % 15) == 0' in warmer
assert 'if ((cycle % 5) == 0 && rx)' in warmer, 'the .text sweep keeps its cadence'
assert '(walk %ld ms; next in %u ' in warmer
assert 'if (!w && pt_ && pt + et >= 2.0) ios_xp_name_native( pt_, idi.thread_id );' in srv
print('PASS: pages are warmed every cycle; only the address-space sweeps slow down; native [xp-t] rows get a name once')
