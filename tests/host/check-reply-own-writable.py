#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2230, from device logs 111-112 (Steam Big Picture, 2026-10-28):

- build/ntdll-unix/server_ios.c: a server reply into the JIT pool's address range goes through the pool's RW
  alias only for a page that is not writable at its own address. Log 111: a page the pool had given up held a
  child's pthread stack, rpcss.exe's first reply went to the alias of that hole (unmapped) and the process died at
  boot (env.MADEIRA_REPLY_OWN_WRITABLE=0 reverts);
- build/ntdll-unix/process_ios.c: env.MADEIRA_CEF_VERBOSE=0 drops CEF's verbose file log from the web helper's
  command line (default keeps it), with or without --jitless.

Static anchors only.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
server = (ROOT / 'build/ntdll-unix/server_ios.c').read_text(encoding='utf-8', errors='replace')
proc = (ROOT / 'build/ntdll-unix/process_ios.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(src, name, stop='\n}\n'):
    i = src.index(name)
    return src[i:src.index(stop, i)]

alias = body(server, 'static uintptr_t ios_reply_rw_alias( uintptr_t addr )')
check('if (ios_reply_own_writable() && ios_reply_host_writable( page, IOS_REPLY_PAGE )) return 0;' in alias
      and alias.index('ios_reply_host_writable( page') < alias.index('return rw + (addr - rx);'),
      'a pool-range page writable at its own address is not sent to the RW alias')
check('return ios_jit_anon_alias_lookup( addr );' in alias, 'anonymous-RWX aliases are looked up as before')
own = body(server, 'static int ios_reply_own_writable( void )')
check('getenv( "MADEIRA_REPLY_OWN_WRITABLE" )' in own and "on = !(e && e[0] == '0');" in own,
      'env.MADEIRA_REPLY_OWN_WRITABLE=0 reverts, default on')
check(server.index('static BOOL ios_reply_host_writable( uintptr_t addr, size_t size );')
      < server.index('static uintptr_t ios_reply_rw_alias( uintptr_t addr )'),
      'the writability test is declared before the alias lookup uses it')
paged = body(server, 'static BOOL ios_read_reply_paged(')
check('if ((rw = ios_reply_rw_alias( dst )))' in paged
      and 'else if (ios_reply_host_writable( dst, n )) memcpy( (void *)dst, bounce, n );' in paged,
      'a page the alias lookup declines is written at its own address when writable')

check('const char *cv = getenv( "MADEIRA_CEF_VERBOSE" );' in proc and "int verbose_on = !(cv && cv[0] == '0');" in proc,
      'env.MADEIRA_CEF_VERBOSE=0 turns the verbose CEF log off, default on')
check('static const char sp_quiet_jit[]     = " --single-process --no-proxy-server --winhttp-proxy-resolver";' in proc
      and '" --js-flags=--jitless";' in proc
      and 'const char *sp = verbose_on ? (jitless_on ? sp_jitless : sp_jit)' in proc
      and ': (jitless_on ? sp_quiet_jitless : sp_quiet_jit);' in proc,
      'the quiet command lines keep --single-process, the proxy switches and --jitless as chosen')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    for key in ('MADEIRA_REPLY_OWN_WRITABLE', 'MADEIRA_CEF_VERBOSE', 'MADEIRA_BIG_PICTURE_GPU', 'MADEIRA_BIG_PICTURE_LIBRARIES'):
        check(f'key: "env.{key}"' in text, f'the config catalog documents env.{key}')

print(f'check-reply-own-writable: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
