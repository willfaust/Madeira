#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""Opt-in available physical memory (madeira.cfg avail-phys = 1), the ntdll side; no Wine runs.

  - ios_avail_phys, cut out of build/ntdll-unix/virtual_ios.c and compiled on
    the host with stubs: off (the default) returns the phone's free memory
    untouched and never asks iOS; on, returns min(headroom, phone's free), and
    the phone's figure when iOS answers 0 or a "no limit" sentinel larger than
    the machine; the config is read once; one log line per band change
    (1000 MB / 400 MB, Chromium's levels), at most 64;
  - avail-phys-cef-mb (read once with madeira_cfg_int, 0 = off): only a
    Chromium browser (ios_avail_phys_chromium: a known Chromium helper's name
    as the last component of the PEB's image path, any case; compiled on the
    host against a stub PEB) sees at most N MB, with avail-phys off (the
    phone's figure capped) or on (the headroom capped); everyone else gets
    exactly what they got before; a smaller real figure is never raised; the
    band log lines still follow the real headroom; at most 4 cap lines;
  - the catalog lists avail-phys (off) and avail-phys-cef-mb (0), when it exists.
The Wine-side patch (get_performance_info passing freeram through
ios_avail_phys) is not checked here. The runtime part needs a host C compiler
(CC, cc, gcc or clang) and is skipped without one.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


# --- ios_avail_phys on the host ---
v = (root / "build/ntdll-unix/virtual_ios.c").read_text(encoding="utf-8", errors="replace")
start = v.index("unsigned long long ios_avail_phys( unsigned long long host_free )")
func = v[start:v.index("\n}\n", start) + 3]
check("ios_avail_phys reads avail-phys once with madeira_cfg_bool, off by default",
      'on = madeira_cfg_bool( "avail-phys", 0 );' in func and "if (on < 0)" in func)
cstart = v.index("static int ios_avail_phys_chromium( void )\n{")   # the definition, not the forward declaration
chromium = v[cstart:v.index("\n}\n", cstart) + 3]
check("avail-phys-cef-mb is read once with madeira_cfg_int (0 = off) next to avail-phys",
      'mb = madeira_cfg_int( "avail-phys-cef-mb", 0 );' in func
      and func.index("if (on < 0)") < func.index('madeira_cfg_int( "avail-phys-cef-mb"') < func.index("left = (unsigned long long)os_proc_available_memory()"))
check("the cap is applied last, only for a Chromium browser, never raising a value",
      func.index("cef && value > cef && ios_avail_phys_chromium()") > func.index("if (left < host_free) value = left;")
      and v.index("static int ios_avail_phys_chromium( void )") < start)
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
if not cc or not shutil.which(cc):
    print("SKIP runtime checks: no host C compiler")
else:
    harness = r'''
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
typedef uint16_t WCHAR;
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { UNICODE_STRING ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { RTL_USER_PROCESS_PARAMETERS *ProcessParameters; } PEB;
static PEB cur_peb, *cur;
static RTL_USER_PROCESS_PARAMETERS cur_pp;
static WCHAR cur_path[260];
static void *ios_jit_current_peb(void) { return cur; }
static void set_image(const char *path)
{
    size_t n = 0;
    if (!path) { cur = NULL; return; }
    for (; path[n]; n++) cur_path[n] = (unsigned char)path[n];
    cur_pp.ImagePathName.Buffer = n ? cur_path : NULL;
    cur_pp.ImagePathName.Length = cur_pp.ImagePathName.MaximumLength = (unsigned short)(n * 2);
    cur_peb.ProcessParameters = &cur_pp;
    cur = &cur_peb;
}
static int cfg_reads, cfg_on, ios_calls, lines;
static long long cfg_cef;
static size_t ios_left;
static unsigned long long fake_memsize = 12ull << 30;
static char last[256];
static int madeira_cfg_bool(const char *key, int dflt) { cfg_reads++; return strcmp(key, "avail-phys") ? dflt : cfg_on; }
static long long madeira_cfg_int(const char *key, long long dflt) { cfg_reads++; return strcmp(key, "avail-phys-cef-mb") ? dflt : cfg_cef; }
size_t os_proc_available_memory(void) { ios_calls++; return ios_left; }
static int sysctlbyname(const char *n, void *out, size_t *len, void *nv, size_t nl)
{ (void)nv; (void)nl; if (strcmp(n, "hw.memsize") || *len != 8) return -1; memcpy(out, &fake_memsize, 8); return 0; }
static int fake_dprintf(int fd, const char *fmt, ...)
{ va_list a; (void)fd; va_start(a, fmt); vsnprintf(last, sizeof last, fmt, a); va_end(a); lines++; return 0; }
#define dprintf fake_dprintf
''' + chromium + func + r'''
#define MB (1ull << 20)
#define TITLE "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Title\\Title.exe"
#define HELPER "C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\steamwebhelper.exe"
#define LAUNCHER "C:\\Program Files\\Launcher\\Launcher.exe"
int main(void)
{
    int bad = 0;
#define EXPECT(c, what) do { if (!(c)) { printf("FAIL %s\n", what); bad = 1; } } while (0)
    set_image(TITLE);
#if CEF
    set_image(HELPER);
    EXPECT(ios_avail_phys_chromium(), "helper recognised");
    set_image("\\??\\C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\STEAMWEBHELPER.EXE");
    EXPECT(ios_avail_phys_chromium(), "steamwebhelper recognised, NT path, upper case");
    set_image("steamwebhelper.exe");
    EXPECT(ios_avail_phys_chromium(), "bare name");
    set_image(LAUNCHER);
    EXPECT(!ios_avail_phys_chromium(), "the launcher is not Chromium");
    set_image("C:\\x\\steamwebhelper.exe.bak");
    EXPECT(!ios_avail_phys_chromium(), "suffix");
    set_image("C:\\x\\xsteamwebhelper.exe");
    EXPECT(!ios_avail_phys_chromium(), "prefix");
    set_image("C:\\x\\");
    EXPECT(!ios_avail_phys_chromium(), "empty last component");
    set_image("");
    EXPECT(!ios_avail_phys_chromium(), "no image path");
    set_image(NULL);
    EXPECT(!ios_avail_phys_chromium(), "no PEB");

    cfg_cef = 300;
    cfg_on = CEF_ON;
    ios_left = 5000 * MB;
    set_image(TITLE);
    EXPECT(ios_avail_phys(4000 * MB) == 4000 * MB, "cef: the title keeps its figure");
    set_image(LAUNCHER);
    EXPECT(ios_avail_phys(4000 * MB) == 4000 * MB, "cef: the launcher keeps its figure");
    set_image(HELPER);
    EXPECT(ios_avail_phys(4000 * MB) == 300 * MB, "cef: the helper sees the cap");
    EXPECT(strstr(last, "300 MB reported instead of 4000 MB"), "cef: the cap is logged");
    EXPECT(ios_avail_phys(200 * MB) == 200 * MB, "cef: a smaller phone figure is never raised");
    ios_left = 250 * MB;
    EXPECT(ios_avail_phys(4000 * MB) == (CEF_ON ? 250 : 300) * MB, "cef: headroom below the cap wins with avail-phys");
    set_image(TITLE);
    EXPECT(ios_avail_phys(4000 * MB) == (CEF_ON ? 250 : 4000) * MB, "cef: the title sees the real figure");
    EXPECT(CEF_ON ? ios_calls == 6 : ios_calls == 0, "cef: iOS asked only with avail-phys");
    EXPECT(cfg_reads == 2, "cef: config read once (two keys)");
    {
        int before = lines;
        set_image("steamwebhelper.exe");
        ios_left = 5000 * MB;
        for (int i = 0; i < 50; i++) ios_avail_phys(4000 * MB);
        EXPECT(lines - before <= 4, "cef: at most 4 cap lines");
    }
#elif OFF
    ios_left = 100 * MB;
    EXPECT(ios_avail_phys(3000 * MB) == 3000 * MB, "off: the phone's free memory, untouched");
    EXPECT(ios_avail_phys(2000 * MB) == 2000 * MB, "off: again");
    EXPECT(ios_calls == 0, "off: iOS is never asked");
    EXPECT(cfg_reads == 2, "off: config read once (two keys)");
    EXPECT(lines == 0, "off: no log line");
    set_image("steamwebhelper.exe");
    EXPECT(ios_avail_phys(3000 * MB) == 3000 * MB, "off: avail-phys-cef-mb unset leaves the helper alone");
#else
    cfg_on = 1;
    ios_left = 2500 * MB;
    EXPECT(ios_avail_phys(4000 * MB) == 2500 * MB, "on: headroom below the phone's free memory wins");
    EXPECT(lines == 2 && strstr(last, "2500 MB left") && strstr(last, "1000 MB or more"), "on: first band logged");
    ios_left = 5000 * MB;
    EXPECT(ios_avail_phys(4000 * MB) == 4000 * MB, "on: the phone's free memory when it is smaller");
    EXPECT(lines == 2, "on: same band, no line");
    ios_left = 900 * MB;
    EXPECT(ios_avail_phys(4000 * MB) == 900 * MB, "on: 900 MB");
    EXPECT(lines == 3 && strstr(last, "moderate"), "on: moderate band logged");
    ios_left = 300 * MB;
    EXPECT(ios_avail_phys(4000 * MB) == 300 * MB && lines == 4 && strstr(last, "critical"), "on: critical band logged");
    EXPECT(ios_avail_phys(4000 * MB) == 300 * MB && lines == 4, "on: no repeat while in the band");
    ios_left = 0;
    EXPECT(ios_avail_phys(4000 * MB) == 4000 * MB, "on: iOS answers 0 -> the phone's figure");
    ios_left = (size_t)0x7ffffddb00000ull;
    EXPECT(ios_avail_phys(4000 * MB) == 4000 * MB, "on: a no-limit sentinel -> the phone's figure");
    EXPECT(cfg_reads == 2, "on: config read once (two keys)");
    set_image("steamwebhelper.exe");
    ios_left = 2000 * MB;
    EXPECT(ios_avail_phys(4000 * MB) == 2000 * MB, "on: avail-phys-cef-mb unset leaves the helper's headroom alone");
    for (int i = 0; i < 200; i++) { ios_left = (i & 1) ? 300 * MB : 2000 * MB; ios_avail_phys(4000 * MB); }
    EXPECT(lines <= 65, "on: at most 64 band lines");
#endif
    if (!bad) printf("ok\n");
    return bad;
}
'''
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / "h.c").write_text(harness)
        for name, defs in (("off", ["-DCEF=0", "-DOFF=1"]), ("on", ["-DCEF=0", "-DOFF=0"]),
                           ("avail-phys-cef-mb = 300, avail-phys off", ["-DCEF=1", "-DCEF_ON=0", "-DOFF=0"]),
                           ("avail-phys-cef-mb = 300, avail-phys on", ["-DCEF=1", "-DCEF_ON=1", "-DOFF=0"])):
            exe = t / ("h%d" % len(list(t.iterdir())))
            r = subprocess.run([cc, "-std=gnu99", "-Wall", "-Wno-unused-function"] + defs +
                               ["-o", str(exe), str(t / "h.c")], capture_output=True, text=True)
            if r.returncode:
                print(r.stderr[-2000:])
            out = subprocess.run([str(exe)], capture_output=True, text=True).stdout if exe.exists() else ""
            check("ios_avail_phys runtime, switch %s" % name, r.returncode == 0 and out.strip() == "ok")
            if out.strip() != "ok":
                print(out)

# --- catalog ---
catalog = root / "app/Madeira/ConfigCatalog.generated.swift"
if catalog.exists():
    cat = catalog.read_text(encoding="utf-8", errors="replace")
    check("catalog lists avail-phys, off by default",
          re.search(r'key: "avail-phys".*kind: \.bool, defaultValue: "0"', cat) is not None)
    check("catalog lists avail-phys-cef-mb, 0 (off) by default",
          re.search(r'key: "avail-phys-cef-mb".*kind: \.int, defaultValue: "0"', cat) is not None)

print("PASS" if ok else "FAILED")
sys.exit(0 if ok else 1)
