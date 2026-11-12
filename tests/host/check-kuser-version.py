#!/usr/bin/env python3
"""[kuser-version]: KUSER_SHARED_DATA carries the Windows version (10.0 build 19045, workstation) instead of 0.0 build 0.

StarCraft's ClientSdk.dll polled 0x7ffe0260 / 0x7ffe026c / 0x7ffe0270 (NtBuildNumber, NtMajorVersion, NtMinorVersion) 60k+ times and
then called rip=0. virtual_init_user_shared_data (build/ntdll-unix/virtual_ios.c) never set those fields. It now calls
ios_kuser_version(), which writes NtBuildNumber (0x260), NtProductType (0x264), ProductTypeIsValid (0x268), NtMajorVersion (0x26c)
and NtMinorVersion (0x270). The values match init_peb (10 / 0 / 19045) in wine's env.c and the iOS env_ios.c.

Checks, without a device:
  - the helper is compiled and run against a mock page whose fields sit at the real offsets: values, plain build number (no 0xF0000000
    flags), product type 1, ProductTypeIsValid 1, the switch MADEIRA_KUSER_VERSION=0 (only "0" turns it off) leaves the page zero,
    and the log line prints once per call up to four times;
  - virtual_init_user_shared_data calls it right after init_shared_data_cpuinfo, on the page it maps from the shared section;
  - the numbers equal the PEB numbers in env_ios.c / wine env.c;
  - nothing else in build/ writes those five fields (so nothing overwrites or bypasses them), the 32-bit view
    (ios_wow_map_user_shared_data) maps the same section, and the 64-bit sub-floor window points at that same page.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os, re, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text(errors='replace')

def between(a, b, frm=0):
    i = src.index(a, frm)
    return src[i:src.index(b, i)], i

helper, hat = between('#define IOS_KUSER_MAJOR', '\n}\n')
helper += '\n}\n'
for need in ('MADEIRA_KUSER_VERSION', "e[0] == '0' && !e[1]", '[kuser-version] %u.%u build %u', 'logged++ < 4'):
    assert need in helper, need

# the call site
init, _ = between('void virtual_init_user_shared_data(void)', '\n}\n')
assert init.index('init_shared_data_cpuinfo( data );') < init.index('ios_kuser_version( data );') < init.index('munmap( data, sizeof(*data) )')
assert 'MAP_SHARED, fd, 0' in init and 'shared_data_nameW' in src[src.index('void virtual_init_user_shared_data(void)'):][:600]

# values equal the PEB's
for f in ('build/ntdll-unix/env_ios.c', 'wine/dlls/ntdll/unix/env.c'):
    p = root / f
    if not p.exists():
        continue
    t = p.read_text(errors='replace')
    if 'OSBuildNumber' in t and f.endswith('env.c'):
        assert re.search(r'OSMajorVersion\s*=\s*10;', t) and re.search(r'OSMinorVersion\s*=\s*0;', t) and re.search(r'OSBuildNumber\s*=\s*19045;', t), f
assert '#define IOS_KUSER_MAJOR 10' in helper and '#define IOS_KUSER_MINOR 0' in helper and '#define IOS_KUSER_BUILD 19045' in helper

# nothing else writes the fields
for f in (root / 'build').rglob('*.c'):
    if 'ffmpeg' in f.parts or 'mesa-d3d12' in f.parts:
        continue
    t = f.read_text(errors='replace')
    n = len(re.findall(r'(NtMajorVersion|NtMinorVersion|NtBuildNumber|ProductTypeIsValid|NtProductType)\s*=[^=]', t))
    if f.name == 'virtual_ios.c':
        assert n == 5, ('virtual_ios.c should assign the five fields exactly once', n)
    else:
        assert n == 0, (str(f), n)
assert 'memset( data' not in init and 'memset(data' not in init
wow, _ = between('void ios_wow_map_user_shared_data(void)', '\n}\n')
assert 'shared_data_nameW' in wow.split('{', 1)[1][:400] and 'NtMapViewOfSection' in wow and 'PAGE_READONLY' in wow
assert 'ios_register_subfloor_image( 0x7ffe0000ull' in src

# the helper, compiled and run
prog = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#define TRUE 1
#define dprintf(fd, ...) do { if (fd == 2) { printf(__VA_ARGS__); } } while (0)
typedef unsigned int ULONG; typedef unsigned char BOOLEAN;
enum { NtProductWinNt = 1 };
typedef struct { char pad0[0x260]; ULONG NtBuildNumber; ULONG NtProductType; BOOLEAN ProductTypeIsValid; char pad1[3];
                 ULONG NtMajorVersion; ULONG NtMinorVersion; char pad2[0x100]; } KUSER_SHARED_DATA;
''' + helper + r'''
int main(void)
{
    KUSER_SHARED_DATA d;
    unsigned char *b = (unsigned char *)&d;
    if (offsetof(KUSER_SHARED_DATA, NtBuildNumber) != 0x260 || offsetof(KUSER_SHARED_DATA, NtMajorVersion) != 0x26c ||
        offsetof(KUSER_SHARED_DATA, NtMinorVersion) != 0x270) return 90;
    unsetenv("MADEIRA_KUSER_VERSION");
    memset(&d, 0, sizeof(d)); ios_kuser_version(&d);
    if (*(ULONG *)(b + 0x260) != 19045) return 1;
    if ((*(ULONG *)(b + 0x260) & 0xF0000000u) != 0) return 2;
    if (*(ULONG *)(b + 0x264) != 1) return 3;
    if (b[0x268] != 1) return 4;
    if (*(ULONG *)(b + 0x26c) != 10) return 5;
    if (*(ULONG *)(b + 0x270) != 0) return 6;
    setenv("MADEIRA_KUSER_VERSION", "0", 1);
    memset(&d, 0, sizeof(d)); ios_kuser_version(&d);
    for (size_t i = 0; i < sizeof(d); i++) if (b[i]) return 7;
    setenv("MADEIRA_KUSER_VERSION", "00", 1);
    ios_kuser_version(&d); if (d.NtMajorVersion != 10) return 8;
    setenv("MADEIRA_KUSER_VERSION", "1", 1);
    memset(&d, 0, sizeof(d)); ios_kuser_version(&d); if (d.NtMajorVersion != 10) return 9;
    unsetenv("MADEIRA_KUSER_VERSION");
    for (int i = 0; i < 6; i++) ios_kuser_version(&d);
    return 0;
}
'''
with tempfile.TemporaryDirectory() as d:
    c = Path(d, 't.c'); c.write_text(prog)
    exe = Path(d, 't')
    subprocess.run([os.environ.get('CC', 'cc'), '-Wall', '-Werror', '-o', str(exe), str(c)], check=True)
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    assert r.returncode == 0, ('helper test failed', r.returncode, r.stdout)
    lines = [l for l in r.stdout.splitlines() if l.startswith('[kuser-version]')]
    assert lines[0] == '[kuser-version] 10.0 build 19045', lines
    assert len(lines) == 4, ('log is capped at the first four', len(lines))
print('ok')