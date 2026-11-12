#!/usr/bin/env python3
"""env.MADEIRA_JIT_POOL_AUTO: a library game whose session logs `[jit-pool] EXHAUSTED`
gets `pool-split = 1` and `env.MADEIRA_X64_IMAGE_NOCOPY = 1` in its own config, and the
alert after the session asks for Madeira to be reopened (the pool is set up once per app
run). Read from the sources; no Wine runs. Part 2 runs the same line-adding rule in Python.

1. LibraryModel.poll checks once per session, when JITPoolMeter counted an EXHAUSTED line,
   and only for a library entry that is not the Wine desktop.
2. begin() resets the check; finish() shows the alert after a Steam run request but before
   the exit report, and clears the title.
3. JITPoolAuto leaves a key the game's config already sets (any value) alone, writes through
   GameProfile (the file MADEIRA_CFG_GAME exports), checks the write and logs.
4. The catalog lists the switch, on by default.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
bcd = (root / "app/Madeira/LibraryBCD.swift").read_text(encoding="utf-8")
lib = (root / "app/Madeira/Library.swift").read_text(encoding="utf-8")
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text(encoding="utf-8")
gen = (root / "build/tools/gen-config-catalog.py").read_text(encoding="utf-8")
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


def body(src, sig, end="\n    }\n"):
    start = src.index(sig)
    return src[start:src.index(end, start)]


poll = body(lib, "    private func poll() {")
check("poll checks once, when the pool ran out",
      "if !poolAutoChecked, JITPoolMeter.current.exhausted > 0 {" in poll and "poolAutoChecked = true" in poll)
check("only a library entry, not the desktop",
      re.search(r"let entry = activeEntry, entry\.desktop != true, entries\.contains\(where: \{ \$0\.id == entry\.id \}\)", poll) is not None)
check("the game's windowsPath (GameProfile's key) and title",
      "JITPoolAuto.apply(windowsPath: entry.windowsPath, title: entry.title)" in poll and "poolAutoTitle = entry.title" in poll)
begin = body(lib, "    func begin(_ entry: LibraryEntry, remember: Bool = true, dock: DockGame? = nil) {")
check("begin resets the check", "poolAutoChecked = false; poolAutoTitle = nil" in begin)
fin = body(lib, "    private func finish() {")
i_run, i_pool, i_exit = fin.find("steamRunRequest()"), fin.find("JITPoolAuto.message(title)"), fin.find("exitReport()")
check("finish: Steam run request, then the pool alert, then the exit report", -1 < i_run < i_pool < i_exit)
check("finish clears the title", "poolAutoTitle = nil" in fin)

auto = body(bcd, "enum JITPoolAuto {", "\n}\n")
check("the two lines", '("pool-split", "1"), ("env.MADEIRA_X64_IMAGE_NOCOPY", "1")' in auto)
check("a key already set stays", "values[$0.key] == nil" in auto)
check("off switch", 'MadeiraConfig.flag("MADEIRA_JIT_POOL_AUTO")' in auto)
check("written through GameProfile and read back",
      "GameProfile(windowsPath: windowsPath)" in auto and "guard file.text == out" in auto)
check("logs", auto.count("[jit-pool-auto]") >= 3)
check("the alert asks to reopen Madeira", "open it again and start" in auto)

# Part 2: the same rule in Python.
def parse(text):
    out = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.strip():
            out[k.strip()] = v.strip()
    return out

LINES = [("pool-split", "1"), ("env.MADEIRA_X64_IMAGE_NOCOPY", "1")]

def added(text):
    have = parse(text)
    add = [(k, v) for k, v in LINES if k not in have]
    if not add:
        return None
    out = text
    if out and not out.endswith("\n"):
        out += "\n"
    out += "# Added by Madeira: this game ran out of JIT memory\n" + "\n".join(f"{k} = {v}" for k, v in add) + "\n"
    return out

check("empty config gets both", parse(added("")) == {"pool-split": "1", "env.MADEIRA_X64_IMAGE_NOCOPY": "1"})
check("pool-split = 0 stays 0", parse(added("pool-split = 0")) == {"pool-split": "0", "env.MADEIRA_X64_IMAGE_NOCOPY": "1"})
check("both set: nothing to do", added("pool-split = 1\nenv.MADEIRA_X64_IMAGE_NOCOPY = 0\n") is None)
check("other lines kept", parse(added("env.FEX_MULTIBLOCK = 1"))["env.FEX_MULTIBLOCK"] == "1")

check("the catalog lists the switch, on by default, from LibraryBCD.swift",
      re.search(r'key: "env\.MADEIRA_JIT_POOL_AUTO", [^\n]*kind: \.bool, defaultValue: "1"[^\n]*sources: \["app/Madeira/LibraryBCD\.swift"\]', cat) is not None
      and '"env.MADEIRA_JIT_POOL_AUTO"' in gen)

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
