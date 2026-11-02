#!/usr/bin/env python3
"""ml2280: an aarch64 program is refused in an ARM64EC session; no Wine runs.

Testers' log of 2026-10-28: a launcher installer's service helper made sechost
start services.exe (aarch64) on demand in a session whose first program is x64.
The session's ntdll loaded the emulator into it, its threads had no CPU area,
it faulted at its first executable allocation and its exception path faulted
until the storm handler ended it, twice. Compiles the production
ec_native_child_refuse from build/ntdll-unix/process_ios.c, checks the
NtCreateUserProcess call site textually, and checks that the list for GTA V
Enhanced outside Steam starts in the Wine desktop (an aarch64 session).
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
call = 'ec_native_child_refuse( is_arm64ec(), getenv( "MADEIRA_EC_NATIVE_CHILD" ), machine )'
assert call in create
gate = create[create.index(call):][:900]
assert 'status = STATUS_ACCESS_DENIED;' in gate and 'goto done;' in gate
assert '!conhost_on && ' + call in create, 'MADEIRA_EC_CONHOST=1 still lets conhost.exe through'
# after the machine is known (hybrid images promoted), before anything is set up for the child
assert create.index('machine = ios_cur_image_info()->Machine;') < create.index(call)
assert create.index(call) < create.index('create_startup_info( attr.ObjectName')

code = r'''
#include <stdio.h>
typedef unsigned short USHORT;
#define IMAGE_FILE_MACHINE_I386  0x014c
#define IMAGE_FILE_MACHINE_AMD64 0x8664
#define IMAGE_FILE_MACHINE_ARM64 0xaa64
'''
code += function(source, 'static int ec_native_child_refuse(')
code += r'''
#define FAIL(m) do { fputs( m, stderr ); return 1; } while (0)
int main( void )
{
    if (!ec_native_child_refuse( 1, NULL, IMAGE_FILE_MACHINE_ARM64 ) ||
        !ec_native_child_refuse( 1, "0", IMAGE_FILE_MACHINE_ARM64 ) ||
        !ec_native_child_refuse( 1, "", IMAGE_FILE_MACHINE_ARM64 )) FAIL( "aarch64 child allowed in an EC session\n" );
    if (ec_native_child_refuse( 0, NULL, IMAGE_FILE_MACHINE_ARM64 )) FAIL( "aarch64 session refused its own\n" );
    if (ec_native_child_refuse( 1, "1", IMAGE_FILE_MACHINE_ARM64 )) FAIL( "MADEIRA_EC_NATIVE_CHILD=1 refused\n" );
    if (ec_native_child_refuse( 1, NULL, IMAGE_FILE_MACHINE_AMD64 ) ||
        ec_native_child_refuse( 1, NULL, IMAGE_FILE_MACHINE_I386 )) FAIL( "x86 child refused\n" );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-ec-native-child-') as directory:
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

recs = (root / 'app/Madeira/GameRecommendations.swift').read_text(encoding='utf-8')
other = recs[recs.index('static let gta5EnhancedOther = GameRecommendation('):]
other = other[:other.index('\n    ///')]
assert 'version: 10,' in other and 'launchMode: "desktop"' in other, 'the outside-Steam list starts in the Wine desktop'
assert 'startServices' not in other, 'no services batch (it would carry the Epic sign-in arguments)'

catalog = root / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    assert 'key: "env.MADEIRA_EC_NATIVE_CHILD"' in catalog.read_text(encoding='utf-8')
print('PASS: an aarch64 program is refused only in an ARM64EC session, unless MADEIRA_EC_NATIVE_CHILD=1; '
      'GTA V Enhanced outside Steam starts in the Wine desktop')
