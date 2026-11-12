#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""env.MADEIRA_KILL_REAP = 1: a process ended by another one releases what it held, as an exit does (process_ios.c NtTerminateProcess).

On iOS a process ended by another one's NtTerminateProcess never runs process_exit_wrapper, so its FEX code buffers, guest
window, fd cache and child-table slot stay allocated for the session. With the switch, once the server accepts the kill the
caller runs the storm guard's teardown (server_ios.c ios_end_child_process_async, which claims a live child's socket with a
compare-and-swap, so a racing exit is torn down once).

Checks:
  1. the switch, compiled and run per value: only "1" turns it on; it is read at each call;
  2. NtTerminateProcess asks for the target's PEB only with the switch and another process's handle, before the server
     request; it runs the teardown through ios_end_child_process_async only after a successful request for another process
     (not the caller's own PEB, never the fixed-base image's owner) and logs [kill-reap] only when it started;
  3. the catalog documents the key (off by default) and the session end clears it.
Not covered: process_ios.c does not build on a host; the teardown itself is the storm guard's.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/process_ios.c").read_text()
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
ok = True


def check(what, cond, detail=""):
    global ok
    print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)[:1500]) if detail and not cond else ""))
    ok = ok and bool(cond)


def cut(text, start, end="\n}\n"):
    at = text.index(start)
    return text[at:text.index(end, at) + len(end)]


# 1. the switch
switch = cut(src, "static int ios_kill_reap_enabled(void)")
if cc:
    with tempfile.TemporaryDirectory() as tmp:
        c, exe = Path(tmp) / "k.c", Path(tmp) / "k"
        c.write_text("#include <stdio.h>\n#include <stdlib.h>\n" + switch +
                     "int main( void ) { printf( \"%d\", ios_kill_reap_enabled() ); return 0; }\n")
        r = subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-o", str(exe), str(c)], capture_output=True, text=True)
        check("the switch compiles (-Wall -Wextra -Werror)", r.returncode == 0, r.stderr)
        if r.returncode == 0:
            got = {}
            for v in (None, "", "0", "1", "11", "yes"):
                env = {k: x for k, x in os.environ.items() if k != "MADEIRA_KILL_REAP"}
                if v is not None:
                    env["MADEIRA_KILL_REAP"] = v
                got[v] = subprocess.run([str(exe)], capture_output=True, text=True, env=env).stdout
            check("only '1' turns it on", got == {None: "0", "": "0", "0": "0", "1": "1", "11": "0", "yes": "0"}, got)
else:
    check("a C compiler for the host test", False)
check("the switch is read at each call (no cached value)", "static int cached" not in switch and "getenv( \"MADEIRA_KILL_REAP\" )" in switch)

# 2. NtTerminateProcess
fn = cut(src, "NTSTATUS WINAPI NtTerminateProcess( HANDLE handle, LONG exit_code )")
ask = "if (handle && handle != NtCurrentProcess() && ios_kill_reap_enabled())"
query = "if (!NtQueryInformationProcess( handle, ProcessBasicInformation, &pbi, sizeof(pbi), NULL )) reap_peb = pbi.PebBaseAddress;"
req = "SERVER_START_REQ( terminate_process )"
after = "if (reap_peb && !ret && !self && reap_peb != NtCurrentTeb()->Peb)"
reap = "if (!ios_exe_win_owned_by( reap_peb ) && ios_end_child_process_async( reap_peb, (int)exit_code ))"
check("the PEB is asked for only with the switch and another process's handle, before the server request",
      fn.count(ask) == 1 and fn.count(query) == 1 and fn.index(ask) < fn.index(query) < fn.index(req))
check("the teardown runs after a successful request for another process, never for the fixed-base image's owner",
      fn.count(after) == 1 and fn.count(reap) == 1 and fn.index(req) < fn.index("SERVER_END_REQ;") < fn.index(after) < fn.index(reap)
      < fn.index("    if (self)\n"))
check("[kill-reap] is logged only when the teardown started", re.search(re.escape(reap) + r"\n\s+dprintf\( 2, \"\[kill-reap\]", fn) is not None)

# 3. settings
gen = (root / "build/tools/gen-config-catalog.py").read_text()
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
bridge = (root / "app/Madeira/WineProcessBridge.m").read_text()
check("the catalog documents the key, off by default; the session end clears it",
      re.search(r'"env\.MADEIRA_KILL_REAP": \{[^}]*"default": "0"', gen, re.S) is not None and 'key: "env.MADEIRA_KILL_REAP"' in cat
      and 'unsetenv("MADEIRA_KILL_REAP");' in bridge)
print("PASS: kill-reap" if ok else "FAILED: kill-reap")
sys.exit(0 if ok else 1)
