#!/usr/bin/env python3
"""Execute production diagnostic gates with host stubs; no Wine, GPU or device.

--revision REV is a negative control against older D3D12 source.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--revision')
args = parser.parse_args()

def read(path):
    if args.revision:
        return subprocess.check_output(['git', 'show', f'{args.revision}:{path}'], cwd=root, text=True)
    return (root / path).read_text()

def function(src, signature):
    start = src.index(signature)
    return src[start:src.index('\n}', start) + 2]

d3d = read('madeira-d3d12/src/pe/madeira_d3d12.c')
win = read('app/Madeira/Winios/Winios.m')
init = function(d3d, 'static void mad_quiet_log_init(void)')
conv = function(d3d, 'static int mad_conv_log_ok(void)')
census = re.search(r'g_census_on = !g_quiet_log[^;]+;', d3d).group() + '\n' + re.search(r'if \(g_capture_on\) g_census_on = 1;', d3d).group()
log = function(d3d, 'static void d3d12_log(const char *fmt, ...)')
# The real logger still formats and emits every line; stub only external APIs.
harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdatomic.h>
#define __cdecl
#define LONG long
#define InterlockedIncrement(p) (++*(p))
typedef void *HMODULE;
static int debug_strings, wine_lines;
static int wine_output(const char *s) { (void)s; wine_lines++; return 0; }
static HMODULE GetModuleHandleA(const char *s) { (void)s; return (void *)1; }
static void *GetProcAddress(HMODULE m, const char *s) { (void)m; (void)s; return (void *)wine_output; }
static void OutputDebugStringA(const char *s) { (void)s; debug_strings++; }
static int g_quiet_log, config = -1, g_census_on, g_capture_on;
static long long mad_cfg_int_pe(const char *key, long long fallback) { (void)key; return config < 0 ? fallback : config; }
''' + log + '\n' + init + '\n' + conv + r'''
struct swap { unsigned presents; };
static void present(struct swap *s) {
''' + census + r'''
}
int main(int argc, char **argv) {
    struct swap state = {0}; unsigned auto_frames = 0, conversions = 0;
    if (argc > 1) config = atoi(argv[1]);
    mad_quiet_log_init();
    debug_strings = wine_lines = 0;
    d3d12_log("retained error line");
    for (state.presents = 0; state.presents < 3000; state.presents++) {
        present(&state); auto_frames += !!g_census_on;
    }
    g_capture_on = 1; present(&state);
    for (int n = 0; n < 2000; n++) conversions += mad_conv_log_ok();
    printf("quiet=%d auto_census=%u debug_strings=%d wine_lines=%d manual=%d conversions=%u\n",
           g_quiet_log, auto_frames, debug_strings, wine_lines, g_census_on, conversions);
    int quiet = config != 0;
    return !(g_quiet_log == quiet && auto_frames == (quiet ? 0 : 7) &&
             debug_strings == !quiet && wine_lines == 1 && g_census_on && conversions == (quiet ? 66 : 2000));
}
'''

base = Path.home() / 'tmp'
base.mkdir(mode=0o700, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='pi-gameplay-native.', dir=base) as tmp:
    env = dict(os.environ, TMPDIR=tmp, TMP=tmp, TEMP=tmp)
    src, exe = Path(tmp) / 'gates.c', Path(tmp) / 'gates'
    src.write_text(harness)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Werror', str(src), '-o', str(exe)], env=env, check=True)
    for flags in [[], ['0'], ['1']]:
        subprocess.run([str(exe)] + flags, env=env, check=True)

    helper = function(win, 'static int winios_desktop_diagnostics_enabled(void)')
    src.write_text('#include <stdlib.h>\n#include <string.h>\n#include <stdatomic.h>\n#include <stdio.h>\n' + helper + r'''
int main(int argc, char **argv) {
    (void)argc;
    int first = winios_desktop_diagnostics_enabled();
    setenv("MADEIRA_DESKTOP_DIAG", first ? "0" : "1", 1);
    if (first != atoi(argv[1]) || winios_desktop_diagnostics_enabled() != first) return 1;
    printf("desktop diagnostics=%d (cached for this process)\n", first);
    return 0;
}
''')
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Werror', str(src), '-o', str(exe)], env=env, check=True)
    clean = {k: v for k, v in env.items() if k != 'MADEIRA_DESKTOP_DIAG'}
    for value, expected in [(None, 0), ('', 0), ('0', 0), ('1', 1)]:
        run_env = dict(clean, **({'MADEIRA_DESKTOP_DIAG': value} if value is not None else {}))
        subprocess.run([str(exe), str(expected)], env=run_env, check=True)

assert 'if (desk && winios_desktop_diagnostics_enabled())' in win
assert 'if (!stack_timer && winios_desktop_diagnostics_enabled())' in win
assert 'return winios_drain_input();' in win
print('PASS: native diagnostic defaults, opt-ins, retained logs and manual capture')
