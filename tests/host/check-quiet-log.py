#!/usr/bin/env python3
"""quiet-log (madeira-d3d12) and MADEIRA_SRV_FGETPATH (wineserver); no Wine runs.

Horizon Zero Dawn on build 493 (2026-10-11 11:10) spent its menu and its first
minutes of play on our own logging and file naming:
  - every d3d12_log line also went through OutputDebugStringA, an exception and
    a wineserver request each (~0.5-0.75 ms a line on the device); the menu
    logged ~1000 lines a second while the game built pipelines;
  - every census frame (presents 1500-3000, every 200th) logged ~2000 lines and
    froze the game for 1.5-2 s;
  - the server named each file it opened with realpath (~0.5 ms a file), ~1000
    shader-cache files a second, on a performance core.

Checks:
  - d3d12_log calls OutputDebugStringA only without quiet-log, and still writes
    every line through __wine_dbg_output and stderr;
  - quiet-log is read once, when the device is created, after the Metal device
    and queue exist; census frames and every list 12000-12400 dump test are off
    with it, and a manual capture still turns the census frame on;
  - both "converted at runtime" lines go through the 64-then-every-1000th gate;
  - the server's open_fd names the file with srv_open_fd_name, which takes
    F_GETPATH only when the bridge set g_madeira_srv_fgetpath from
    MADEIRA_SRV_FGETPATH=1 after the game's env lines (the server is running
    before them) and falls back to realpath; the function, compiled on this
    host with a stand-in fcntl, behaves that way; the session end clears the
    switch and unsets it so a later game of the same app run does not inherit it;
  - the catalog documents both switches; Horizon Zero Dawn's list (version 16)
    sets both and no other game's list does.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
D3D = ROOT / "madeira-d3d12/src/pe/madeira_d3d12.c"
FD = ROOT / "build/wineserver/fd_ios.c"
REC = ROOT / "app/Madeira/GameRecommendations.swift"
CAT = ROOT / "app/Madeira/ConfigCatalog.generated.swift"
CI = ROOT / ".github/workflows/build-ipa.yml"
BRIDGE = ROOT / "app/Madeira/WineProcessBridge.m"

failures = []


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def func_body(src, signature):
    i = src.find(signature)
    if i < 0:
        return ""
    j = src.find("{", i)
    depth = 0
    for k in range(j, len(src)):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                return src[i:k + 1]
    return ""


d3d = D3D.read_text(encoding="utf-8")
log = func_body(d3d, "static void d3d12_log(const char *fmt, ...)")
check(bool(log), "d3d12_log found")
check("if (!g_quiet_log) OutputDebugStringA(buf);" in log, "d3d12_log skips OutputDebugStringA with quiet-log")
check(log.count("OutputDebugStringA(") == 1, "d3d12_log has no other OutputDebugStringA call")
check("if (dbg_output) dbg_output(buf);" in log and "fputs(buf, stderr);" in log,
      "d3d12_log still writes every line through __wine_dbg_output and stderr")
check(d3d.find("static int g_quiet_log;") < d3d.find("static void d3d12_log("), "g_quiet_log is declared before d3d12_log")

init = func_body(d3d, "static void mad_quiet_log_init(void)")
check('mad_cfg_int_pe("quiet-log", 0)' in init, "quiet-log is read from the config, default 0")
check(init.find("d3d12_log(") < init.find("g_quiet_log = 1;"), "the quiet-log line is logged before the switch takes effect")
create = func_body(d3d, "__declspec(dllexport) HRESULT WINAPI MadeiraD3D12CreateDevice(")
check(bool(create), "MadeiraD3D12CreateDevice found")
i_chk = create.find("if (!d->mtl_device || !d->mtl_queue)")
i_init = create.find("mad_quiet_log_init();")
i_qi = create.find("HRESULT hr = device_QI(")
check(0 <= i_chk < i_init < i_qi, "quiet-log is read once the Metal device and queue exist, before the device is handed out")
check(d3d.count("mad_quiet_log_init(") == 2, "mad_quiet_log_init has one caller")

win_plain = len(re.findall(r"\(g_list_seq >= 12000 && g_list_seq < 12400\)", d3d))
win_gated = d3d.count("(!g_quiet_log && g_list_seq >= 12000 && g_list_seq < 12400)")
check(win_plain == 0 and win_gated == 5, "all five list 12000-12400 dump tests are off with quiet-log (%d gated, %d not)" % (win_gated, win_plain))
check("g_census_on = !g_quiet_log && (s->presents >= 1500 && s->presents < 3000 && (s->presents % 200) == 0);" in d3d,
      "census frames are off with quiet-log")
i_c = d3d.find("g_census_on = !g_quiet_log && (s->presents >= 1500")
check(d3d.find("if (g_capture_on) g_census_on = 1;", i_c) > i_c, "a manual capture still turns the census frame on after it")

gate = func_body(d3d, "static int mad_conv_log_ok(void)")
check("if (!g_quiet_log) return 1;" in gate and "k <= 64 || k % 1000 == 0" in gate and "InterlockedIncrement" in gate,
      "the conversion-line gate passes everything without quiet-log, else the first 64 and every 1000th")
conv = [m.start() for m in re.finditer(r'd3d12_log\("\[madeira-d3d12\] %s converted at runtime:', d3d)]
check(len(conv) == 2, "two \"converted at runtime\" lines")


def line_before(src, pos):
    end = src.rfind("\n", 0, pos)
    start = src.rfind("\n", 0, end)
    return src[start + 1:end].strip()


check(all(line_before(d3d, p) == "if (mad_conv_log_ok())" for p in conv),
      "both \"converted at runtime\" lines are behind the gate")

fd = FD.read_text(encoding="utf-8")
fn = func_body(fd, "static char *srv_open_fd_name( int unix_fd, const char *path )")
check(bool(fn), "srv_open_fd_name found")
check("extern volatile int g_madeira_srv_fgetpath;" in fd and "if (g_madeira_srv_fgetpath == 1 && unix_fd != -1)" in fn,
      "srv_open_fd_name follows the bridge's g_madeira_srv_fgetpath (the server runs before a game's env is set)")
check("getenv" not in fn, "srv_open_fd_name does not read the environment itself")
check("#ifdef F_GETPATH" in fn and "fcntl( unix_fd, F_GETPATH, buf )" in fn and "return realpath( path, NULL );" in fn,
      "F_GETPATH when available, realpath as the fallback")
check("fd->unix_name = srv_open_fd_name( fd->unix_fd, path );" in fd, "open_fd names its file through srv_open_fd_name")
check(fd.find("static char *srv_open_fd_name(") < fd.find("fd->unix_name = srv_open_fd_name("), "srv_open_fd_name is defined before open_fd uses it")

br = BRIDGE.read_text(encoding="utf-8")
check("volatile int g_madeira_srv_fgetpath = 0;" in br, "the bridge defines g_madeira_srv_fgetpath, off")
i_env = br.find('fprintf(stderr, "[madeira-env] game %s=%s\\n", k.UTF8String, v.UTF8String);')
i_set = br.find('g_madeira_srv_fgetpath = (fp && fp[0] == \'1\') ? 1 : 0;')
check(0 <= i_env < i_set and 'const char *fp = getenv("MADEIRA_SRV_FGETPATH");' in br[i_env:i_set + 10],
      "the bridge sets it from MADEIRA_SRV_FGETPATH after the game's env lines are applied")
i_end = br.find('unsetenv("MADEIRA_SRV_FGETPATH");')
i_stop = br.find('wineserver_stop();', i_end)
check(i_end > i_set and 0 <= br.find("g_madeira_srv_fgetpath = 0;", i_end) < i_stop,
      "the session end unsets MADEIRA_SRV_FGETPATH and clears the global before the server stops")

# Compile the function on this host with a stand-in fcntl that returns a fixed path.
cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
if cc:
    tmp = Path(tempfile.mkdtemp(prefix="quietlog-"))
    harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#define F_GETPATH 50
static int fake_fail;
static int fake_fcntl(int fd, int cmd, char *buf) {
    if (cmd != F_GETPATH || fake_fail) return -1;
    snprintf(buf, PATH_MAX, "/private/var/fgetpath/%d", fd);
    return 0;
}
#define fcntl fake_fcntl
#define realpath fake_realpath
static char *fake_realpath(const char *p, char *r) { (void)r; char *s = malloc(strlen(p) + 10); sprintf(s, "REAL:%s", p); return s; }
volatile int g_madeira_srv_fgetpath;
FUNC
int main(int argc, char **argv) {
    char *n;
    g_madeira_srv_fgetpath = argv[1][0] == '1';
    fake_fail = argv[2][0] == '1';
    n = srv_open_fd_name(7, "/var/x/file");
    puts(n);
    free(n);
    return 0;
}
'''.replace("FUNC", fn)
    (tmp / "h.c").write_text(harness)
    r = subprocess.run([cc, "-o", str(tmp / "h"), str(tmp / "h.c")], capture_output=True, text=True)
    check(r.returncode == 0, "srv_open_fd_name compiles on the host" + ("" if r.returncode == 0 else ": " + r.stderr[-300:]))
    if r.returncode == 0:
        def run(on, fail):
            return subprocess.run([str(tmp / "h"), "1" if on else "0", "1" if fail else "0"],
                                  capture_output=True, text=True).stdout.strip()
        check(run(False, False) == "REAL:/var/x/file", "switch off: realpath")
        check(run(True, False) == "/private/var/fgetpath/7", "switch on: the descriptor's F_GETPATH path")
        check(run(True, True) == "REAL:/var/x/file", "switch on, F_GETPATH failing: realpath")
    shutil.rmtree(tmp, ignore_errors=True)
else:
    print("SKIP host compile of srv_open_fd_name (no C compiler)")

cat = CAT.read_text(encoding="utf-8")
check('key: "quiet-log"' in cat and 'key: "env.MADEIRA_SRV_FGETPATH"' in cat, "the catalog documents both switches")

rec = REC.read_text(encoding="utf-8")
m = re.search(r'static let horizonZeroDawn = GameRecommendation\(\s*id: "horizon-zero-dawn", title: "Horizon Zero Dawn", version: (\d+),'
              r'.*?config: """(.*?)"""', rec, re.S)
check(bool(m), "Horizon Zero Dawn's list found")
if m:
    check(int(m.group(1)) == 16, "Horizon Zero Dawn's list is version 16")
    cfg = m.group(2)
    check(re.search(r"^\s*quiet-log = 1$", cfg, re.M) is not None, "Horizon Zero Dawn's list sets quiet-log = 1")
    check(re.search(r"^\s*env\.MADEIRA_SRV_FGETPATH = 1$", cfg, re.M) is not None,
          "Horizon Zero Dawn's list sets env.MADEIRA_SRV_FGETPATH = 1")
hfw = re.search(r'static let horizonForbiddenWest = GameRecommendation\(\s*id: "horizon-forbidden-west", '
                r'title: "Horizon Forbidden West", version: (\d+),.*?config: """(.*?)"""', rec, re.S)
check(bool(hfw), "Horizon Forbidden West's list found")
if hfw:
    check(re.search(r"^\s*quiet-log = 1$", hfw.group(2), re.M) is not None
          and re.search(r"^\s*env\.MADEIRA_SRV_FGETPATH = 1$", hfw.group(2), re.M) is not None,
          "Horizon Forbidden West's list sets both switches")
rca = re.search(r'static let ratchetClankRiftApart = GameRecommendation\(\s*id: "ratchet-clank-rift-apart", '
                r'title: "Ratchet & Clank: Rift Apart", version: (\d+),.*?config: """(.*?)"""', rec, re.S)
check(bool(rca), "Ratchet & Clank: Rift Apart's list found")
if rca:
    check(re.search(r"^\s*quiet-log = 1$", rca.group(2), re.M) is not None
          and re.search(r"^\s*env\.MADEIRA_SRV_FGETPATH = 1$", rca.group(2), re.M) is not None,
          "Rift Apart's list sets both switches (HFW's general lines)")
others = rec
for found in (m, hfw, rca):
    if found:
        others = others.replace(found.group(0), "")
# Lists ported from community tested lists that also turn the log off: quiet-log only, never the
# server's F_GETPATH switch.
quiet_only = ("marvels-spider-man-miles-morales", "marvels-spider-man-remastered", "marvels-spider-man-2",
              "minecraft-dungeons-2")
for qid in quiet_only:
    q = re.search(r'static let \w+ = GameRecommendation\(\s*id: "%s",.*?config: """(.*?)"""' % re.escape(qid), rec, re.S)
    check(bool(q) and re.search(r"^\s*quiet-log = 1$", q.group(1), re.M) is not None
          and "MADEIRA_SRV_FGETPATH" not in q.group(1),
          "list %s sets quiet-log = 1 and not env.MADEIRA_SRV_FGETPATH" % qid)
    if q:
        others = others.replace(q.group(0), "")
check("quiet-log" not in re.sub(r"///.*", "", others) and "MADEIRA_SRV_FGETPATH" not in re.sub(r"///.*", "", others),
      "no other game's list sets either switch")

# The CI step exists only in the fork's workflow; upstream has no .github.
if CI.exists():
    check("python3 tests/host/check-quiet-log.py" in CI.read_text(encoding="utf-8"), "CI runs this check")

print()
if failures:
    print("%d check(s) failed" % len(failures))
    sys.exit(1)
print("all checks passed")
