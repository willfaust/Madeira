#!/usr/bin/env python3
"""A library game's own lines ($MADEIRA_CFG_GAME) win over madeira.cfg.

Compiles the production build/madeira_cfg.h into a small reader and checks, on a
POSIX host:
  - a key set in the game's file wins over madeira.cfg (and over the legacy
    madeira-<key>.txt files when madeira.cfg is absent);
  - keys the game's file does not set still come from madeira.cfg;
  - the last line of the game's file wins, a UTF-8 byte-order mark is ignored;
  - an unset, empty or missing MADEIRA_CFG_GAME changes nothing.
It also checks the source order the rule depends on: WineProcessBridge.m exports
the game's env.NAME lines after madeira.cfg's and before the fastsync default,
the app writes the file for every library launch, and the DXMT options are
joined with ";" (DXMT splits DXMT_CONFIG on ";" only).

No Wine, SDK, device or credentials are needed. Run with python3.
"""
import os, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8").replace("\r\n", "\n")


def check(ok, what, detail=None):
    if not ok:
        raise SystemExit("FAIL: " + what + ("\n" + repr(detail) if detail is not None else ""))
    print("ok:", what)


harness_c = r'''
#include <stdio.h>
#include "madeira_cfg.h"
int main(int argc, char **argv)
{
    int i;
    for (i = 1; i < argc; i++) {
        char v[256];
        int found = madeira_cfg_get(argv[i], v, sizeof v);
        printf("%s=%s\n", argv[i], found ? v : "<unset>");
    }
    printf("sync=%d\n", madeira_cfg_sync_engine());
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix="madeira-cfg-game-") as tmp:
    tmp = Path(tmp)
    (tmp / "c.c").write_text(harness_c, encoding="utf-8")
    subprocess.run([CC, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                    "-I", str(ROOT / "build"), str(tmp / "c.c"), "-o", str(tmp / "c")], check=True)

    def run(docs, game=None, keys=("swap-mb", "fence-chain", "pool", "inproc-sync")):
        env = {k: v for k, v in os.environ.items() if k not in ("MADEIRA_CFG_GAME", "CFFIXED_USER_HOME")}
        env["MADEIRA_DOCS_DIR"] = str(docs)
        if game is not None:
            env["MADEIRA_CFG_GAME"] = str(game)
        out = subprocess.run([str(tmp / "c")] + list(keys), check=True, capture_output=True, text=True, env=env).stdout
        return dict(line.split("=", 1) for line in out.split())

    docs = tmp / "Documents"
    docs.mkdir()
    (docs / "madeira.cfg").write_text("swap-mb = 2048\nfence-chain = 1\npool = 896\n", encoding="utf-8")
    game = tmp / "madeira-game.cfg"

    r = run(docs)
    check(r["swap-mb"] == "2048" and r["fence-chain"] == "1", "no game file: madeira.cfg values", r)
    r = run(docs, game="")
    check(r["fence-chain"] == "1", "empty MADEIRA_CFG_GAME: madeira.cfg values", r)
    r = run(docs, game=tmp / "missing.cfg")
    check(r["fence-chain"] == "1" and r["pool"] == "896", "missing game file: madeira.cfg values", r)

    game.write_text("# this game\nfence-chain = 5\nfence-chain = 6\nenv.FEX_MULTIBLOCK = 1\n", encoding="utf-8")
    r = run(docs, game=game)
    check(r["fence-chain"] == "6", "game file wins, its last line wins", r)
    check(r["swap-mb"] == "2048" and r["pool"] == "896", "keys the game does not set come from madeira.cfg", r)
    check(r["inproc-sync"] == "<unset>" and r["sync"] == "1", "unset in both stays unset (fastsync default)", r)

    game.write_bytes(b"\xef\xbb\xbfinproc-sync = 1\r\n")
    r = run(docs, game=game)
    check(r["inproc-sync"] == "1" and r["sync"] == "0", "BOM + CRLF game file: first key found, sync engine follows", r)

    game.write_text("swap-mb =\n", encoding="utf-8")
    r = run(docs, game=game)
    check(r["swap-mb"] == "", "an empty value in the game file is set (empty), as in madeira.cfg", r)

    legacy = tmp / "Legacy"
    legacy.mkdir()
    (legacy / "madeira-pool.txt").write_text("512\n", encoding="utf-8")
    r = run(legacy)
    check(r["pool"] == "512", "no madeira.cfg: legacy file", r)
    game.write_text("pool = 384\n", encoding="utf-8")
    r = run(legacy, game=game)
    check(r["pool"] == "384", "no madeira.cfg: game file wins over the legacy file", r)

bridge = read("app/Madeira/WineProcessBridge.m")
i_cfg = bridge.index('fprintf(stderr, "[madeira-env] ml1062 %s=%s\\n"')
i_game = bridge.index('fprintf(stderr, "[madeira-env] game %s=%s\\n"')
i_fast = bridge.index("madeira_cfg_sync_engine() == MADEIRA_SYNC_FASTSYNC && !getenv(\"MADEIRA_FASTSYNC\")")
check(i_cfg < i_game < i_fast, "bridge: game env lines after madeira.cfg's, before the fastsync default")

lib = read("app/Madeira/Library.swift")
apply_env = lib[lib.index("func applyEnvironment()"):lib.index("func configureLaunch()")]
check("MadeiraConfig.applyGame(config)" in apply_env, "every library launch writes (or clears) the game's lines")
cfg = read("app/Madeira/MadeiraConfig.swift")
check('unsetenv("MADEIRA_CFG_GAME")' in cfg and 'setenv("MADEIRA_CFG_GAME", u.path, 1)' in cfg,
      "MadeiraConfig.applyGame unsets before it sets")
cv = read("app/Madeira/ContentView.swift")
check('setenv("DXMT_CONFIG", dxmtOptions.joined(separator: ";"), 1)' in cv
      and 'MadeiraConfig.gameValue("dxmt")' in cv
      and 'replacingOccurrences(of: ";", with: "\\n")' not in cv,
      "DXMT options from madeira.cfg and the game joined with \";\"")

print("PASS: a library game's own lines win over madeira.cfg")
