#!/usr/bin/env python3
"""The JIT mapping table holds 2048 images, and a full table fails a load before it copies; no Wine runs.

StarCraft via Battle.net (device log 46ebf8e1, Wave 38) logged "[jit-pool] mapping table FULL
(512 slots)" 218 times over 191 distinct images: COMCTL32 / SETUPAPI / POWRPROF / uxtheme got pool
copies but no mapping, exec-faulted at their PE VAs, and StarCraft showed "Failed to load.". With
the table full every retry of the load also copied the image into the pool again.

Checks build/ntdll-unix/virtual_ios.c:
  - IOS_JIT_MAX_MAPPINGS is 2048 and is the only size the table, the child-ntdll full test and
    the FULL log use; every scan runs up to ios_jit_mapping_count (the highest slot used), never
    up to the macro, so lookup cost follows real use;
  - ios_jit_mapping_has_room (compiled from the source, against a model table): room when the count
    is below the limit, when a tombstone exists, or when an overlapping stale entry would be
    purged; none when full of live, disjoint entries (and it then logs the FULL line);
  - mprotect_exec asks it AFTER the stale-image probe and BEFORE any pool range is allocated or any
    byte copied, and a refusal fails the protect (copy_refused=1, PROT_READ, ENOMEM, -1);
  - ios_jit_add_mapping keeps its FULL log line and logs "[jit-map] high-water %d/%d" once per
    new 128-entry step of live entries;
  - sizeof(struct ios_jit_mapping) and the table's BSS size are printed for the record.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


def struct(source, name):
    start = source.index('struct %s {' % name)
    return source[start:source.index('\n};', start) + 3] + '\n'


# --- size ---------------------------------------------------------------------
assert re.search(r'^#define IOS_JIT_MAX_MAPPINGS 2048$', native, re.M)
assert len(re.findall(r'^#define IOS_JIT_MAX_MAPPINGS ', native, re.M)) == 1
assert 'static struct ios_jit_mapping ios_jit_mappings[IOS_JIT_MAX_MAPPINGS];' in native

# no loop runs to the macro: every scan of the table stops at the high-water count
for m in re.finditer(r'for \(\w+ = 0; \w+ < (\w+);', native):
    assert m.group(1) != 'IOS_JIT_MAX_MAPPINGS', m.group(0)
assert 'sizeof(ios_jit_mappings)' not in native.replace('memset( ios_jit_mappings', '')

# --- call sites ---------------------------------------------------------------
add = function(native, 'void ios_jit_add_mapping(void *pe_base, void *jit_base, size_t size)')
assert 'mapping table FULL (%d slots)' in add and 'bump IOS_JIT_MAX_MAPPINGS!' in add, 'FULL line kept'
assert '"[jit-map] high-water %d/%d\\n", live, IOS_JIT_MAX_MAPPINGS' in add
assert 'if (live / 128 > hw_step)' in add
assert add.index('ios_jit_mappings[slot].pe_base = pe_base;') < add.index('[jit-map] high-water')

room = function(native, 'static int ios_jit_mapping_has_room(void *pe_base, size_t size)')
assert 'mapping table FULL (%d slots)' in room

body = native[native.index('/* [jit-map] a full mapping table fails the load BEFORE any pool range'):]
body = body[:body.index('/* ml457 REVERTED')]
assert re.search(r'if \(!ios_jit_mapping_has_room\( image_base, image_size \)\)\s*\{\s*'
                 r'ios_jit_copy_refused = 1;[^\n]*\n\s*mprotect\( base, size, PROT_READ \);\s*'
                 r'errno = ENOMEM;\s*return -1;\s*\}', body), 'refusal shape'
site = native.index('if (!ios_jit_mapping_has_room( image_base, image_size ))')
assert native.index('if (!ios_image_view_readable( image_base, image_size ))', site - 3000) < site
for later in ('offset = ios_pool_alloc_range_tagged(alloc_size, jit_pool_size - ios_jit_tail_reserved, image_tag);',
              'memcpy((char *)jit_rw_base + offset, image_base, image_size);',
              'ios_jit_add_mapping(image_base, (char *)jit_rx_base + offset, image_size);'):
    assert native.index(later, site) > site, later

# --- behaviour ----------------------------------------------------------------
code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
'''
code += re.search(r'^#define IOS_JIT_MAX_MAPPINGS .*$', native, re.M).group(0) + '\n'
code += re.search(r'^#define IOS_JIT_MAX_CODE_RANGES .*$', native, re.M).group(0) + '\n'
code += struct(native, 'ios_jit_mapping')
code += r'''
static struct ios_jit_mapping ios_jit_mappings[IOS_JIT_MAX_MAPPINGS];
static int ios_jit_mapping_count = 0;
static int full_logs;
static int dprintf_model( int fd, const char *fmt, ... )
{
    (void)fd;
    if (strstr( fmt, "mapping table FULL" )) full_logs++;
    return 0;
}
#define dprintf dprintf_model
'''
code += function(native, 'static int ios_jit_mapping_has_room(void *pe_base, size_t size)')
code += r'''
int main(void)
{
    int i;
    printf( "sizeof(struct ios_jit_mapping)=%zu table=%zu bytes (%d slots)\n",
            sizeof(struct ios_jit_mapping), sizeof(ios_jit_mappings), IOS_JIT_MAX_MAPPINGS );
    assert( IOS_JIT_MAX_MAPPINGS == 2048 );

    /* empty and partly used: room */
    assert( ios_jit_mapping_has_room( (void *)0x10000000, 0x1000 ) );
    for (i = 0; i < IOS_JIT_MAX_MAPPINGS - 1; i++)
    {
        ios_jit_mappings[i].pe_base = (void *)(uintptr_t)(0x100000000ULL + (uint64_t)i * 0x100000);
        ios_jit_mappings[i].size = 0x80000;
    }
    ios_jit_mapping_count = IOS_JIT_MAX_MAPPINGS - 1;
    assert( ios_jit_mapping_has_room( (void *)0x700000000ULL, 0x1000 ) );   /* one slot left */

    /* exactly full of live, disjoint entries: no room, and the FULL line is logged */
    ios_jit_mappings[IOS_JIT_MAX_MAPPINGS - 1].pe_base = (void *)0x600000000ULL;
    ios_jit_mappings[IOS_JIT_MAX_MAPPINGS - 1].size = 0x1000;
    ios_jit_mapping_count = IOS_JIT_MAX_MAPPINGS;
    full_logs = 0;
    assert( !ios_jit_mapping_has_room( (void *)0x700000000ULL, 0x1000 ) );
    assert( full_logs == 1 );
    /* adjacency is not overlap */
    assert( !ios_jit_mapping_has_room( (void *)(0x100000000ULL + 0x80000), 0x80000 ) );

    /* a tombstone makes room */
    ios_jit_mappings[700].pe_base = NULL;
    full_logs = 0;
    assert( ios_jit_mapping_has_room( (void *)0x700000000ULL, 0x1000 ) );
    assert( full_logs == 0 );
    ios_jit_mappings[700].pe_base = (void *)(uintptr_t)(0x100000000ULL + 700ULL * 0x100000);

    /* an overlapping stale entry would be purged by add_mapping: room */
    assert( ios_jit_mapping_has_room( (void *)(0x100000000ULL + 5ULL * 0x100000 + 0x1000), 0x2000 ) );
    puts( "PASS" );
    return 0;
}
'''
tmp = tempfile.mkdtemp()
src = os.path.join(tmp, 'm.c')
exe = os.path.join(tmp, 'm')
Path(src).write_text(code)
cc = os.environ.get('CC', 'cc')
subprocess.run([cc, '-O1', '-g', '-fsanitize=address,undefined', '-Wall', '-o', exe, src], check=True)
out = subprocess.run([exe], check=True, capture_output=True, text=True).stdout
print(out, end='')
assert 'PASS' in out
