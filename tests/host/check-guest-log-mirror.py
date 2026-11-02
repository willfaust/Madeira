#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2300, from a tester's log of 2026-10-31: a launcher wrote every ordinary info line with a "[DISPLAY]"
log-level tag, so the guest text-log mirror's keyword filter kept all of them and its 64-line budget ran out
during startup, before the launcher's error lines. The same log also carried a launcher's one-use sign-in
argument (-AUTH_PASSWORD=...) into the exported Madeira log.

- wine/dlls/ntdll/unix/file.c: ios_guest_log_keep blanks a "[DISPLAY]" / "[ display ]" tag before the keyword
  match (other "display" text still matches); ios_guest_log_redact replaces the value after password=, token=
  and secret= (any case) with <redacted> in every mirrored line.

Compiles the two functions from the wine source with cc when both are available.
"""
import shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(src, name, stop='\n}\n'):
    i = src.index(name)
    return src[i:src.index(stop, i) + len(stop)]

HARNESS = r'''
#define CHECK(c, m) do { if (!(c)) { printf( "FAIL: %s\n", m ); fails++; } else printf( "PASS: %s\n", m ); } while (0)
int main( void )
{
    char out[256];
    int fails = 0;
    const char *a = "[startupinfo]     -AUTH_PASSWORD=0123abcd -AUTH_TYPE=exchangecode";
    unsigned int n = ios_guest_log_redact( a, strlen( a ), out, sizeof(out) );
    CHECK( !strcmp( out, "[startupinfo]     -AUTH_PASSWORD=<redacted> -AUTH_TYPE=exchangecode" ) && n == strlen( out ),
           "a sign-in argument's value is redacted, the rest of the line kept" );
    a = "x token=abc&secret=\"q\" Password=zz";
    ios_guest_log_redact( a, strlen( a ), out, sizeof(out) );
    CHECK( !strcmp( out, "x token=<redacted>&secret=<redacted>\"q\" Password=<redacted>" ),
           "token=, secret= and password= in any case; a value ends at space, quote or &" );
    a = "no secrets here";
    ios_guest_log_redact( a, strlen( a ), out, 8 );
    CHECK( !strcmp( out, "no secr" ), "the output stays within its capacity" );
    a = "[2026] [DISPLAY] [Main ] [launcher] Opening log file.";
    CHECK( !ios_guest_log_keep( a, strlen( a ) ), "a [DISPLAY] log-level tag alone does not keep a line" );
    a = "[2026] [ ERROR ] [Main ] [fileutils] No version info";
    CHECK( ios_guest_log_keep( a, strlen( a ) ), "error lines are kept" );
    a = "[2026] [DISPLAY] [Main ] [d3d] display mode 1920x1080";
    CHECK( ios_guest_log_keep( a, strlen( a ) ), "display text outside the tag still matches" );
    return fails != 0;
}
'''

src = ROOT / 'wine/dlls/ntdll/unix/file.c'
if src.exists():
    s = src.read_text(encoding='utf-8', errors='replace')
    keep = body(s, 'static int ios_guest_log_keep(')
    redact = body(s, 'static unsigned int ios_guest_log_redact(')
    mirror = body(s, 'static void ios_guest_log_mirror(')
    check('ios_guest_log_redact( (const char *)text + start, len, clean, sizeof(clean) )' in mirror,
          'every mirrored line goes through the redaction')
    cc = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')
    if cc:
        with tempfile.TemporaryDirectory() as d:
            c = Path(d) / 't.c'
            c.write_text('#include <stdio.h>\n#include <string.h>\n#include <stdlib.h>\n' + keep + redact + HARNESS)
            exe = Path(d) / 't'
            r = subprocess.run([cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-o', str(exe), str(c)],
                               capture_output=True, text=True)
            check(r.returncode == 0, 'the mirror functions compile on the host' + ('' if not r.returncode else ': ' + r.stderr[:400]))
            if r.returncode == 0:
                r = subprocess.run([str(exe)], capture_output=True, text=True)
                sys.stdout.write(r.stdout)
                failures += r.stdout.count('FAIL: ')
    else:
        print('SKIP: no C compiler')
else:
    print('SKIP: wine sources not checked out')

print(f'check-guest-log-mirror: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
