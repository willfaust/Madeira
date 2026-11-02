#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""The virtual monitor's Win32 names (build/win32u-unix/sysparams_ios.c); no Wine runs.

Compiles the production helpers (ios_vmon_ids_enabled .. ios_vmon_device_key) against stubs and checks the strings
NtUserEnumDisplayDevices hands out for the monitor under "\\\\.\\DISPLAY1" -- the
same ones the engine answered before an earlier switch (device interface
path with EDD_GET_DEVICE_INTERFACE_NAME, MONITOR\\... instance id without, the
monitor class key) -- and that MADEIRA_VMON_IDS=0 turns them off. Then checks
the wiring in the file: GetMonitorInfo names the virtual monitor
"\\\\.\\DISPLAY1" (not "WinDisc") unless switched off, the synthesized monitor
gets those ids, the adapter keeps its PCI id / Video key and no interface name.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/win32u-unix/sysparams_ios.c").read_text()
# the switch and the two id writers, from ios_vmon_ids_enabled to the end of ios_vmon_device_key
_key = src.index("static void ios_vmon_device_key( char *buffer, size_t size )")
region = src[src.index("static int ios_vmon_ids_enabled(void)"):src.index("\n}\n", _key) + 3]

# Wiring, read from the file itself.
info = src[src.index("static void monitor_get_info("):]
info = info[:info.index("\n}\n")]
assert re.search(r'else if \(monitor == &virtual_monitor && ios_vmon_ids_enabled\(\)\) strcpy\( buffer, "\\\\\\\\\.\\\\DISPLAY1" \);\n'
                 r'#endif\n        else strcpy\( buffer, "WinDisc" \);', info), "monitor_get_info: virtual monitor name"
edd = src[src.index("NTSTATUS WINAPI NtUserEnumDisplayDevices("):]
edd = edd[:edd.index("if (!lock_display_devices( FALSE )) return STATUS_UNSUCCESSFUL;")]
assert "else if (!is_adapter && ios_vmon_ids_enabled()) ios_vmon_device_id( flags, id, sizeof(id) );" in edd
assert "else if (ios_vmon_ids_enabled()) ios_vmon_device_key( key, sizeof(key) );" in edd
assert "if (is_adapter && !(flags & EDD_GET_DEVICE_INTERFACE_NAME))" in edd
assert 'PCI\\\\VEN_%04X&DEV_%04X&SUBSYS_00000000&REV_00' in edd
assert 'snprintf( key, sizeof(key), "%s\\\\Video\\\\%s\\\\0000", control_keyA, ios_video_guidA );' in edd
assert 'static const char ios_video_guidA[] = "{8C0C2A5B-0E7E-4B0E-9E3F-1D0A6B5C4D21}";' in src
# The first static definition of the helpers precedes both users.
assert src.index("static int ios_vmon_ids_enabled(void)") < src.index("static void monitor_get_info(")

consts = "\n".join(l for l in src.splitlines()
                   if re.match(r"static const char\s+(control_keyA|guid_devclass_monitorA|guid_devinterface_monitorA)\[\]", l))
harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned int DWORD;
#define EDD_GET_DEVICE_INTERFACE_NAME 0x00000001
""" + consts + "\n" + region + r"""
int main( int argc, char **argv )
{
    char id[260], key[260];
    int on = ios_vmon_ids_enabled();
    ios_vmon_device_id( EDD_GET_DEVICE_INTERFACE_NAME, id, sizeof(id) );
    printf( "%d\n%s\n", on, id );
    ios_vmon_device_id( 0, id, sizeof(id) );
    ios_vmon_device_key( key, sizeof(key) );
    printf( "%s\n%s\n", id, key );
    return strlen( id ) >= 128 || strlen( key ) >= 128;   /* DISPLAY_DEVICEW fields are 128 WCHARs */
}
"""
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    print("PASS: wiring in sysparams_ios.c; SKIP: the vmon helpers need a C compiler")
    sys.exit(0)
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "vmon.c"; c.write_text(harness)
    exe = Path(t) / "vmon"
    subprocess.run([cc,"-std=gnu11", "-Wall", "-Wno-unused-function", "-fsanitize=address,undefined",
                    str(c), "-o", str(exe)], check=True)
    def run(env):
        e = {k: v for k, v in os.environ.items() if k != "MADEIRA_VMON_IDS"}
        e.update(env)
        r = subprocess.run([str(exe)], capture_output=True, text=True, env=e)
        assert r.returncode == 0, (env, r.returncode, r.stdout, r.stderr)
        return r.stdout.splitlines()
    out = run({})
    assert out == ["1",
                   "\\\\?\\DISPLAY#Default_Monitor#4&madeira&0&UID0#{E6F07B5F-EE97-4A90-B076-33F57BF4EAA7}",
                   "MONITOR\\Default_Monitor\\{4D36E96E-E325-11CE-BFC1-08002BE10318}\\0000",
                   "\\Registry\\Machine\\System\\CurrentControlSet\\Control\\Class\\{4D36E96E-E325-11CE-BFC1-08002BE10318}\\0000"], out
    assert run({"MADEIRA_VMON_IDS": "1"})[0] == "1"
    assert run({"MADEIRA_VMON_IDS": "0"})[0] == "0"

print("PASS: virtual monitor named \\\\.\\DISPLAY1 by GetMonitorInfo; EnumDisplayDevices gives it the earlier "
      "interface path, instance id and class key; adapter ids unchanged; MADEIRA_VMON_IDS=0 restores upstream")
