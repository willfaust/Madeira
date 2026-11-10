#!/usr/bin/env python3
"""env.MADEIRA_CEF_PA_EXES: programs other than SocialClubHelper.exe get the CEF address space; no Wine runs.

BeamNG.drive (2026-11-01, six logs): BeamNG.drive.x64.exe loads chrome_elf.dll
and libcef.dll in its own process. With env.MADEIRA_SC_PA_POOLS = 2 the slots
were held at boot, but every route that hands them out asked
ios_sc_current_is_helper(), so the game's 32 GB PartitionAlloc reserves were
refused three times and chrome_elf.dll stopped on its own int3 (80000003).

build/ntdll-unix/virtual_ios.c's ios_cef_pa_listed matches the image's last
path component against env.MADEIRA_CEF_PA_EXES, and ios_sc_current_is_cef_host
is SocialClubHelper.exe or a listed program. Compiles the list parser and the
matcher and checks names, case, directories, separators, spaces and look-alikes;
then checks textually that every address-space route (HighestUserAddress, the
commit judge, the dead-host reap, the hinted jumbo retry, layout 2's route and
layout 1's glued pools, the grant note, VirtualAlloc2's V8 step) asks
ios_sc_current_is_cef_host, while Social Club-only behaviour (libcef refusal in
a client, the [sc-rph] patch) still asks for SocialClubHelper.exe alone.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(src, sig):
    start = src.index(sig)
    return src[start:src.index('\n}\n', start) + 3]


# --- textual: which routes ask which question -------------------------------------
assert native.count('ios_sc_current_is_cef_host()') == 7, native.count('ios_sc_current_is_cef_host()')
for needle in (
    'ios_sc2_reported_highest( real, wow64, ios_sc_layout_mode, ios_sc_current_is_cef_host() );',
    'if (a < IOS_SC2_L_BASE || !ios_sc_grant_n || !ios_sc_current_is_cef_host()) return;',
    'if (is_jumbo && ios_sc_grant_dead_n && ios_sc_cef_enabled() && ios_sc_current_is_cef_host())',
    '&& ios_sc_cef_enabled() && ios_sc_current_is_cef_host())\n            {\n                void *hint = *ret;',
    'int sc_helper = ios_sc_cef_enabled() && ios_sc_current_is_cef_host();',
    'if (is_jumbo && !st && ios_sc_cef_enabled() && ios_sc_current_is_cef_host()) ios_sc_grant_note( *ret, *size_ptr );',
    'int sc2 = is_jumbo && ios_sc_layout_mode == 2 && ios_sc_cef_enabled() && ios_sc_current_is_cef_host();',
):
    assert native.count(needle) == 1, needle
# Social Club-only behaviour keeps the helper test
assert 'ios_sc_cef_refuse( sc_mod, 1, ios_sc_current_is_helper(), ios_sc_current_has_socialclub(),' in native
assert '!ios_sc_path_is_helper( nt_name->Buffer, nt_name->Length / sizeof(WCHAR) )) return;' in native
host = function(native, 'static int ios_sc_current_is_cef_host(void)')
assert 'ios_sc_path_is_helper( pp->ImagePathName.Buffer, n ) || ios_cef_pa_listed( pp->ImagePathName.Buffer, n )' in host
print('PASS: every CEF address-space route asks ios_sc_current_is_cef_host; libcef refusal and [sc-rph] stay '
      'SocialClubHelper.exe-only')

# --- compiled: the list -------------------------------------------------------------
code = native[native.index('#define IOS_CEF_PA_MAX'):native.index('/* Does the calling pseudo-process get the CEF address space?')]
harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
typedef uint16_t WCHAR;
#define FAIL(...) do { fprintf(stderr, __VA_ARGS__); exit(1); } while (0)
''' + code + r'''
static WCHAR *w( const char *s, size_t *len )
{
    static WCHAR buf[4][512];
    static int k;
    WCHAR *o = buf[k++ & 3];
    size_t n = 0;
    for (; s[n]; n++) o[n] = (unsigned char)s[n];
    o[n] = 0;
    *len = n;
    return o;
}
static int listed( const char *s ) { size_t n; WCHAR *p = w( s, &n ); return ios_cef_pa_listed( p, n ); }

int main( int argc, char **argv )
{
    const char *mode = argc > 1 ? argv[1] : "";
    if (!strcmp( mode, "beamng" ))
    {
        if (!listed( "C:\\Program Files (x86)\\Steam\\steamapps\\common\\BeamNG.drive\\Bin64\\BeamNG.drive.x64.exe" ))
            FAIL("full path\n");
        if (!listed( "\\??\\C:\\x\\beamng.drive.x64.EXE" ) || !listed( "BeamNG.drive.x64.exe" ) ||
            !listed( "/mnt/x/BeamNG.drive.x64.exe" )) FAIL("case / bare / unix path\n");
        if (!listed( "C:\\x\\Other Game.exe" )) FAIL("second entry with a space inside\n");
        if (listed( "C:\\x\\BeamNG.drive.exe" ) || listed( "C:\\x\\NotBeamNG.drive.x64.exe" ) ||
            listed( "C:\\x\\BeamNG.drive.x64.exe.bak" ) || listed( "C:\\BeamNG.drive.x64.exe\\game.exe" ) ||
            listed( "SocialClubHelper.exe" ) || listed( "" )) FAIL("look-alike\n");
        if (ios_cef_pa_listed( NULL, 0 )) FAIL("NULL\n");
        if (ios_cef_pa_n != 2) FAIL("empty entries kept (%d)\n", ios_cef_pa_n);
        printf("PASS: a listed name matches in any directory and case; look-alikes, the launcher and empty "
               "entries do not\n");
    }
    else if (!strcmp( mode, "unset" ))
    {
        if (listed( "C:\\x\\BeamNG.drive.x64.exe" ) || ios_cef_pa_n) FAIL("unset list matched\n");
        printf("PASS: no env.MADEIRA_CEF_PA_EXES, no program but SocialClubHelper.exe\n");
    }
    else if (!strcmp( mode, "long" ))
    {
        ios_cef_pa_parse_list( "a.exe;b.exe;c.exe;d.exe;e.exe;f.exe;g.exe;h.exe;i.exe" );
        if (ios_cef_pa_n != IOS_CEF_PA_MAX) FAIL("list cap\n");
        ios_cef_pa_parse_list( "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.exe,ok.exe" );
        if (ios_cef_pa_n != 1 || strcmp( ios_cef_pa_names[0], "ok.exe" )) FAIL("over-long name\n");
        printf("PASS: at most %d names, an over-long one is dropped\n", IOS_CEF_PA_MAX);
    }
    else FAIL("mode?\n");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as t:
    c = Path(t) / 'cef.c'
    c.write_text(harness)
    exe = Path(t) / 'cef'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-O1', '-Wall', '-Werror', '-pthread',
                    '-fsanitize=address,undefined', '-fno-sanitize-recover=all', str(c), '-o', str(exe)], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('MADEIRA_')}
    subprocess.run([str(exe), 'beamng'], check=True,
                   env=dict(env, MADEIRA_CEF_PA_EXES=' BeamNG.drive.x64.exe ;; "Other Game.exe",'))
    subprocess.run([str(exe), 'unset'], check=True, env=env)
    subprocess.run([str(exe), 'long'], check=True, env=env)
