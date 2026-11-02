#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""The JIT-pool dump is opt-in (signal_arm64_ios.c ios_jit_dump_enabled); no Wine runs.

A mach UNHANDLED is any fault passed on to Wine's own exception path, so the
old default (dump unless MADEIRA_JIT_DUMP=0) wrote ~930 MB to Documents in
every licensed session. Compiles
ios_jit_dump_enabled and ios_jit_dump_remove_stale against a fake Documents
directory and checks:
  - unset, 0 or any other value: no dump, and a dump an earlier session left
    is removed;
  - 1: the dump is on and an existing file is kept;
and textually that ios_dump_jit_pool returns early unless enabled and that
the mach exception thread removes a stale dump when it starts.
Needs python3 and a C compiler (CC, default cc).
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
start = src.index('static int ios_jit_dump_enabled( void )')
end = src.index('static void ios_dump_jit_pool( const char *why )')
chunk = src[start:end]

harness = r'''
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
''' + chunk + r'''
int main(int argc, char **argv)
{
    char path[512];
    int fd;
    snprintf(path, sizeof path, "%s/fex-jit-dump.bin", getenv("MADEIRA_DOCS_DIR"));
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || ftruncate(fd, 3 << 20)) return 3;
    close(fd);
    printf("enabled=%d\n", ios_jit_dump_enabled());
    ios_jit_dump_remove_stale();
    printf("exists=%d\n", access(path, F_OK) == 0);
    return 0;
}
'''

cc = os.environ.get('CC') or shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
if not cc:
    print('SKIP: no C compiler (set CC); the JIT-dump checks need one')
    sys.exit(0)
with tempfile.TemporaryDirectory(prefix='madeira-jit-dump-') as directory:
    c = Path(directory) / 'j.c'
    exe = Path(directory) / 'j'
    docs = Path(directory) / 'Documents'
    docs.mkdir()
    c.write_text(harness)
    build = subprocess.run([cc, '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function',
                            '-fsanitize=address,undefined', '-o', str(exe), str(c)], capture_output=True, text=True)
    assert build.returncode == 0, build.stdout + build.stderr
    for value, enabled in ((None, 0), ('0', 0), ('yes', 0), ('1', 1)):
        env = {k: v for k, v in os.environ.items() if not k.startswith('MADEIRA_')}
        env['MADEIRA_DOCS_DIR'] = str(docs)
        if value is not None:
            env['MADEIRA_JIT_DUMP'] = value
        run = subprocess.run([str(exe)], capture_output=True, text=True, env=env)
        assert run.returncode == 0, run.stdout + run.stderr
        assert f'enabled={enabled}' in run.stdout, (value, run.stdout)
        assert f'exists={enabled}' in run.stdout, (value, run.stdout)
        if not enabled:
            assert 'removed' in run.stderr and '(3 MB) left by an earlier session' in run.stderr, run.stderr
        else:
            assert 'removed' not in run.stderr, run.stderr
    print('PASS: the JIT-pool dump is on only with MADEIRA_JIT_DUMP=1; otherwise a stale dump is removed')

dump = src[src.index('static void ios_dump_jit_pool( const char *why )\n{'):]
dump = dump[:dump.index('\n}\n')]
assert 'if (!ios_jit_dump_enabled() || !ios_jit_rw_base_global || !total) return;' in dump, 'the dump returns early unless enabled'
thread = src[src.index('static void *ios_mach_exception_thread( void *arg )\n{'):]
thread = thread[:thread.index('for (;;)')]
assert 'ios_jit_dump_remove_stale();' in thread, 'the exception thread removes a stale dump at start'
print('PASS: ios_dump_jit_pool is gated and the exception thread removes a stale dump at start')
