#!/usr/bin/env python3
"""Run the actual initial-CWD override and Wine UTF-8 decoder under ASan/UBSan.
Requires the pinned Wine source, not a configured Wine build or an iPad.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/env_ios.c').read_text()
locale = (root / 'wine/dlls/ntdll/locale_private.h').read_text()


def function(text, name):
    start = text.index(name)
    brace = text.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


start = source.index('    /* iOS-Madeira override:')
start = source.index('\n    {', start)
end = source.index('    /* try to get it from the Unix cwd */', start)
override = source[start:end]
helpers = '\n'.join(function(locale, name) for name in (
    'static inline unsigned int decode_utf8_char(', 'static inline NTSTATUS utf8_mbstowcs('))
prefix = r'''
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
typedef uint16_t WCHAR;
typedef int32_t NTSTATUS;
#define STATUS_SUCCESS 0
#define STATUS_BUFFER_TOO_SMALL ((NTSTATUS)0xc0000023)
#define STATUS_SOME_NOT_MAPPED ((NTSTATUS)0x00000107)
#define os_log(...) ((void)0)
static const char *input;
static int fail_allocation;
static const char *cwd_env(const char *name) { (void)name; return input; }
static void *allocate(size_t size) { return fail_allocation ? NULL : malloc(size); }
#define getenv cwd_env
#define malloc allocate
'''
program = prefix + helpers + '\nstatic WCHAR *initial(void) { WCHAR *ret = NULL;\n' + override + '\nreturn ret; }\n'
cases = ['C:\\', 'C:\\Games\\Demo', 'C:\\Games\\Demo\\',
         'C:\\TaskbarList-iPad测试', 'C:\\Café\\Résumé', 'C:\\游戏🎮\\保存',
         'C:\\e\u0301\\NFD', 'C:\\العربية\\لعبة', 'C:\\日本語\\ゲーム',
         'C:\\русский\\игра', 'C:\\हिन्दी\\खेल']
cases += ['C:\\' + '目录é🎮' * n for n in (1, 16, 64, 256)]
checks = []
for number, path in enumerate(cases):
    encoded = ''.join('\\x%02x' % byte for byte in path.encode('utf-8'))
    expected = ('\\??\\' + path + ('' if path.endswith('\\') else '\\') + '\0').encode('utf-16-le')
    units = [expected[i] | expected[i + 1] << 8 for i in range(0, len(expected), 2)]
    checks.append('''{ const WCHAR expected[] = {%s}; input = "%s"; WCHAR *actual = initial();
if (!actual || memcmp(actual, expected, sizeof(expected))) {
    fprintf(stderr, "FAIL UTF-16 path case %d\\n"); return 1; }
free(actual); }''' % (','.join(map(str, units)), encoded, number))
checks.append(r'''{
    input = NULL; if (initial()) return 1;
    input = ""; if (initial()) return 1;
    fail_allocation = 1; input = "C:\\Games";
    if (initial()) { fputs("FAIL allocation fallback\n", stderr); return 1; }
    fail_allocation = 0;
    const char *invalid[] = {"C:\\\xc0\x80", "C:\\\xe6\xb5", "C:\\\xed\xa0\x80", "C:\\\xff"};
    for (unsigned i = 0; i < sizeof(invalid)/sizeof(*invalid); i++) {
        input = invalid[i];
        if (initial()) { fputs("FAIL invalid UTF-8 fallback\n", stderr); return 1; }
    }
}''')
program += '\nint main(void) { (void)utf8_mbstowcs;\n' + '\n'.join(checks) + '\nputs("PASS initial CWD: 15 UTF-8/UTF-16 paths, unset/empty/OOM and four invalid UTF-8 fallbacks"); return 0; }\n'
with tempfile.TemporaryDirectory(prefix='madeira-initial-cwd-') as directory:
    src = Path(directory) / 'test.c'
    exe = Path(directory) / 'test'
    src.write_text(program)
    # Wine's decode_utf8_char falls through its switch on purpose; GCC's -Wextra warns on that.
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-implicit-fallthrough',
                    '-fsanitize=address,undefined', '-fno-omit-frame-pointer', str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
