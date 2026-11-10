#!/usr/bin/env python3
"""[x64-data-imp]: the data imports of an x64 image without a pool copy.

ios_x64_iat_bind_live_data (ml1244/ml1245) points a pure x64 importer's IAT
slots for DATA exports of ARM64EC modules at the copy that is live, the pool
copy. An image mapped with MADEIRA_X64_IMAGE_NOCOPY (VPROT_X64DATA) has no
ios_jit_mappings[] entry; a small table of such views lets the binder find it.

Checks, without a Wine run:
  - the table's functions, compiled under ASan/UBSan with the production
    source: a noted image is found for a range inside it and not for one that
    crosses its end; a forgotten one is not found and its slot is reused; a
    full table logs once and notes nothing more;
  - the switch: on unless env.MADEIRA_X64_NOCOPY_DATAIMP is exactly "0";
  - map_image_into_view notes the view right where it marks VPROT_X64DATA,
    delete_view forgets a VPROT_X64DATA view, and the binder looks the range
    up only when no ios_jit_mappings[] entry holds it, then reads the
    importer's headers within the noted size;
  - the catalog overlay documents the key.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8')
catalog = (root / 'build/tools/gen-config-catalog.py').read_text(encoding='utf-8')
CC = os.environ.get('CC') or shutil.which('cc') or shutil.which('clang')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def function(source, signature, start=0):
    begin = source.index(signature, start)
    return source[begin:source.index('\n}\n', begin) + 3]


# ------------------------------------------------------------------ static rules
mapper = function(native, 'static NTSTATUS map_image_into_view(')
mark = mapper.index('view->protect |= VPROT_X64DATA;')
require(mapper.count('view->protect |= VPROT_X64DATA;') == 1 and native.count('|= VPROT_X64DATA') == 1,
        'one place marks a view VPROT_X64DATA')
require(mapper[mark:mark + 200].split('\n')[1].strip() ==
        'if (ios_x64_nocopy_dataimp_enabled()) ios_x64_nocopy_note( (uintptr_t)ptr, total_size );   /* [x64-data-imp] */'
        and 'char *ptr = view->base;' in mapper,
        'the mark notes the view (ptr is view->base) right after setting the flag')

deleter = function(native, 'static void delete_view(')
require('if ((view->protect & VPROT_X64DATA) && ios_x64_nocopy_dataimp_enabled())\n'
        '        ios_x64_nocopy_forget( (uintptr_t)view->base );' in deleter and
        deleter.index('ios_x64_nocopy_forget') < deleter.index('unmap_area( view->base, view->size );'),
        'delete_view forgets a VPROT_X64DATA view before its pages go')

binder = function(native, 'static void ios_x64_iat_bind_live_data(')
lookup = binder.index('else if (ios_x64_nocopy_dataimp_enabled() && ios_x64_nocopy_find( rs, re, &pe, &pe_size )) nocopy = 1;')
require(binder.index('if (imp >= 0)') < lookup < binder.index('else return;') and
        binder.index('ios_jit_mapping_is_hybrid( imp )) return;') < lookup,
        'the binder keeps ml1245\'s rule for pool-copied importers and looks a range up only when no mapping holds it')
require('(size_t)lfanew + sizeof(nt) > pe_size' in binder and 'ios_jit_mappings[imp].size' in binder and
        binder.count('ios_jit_mappings[imp]') == 2,
        'the importer\'s headers are read within the size of whichever entry holds it')
require('nocopy ? " (no pool copy)" : ""' in binder, 'the per-window log line says when the importer has no pool copy')
require(native.index('static int ios_x64_nocopy_find(') < native.index('static void ios_x64_iat_bind_live_data('),
        'the table is defined before the binder')
require('"env.MADEIRA_X64_NOCOPY_DATAIMP"' in catalog, 'the catalog overlay documents env.MADEIRA_X64_NOCOPY_DATAIMP')

# ------------------------------------------------------------------ compiled table
table = native[native.index('#define IOS_X64_NOCOPY_MAX'):native.index('/* ml1244: bind an x64 importer')]
prog = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int logged;
#define dprintf(fd, ...) (logged++, fprintf(stderr, __VA_ARGS__))
''' + table + r'''
int main(int argc, char **argv)
{
    uintptr_t pe = 0;
    size_t size = 0;
    int bad = 0, i;
    (void)argv;
#define T(cond, label) do { if (!(cond)) { printf("FAIL %s\n", label); bad = 1; } } while (0)
    if (argc > 1)   /* the switch: one answer per process (it is cached) */
    {
        printf("%d\n", ios_x64_nocopy_dataimp_enabled());
        return 0;
    }
    ios_x64_nocopy_note( 0x114030000u, 0x1a000u );     /* FarCry4.exe, 2026-11-09 */
    ios_x64_nocopy_note( 0x70e8db0000u, 0x5a00000u );  /* FC64.dll */
    T(ios_x64_nocopy_find( 0x114037000u, 0x114038000u, &pe, &size ) && pe == 0x114030000u && size == 0x1a000u,
      "a range inside the exe finds it");
    T(ios_x64_nocopy_find( 0x114030000u, 0x11404a000u, &pe, &size ) && pe == 0x114030000u, "the whole image");
    T(!ios_x64_nocopy_find( 0x114049000u, 0x11404b000u, &pe, &size ), "a range past its end");
    T(!ios_x64_nocopy_find( 0x11402f000u, 0x114031000u, &pe, &size ), "a range starting below it");
    T(ios_x64_nocopy_find( 0x70e8db1000u, 0x70e8db2000u, &pe, &size ) && pe == 0x70e8db0000u, "the second image");
    ios_x64_nocopy_forget( 0x114030000u );
    T(!ios_x64_nocopy_find( 0x114037000u, 0x114038000u, &pe, &size ), "forgotten");
    T(ios_x64_nocopy_find( 0x70e8db1000u, 0x70e8db2000u, &pe, &size ), "the other image stays");
    ios_x64_nocopy_note( 0x200000000u, 0x10000u );
    T(ios_x64_nocopy_tab[0].base == 0x200000000u, "a forgotten slot is reused");
    for (i = 0; i < IOS_X64_NOCOPY_MAX + 4; i++) ios_x64_nocopy_note( 0x300000000u + (uintptr_t)i * 0x100000u, 0x10000u );
    T(logged == 1, "a full table logs once");
    T(ios_x64_nocopy_find( 0x300000000u, 0x300001000u, &pe, &size ), "images noted before it filled are found");
    T(!ios_x64_nocopy_find( 0x300000000u + (uintptr_t)(IOS_X64_NOCOPY_MAX + 3) * 0x100000u,
                            0x300001000u + (uintptr_t)(IOS_X64_NOCOPY_MAX + 3) * 0x100000u, &pe, &size ),
      "an image past a full table is not");
    if (!bad) printf("ok\n");
    return bad;
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-x64-dataimp-') as tmp:
    tmp = Path(tmp)
    (tmp / 't.c').write_text(prog, encoding='utf-8')
    exe = tmp / 't'
    cc = subprocess.run([CC, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function',
                         '-fsanitize=address,undefined', '-o', str(exe), str(tmp / 't.c')])
    require(cc.returncode == 0, 'the table compiles with the production source')
    if cc.returncode == 0:
        run = subprocess.run([str(exe)], capture_output=True, text=True, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))
        require(run.returncode == 0 and run.stdout.strip() == 'ok', 'note, find, forget and a full table ' + run.stdout.strip())
        answers = {}
        for value in ('0', '1', '', '00', 'off', None):
            env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')
            env.pop('MADEIRA_X64_NOCOPY_DATAIMP', None)
            if value is not None:
                env['MADEIRA_X64_NOCOPY_DATAIMP'] = value
            answers[value] = subprocess.run([str(exe), 'switch'], capture_output=True, text=True, env=env).stdout.strip()
        require(answers == {'0': '0', '1': '1', '': '1', '00': '1', 'off': '1', None: '1'},
                'on unless env.MADEIRA_X64_NOCOPY_DATAIMP is exactly "0" (%s)' % answers)

if failures:
    print('FAILURES: %d' % failures)
    sys.exit(1)
print('PASS: all x64 no-copy data import checks')
