#!/usr/bin/env python3
"""env.MADEIRA_APP_DLL_SHADOW: named app-local x64 DLLs are refused like ucrtbase.dll.

Crysis 3 Remastered (build 547, log 2026-10-15 15:08:17) ships Microsoft's x64
vcruntime140.dll beside its exe but not msvcp140.dll. Wine's ARM64EC
msvcp140.dll (sysx64) then imported that x64 memcpy through a stub without an
exit thunk and branched to its own MZ header (c000001d, "MSVCP140.dll failed
to initialize"). build/ntdll-unix/virtual_ios.c's ios_ucrt_shadow_refused
gains an opt-in list: a plain x64 image named there, outside \\windows\\, is
reported as not loadable, so the loader binds the system's.

Checks:
  - ios_app_dll_listed and ios_path_in_windows, cut out of virtual_ios.c and
    compiled on the host: names match whole and in any case, with ';', ','
    or spaces between them; a prefix, a longer name or an empty list does not
    match; \\windows\\ anywhere in the path (any case, '/' too) counts, a
    folder named "windowsapps" or "mywindows" does not;
  - unset, nothing changes: the ucrtbase refusal and MADEIRA_APP_UCRT=1 work
    as before (the only early return keeps its old condition), and the new
    refusal needs the list and a path outside \\windows\\;
  - the gate before both stays: plain x64 (not hybrid, not a Wine builtin) in
    an x64 (ARM64EC) process;
  - CI runs this check (where the repository has the workflow); the settings
    catalog documents the switch.
The host compile is skipped when no C compiler is found.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

R = Path(__file__).resolve().parents[2]
src = (R / "build/ntdll-unix/virtual_ios.c").read_text()
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok = ok and bool(cond)


def cut(start, end_marker="\n}\n"):
    i = src.index(start)
    return src[i:src.index(end_marker, i) + len(end_marker)]


helpers = cut("static BOOL ios_app_dll_listed(") + "\n" + cut("static BOOL ios_path_in_windows(")
fn = cut("static BOOL ios_ucrt_shadow_refused(")

cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    print("SKIP host compile: no C compiler")
else:
    harness = r'''
#include <stdio.h>
#include <string.h>
typedef unsigned short WCHAR, USHORT;
typedef int BOOL;
#define TRUE 1
#define FALSE 0
''' + helpers + r'''
static int fails;
static void W(WCHAR *out, const char *s) { while ((*out++ = (unsigned char)*s++)); }
static void listed(const char *list, const char *name, int want) {
    WCHAR w[128]; W(w, name);
    if (ios_app_dll_listed(list, w, (USHORT)strlen(name)) != want) { printf("listed(\"%s\", %s) != %d\n", list, name, want); fails++; }
}
static void inwin(const char *path, int want) {
    WCHAR w[256]; W(w, path);
    if (ios_path_in_windows(w, (USHORT)strlen(path)) != want) { printf("in_windows(%s) != %d\n", path, want); fails++; }
}
int main(void) {
    listed("vcruntime140.dll", "vcruntime140.dll", 1);
    listed("vcruntime140.dll", "VCRUNTIME140.DLL", 1);
    listed("VCRuntime140.dll", "vcruntime140.dll", 1);
    listed("msvcp140.dll;vcruntime140.dll", "vcruntime140.dll", 1);
    listed("msvcp140.dll, vcruntime140.dll", "vcruntime140.dll", 1);
    listed(" ;vcruntime140.dll; ", "vcruntime140.dll", 1);
    listed("vcruntime140.dll;vcruntime140_1.dll", "vcruntime140_1.dll", 1);
    listed("vcruntime140.dll", "vcruntime140_1.dll", 0);
    listed("vcruntime140_1.dll", "vcruntime140.dll", 0);
    listed("vcruntime140", "vcruntime140.dll", 0);
    listed("vcruntime140.dll", "vcruntime140.dl", 0);
    listed("", "vcruntime140.dll", 0);
    listed(";;", "vcruntime140.dll", 0);
    inwin("\\??\\C:\\windows\\sysx64\\vcruntime140.dll", 1);
    inwin("\\??\\C:\\WINDOWS\\System32\\vcruntime140.dll", 1);
    inwin("\\??\\unix/private/var/x/drive_c/windows/system32/a.dll", 1);
    inwin("\\??\\C:\\Program Files (x86)\\Steam\\steamapps\\common\\Crysis3Remastered\\Bin64\\vcruntime140.dll", 0);
    inwin("\\??\\C:\\Program Files\\WindowsApps\\x\\vcruntime140.dll", 0);
    inwin("\\??\\C:\\Games\\mywindows\\vcruntime140.dll", 0);
    inwin("\\windows", 0);
    printf("%s\n", fails ? "HARNESS FAILED" : "harness ok");
    return fails != 0;
}
'''
    with tempfile.TemporaryDirectory() as tmp:
        c = os.path.join(tmp, "t.c")
        exe = os.path.join(tmp, "t")
        open(c, "w").write(harness)
        b = subprocess.run([cc, "-std=c99", "-Wall", "-Werror", "-fsanitize=address,undefined", c, "-o", exe],
                           capture_output=True, text=True)
        if b.returncode:
            b = subprocess.run([cc, "-std=c99", "-Wall", "-Werror", c, "-o", exe], capture_output=True, text=True)
        check("the helpers compile on the host", b.returncode == 0)
        if b.returncode == 0:
            r = subprocess.run([exe], capture_output=True, text=True)
            print(r.stdout.strip())
            check("names match whole, in any case, with ; , or spaces between; \\windows\\ paths are recognised",
                  r.returncode == 0)
        else:
            print(b.stderr[-2000:])

gate = ('    if (pi->machine != IMAGE_FILE_MACHINE_AMD64 || pi->is_hybrid || pi->wine_builtin) return FALSE;\n'
        '    if (!ios_is_arm64ec_cur()) return FALSE;\n')
check("the gate stays: plain x64 images in an x64 (ARM64EC) process", gate in fn)
check("unset, the early return keeps its old condition (MADEIRA_APP_UCRT=1 turns the ucrt refusal off)",
      'shadow = getenv( "MADEIRA_APP_DLL_SHADOW" );' in fn and
      "    if (shadow && !*shadow) shadow = NULL;\n    if (opt && !shadow) return FALSE;\n" in fn and
      fn.count("return FALSE;") == 5)
check("the ucrtbase refusal is unchanged apart from its MADEIRA_APP_UCRT guard",
      "    if (!opt && name && len == sizeof(ucrt) - 1)\n" in fn and
      '"[ucrt-shadow] %s: plain x64 ucrtbase.dll outside the system farm' in fn)
blk = fn[fn.index("if (!ret && shadow"):]
check("the new refusal needs the list, a listed name and a path outside \\windows\\, and logs [app-dll-shadow]",
      blk.index("ios_app_dll_listed( shadow, name, len )") < blk.index("!ios_path_in_windows(") <
      blk.index("ret = TRUE;") < blk.index('"[app-dll-shadow] %s:'))
CI = R / ".github/workflows/build-ipa.yml"
if CI.exists():
    check("CI runs this check", "run: python3 tests/host/check-app-dll-shadow.py" in CI.read_text())
cat = (R / "app/Madeira/ConfigCatalog.generated.swift").read_text()
check("the catalog documents env.MADEIRA_APP_DLL_SHADOW (default empty)",
      'ConfigOption(key: "env.MADEIRA_APP_DLL_SHADOW", title: "Ignore these DLLs in the game\'s folder", '
      'kind: .text, defaultValue: ""' in cat)

print("PASS: app dll shadow" if ok else "FAILED: app dll shadow")
sys.exit(0 if ok else 1)
