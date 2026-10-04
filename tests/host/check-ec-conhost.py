#!/usr/bin/env python3
"""conhost.exe is refused in an ARM64EC session; no Wine runs.

Wine's conhost.exe is aarch64; in an ARM64EC session its threads get no CPU
area for the emulator the session's ntdll loads into it, so its first
executable allocation faults and the app dies. Compiles the production
ios_image_name_is / ec_conhost_refuse from build/ntdll-unix/process_ios.c and
checks the NtCreateUserProcess call site textually.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/process_ios.c').read_text()


def function(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}', start) + 2] + '\n'


create = function(source, 'NTSTATUS WINAPI NtCreateUserProcess(')
call = 'if (ec_conhost_refuse( is_arm64ec(), getenv( "MADEIRA_EC_CONHOST" ), params->ImagePathName.Buffer,'
assert call in create
gate = create[create.index(call):][:600]
assert 'return STATUS_ACCESS_DENIED;' in gate
# refused before anything is set up for the child
assert create.index(call) < create.index('create_startup_info( attr.ObjectName')

code = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned short WCHAR;
'''
code += function(source, 'static int ios_image_name_is(')
code += function(source, 'static int ec_conhost_refuse(')
code += r'''
static WCHAR buf[8][128];
static WCHAR *w( int slot, const char *s, int *len )
{
    int i;
    for (i = 0; s[i]; i++) buf[slot][i] = (unsigned char)s[i];
    *len = i;
    return buf[slot];
}
#define FAIL(m) do { fputs( m, stderr ); return 1; } while (0)
int main( void )
{
    int l1, l2, l3, l4, l5;
    WCHAR *ch = w( 0, "C:\\windows\\system32\\conhost.exe", &l1 );
    WCHAR *ch2 = w( 1, "\\??\\C:\\Windows\\System32\\CONHOST.EXE", &l2 );
    WCHAR *nc = w( 2, "C:\\x\\notconhost.exe", &l3 );
    WCHAR *nc2 = w( 3, "C:\\x\\conhost.exe.bak", &l4 );
    WCHAR *bare = w( 4, "conhost.exe", &l5 );
    if (!ec_conhost_refuse( 1, NULL, ch, l1 ) || !ec_conhost_refuse( 1, "0", ch2, l2 ) ||
        !ec_conhost_refuse( 1, "", bare, l5 )) FAIL( "EC conhost allowed\n" );
    if (ec_conhost_refuse( 0, NULL, ch, l1 )) FAIL( "aarch64 session conhost refused\n" );
    if (ec_conhost_refuse( 1, "1", ch, l1 )) FAIL( "MADEIRA_EC_CONHOST=1 refused\n" );
    if (ec_conhost_refuse( 1, NULL, nc, l3 ) || ec_conhost_refuse( 1, NULL, nc2, l4 ) ||
        ec_conhost_refuse( 1, NULL, NULL, 0 )) FAIL( "look-alike conhost refused\n" );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-ec-conhost-') as directory:
    folder = Path(directory)
    src = folder / 'check.c'
    src.write_text(code)
    exe = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-g', str(src), '-o', str(exe)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    if subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True).returncode != 0:
        r = subprocess.run(flags, capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
print('PASS: conhost.exe is refused only in an ARM64EC session, unless MADEIRA_EC_CONHOST=1')
