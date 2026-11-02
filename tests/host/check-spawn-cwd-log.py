#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""build/ntdll-unix/process_ios.c: the child-spawn log line names the child's Windows current directory; no Wine runs.

A title that ends on its own "asset could not be found" box raised the question which directory a Steam-launched
child starts in, and that was in no log. spawn_process's one ERR line now ends in
`cwd=%s` with debugstr_us(&params->CurrentDirectory.DosPath). Log only: the call's other arguments, the thread
creation and the return value are unchanged. This check reads the C text: the line keeps its old fields in order,
the cwd field is last, and the number of conversions equals the number of arguments (a mismatch would print garbage
or crash inside the logger, in the one code path every child process takes).
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/process_ios.c').read_text()

start = src.index('ERR("spawn_process: creating child thread for')
depth = 0
end = start
for i in range(start, len(src)):
    c = src[i]
    if c == '(':
        depth += 1
    elif c == ')':
        depth -= 1
        if depth == 0:
            end = i
            break
call = src[start:end + 1]

fmt = re.search(r'ERR\("((?:[^"\\]|\\.)*)"', call).group(1)
assert fmt == ('spawn_process: creating child thread for %s '
               '(fd=%d, unixdir=%d, dup_unixdir=%d) cwd=%s\\n'), fmt

# The arguments after the format string, split at top-level commas.
rest = call[call.index('",', call.index('ERR("')) + 2:-1]
args, depth, cur = [], 0, ''
for c in rest:
    if c in '([':
        depth += 1
    elif c in ')]':
        depth -= 1
    if c == ',' and depth == 0:
        args.append(cur.strip())
        cur = ''
    else:
        cur += c
if cur.strip():
    args.append(cur.strip())

assert len(args) == len(re.findall(r'%[sd]', fmt)) == 5, args
# The command line goes through upstream's redacting madeira_debugstr_cmdline_us (log redaction).
assert args[0] == 'madeira_debugstr_cmdline_us(&params->CommandLine)', args
assert args[1:4] == ['socketfd', 'unixdir', 'args->unixdir'], args
assert args[4] == 'debugstr_us(&params->CurrentDirectory.DosPath)', args

# Nothing else in the file may read the old text (log scanners live in tools/ and app/).
for folder in ('tools', 'app', 'tests'):
    for p in (root / folder).rglob('*'):
        if p.is_file() and p.suffix in ('.py', '.swift', '.m', '.h', '.c', '.sh'):
            try:
                text = p.read_text()
            except UnicodeDecodeError:
                continue
            # check-log-redaction.py reads the same line for its redacted command line, which the cwd field keeps.
            if p.name not in ('check-spawn-cwd-log.py', 'check-log-redaction.py') and 'creating child thread for' in text:
                raise SystemExit('%s matches the spawn line; keep its pattern in step with the new field' % p)

print('check-spawn-cwd-log: ok (spawn line ends in cwd=%s, 5 conversions, 5 arguments)')
