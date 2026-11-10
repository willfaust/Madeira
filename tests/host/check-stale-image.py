#!/usr/bin/env python3
"""[stale-image] Reads of a PE view that was just unmapped no longer fault (Nov 2026).

StarCraft from Battle.net froze at "Launching": a thread inside mprotect_exec's
image copy path read the export directory (ios_pe_module_name) of the view its
own NtUnmapViewOfSection had just removed. The plain load faulted, and the Mach
exception thread then waited for virtual_mutex for good.

Source checks: ios_pe_module_name reads through ios_safe_read (mach_vm_read_overwrite,
which returns an error instead of faulting) and copies the name out of the view; the
two image copy paths (mprotect_exec, ios_jit_copy_module_for_child) probe the first
and last byte of the source before taking a pool range, mprotect_exec again right
before the memcpy; the log is capped at 8 lines; env.MADEIRA_SAFE_IMAGE_READ = 0
turns every guard off.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text()

# The switch: default on, 0 turns it off.
assert 'static int ios_safe_image_read_enabled( void )' in src
assert 'getenv( "MADEIRA_SAFE_IMAGE_READ" )' in src
assert 'cached = !(e && e[0] == \'0\');' in src

# The probe reads the first and the last byte through the non-faulting helper.
m = re.search(r'static int ios_image_view_readable\( const void \*base, size_t size \)\n\{.*?\n\}\n', src, re.S)
assert m, 'ios_image_view_readable missing'
body = m.group(0)
assert 'if (!ios_safe_image_read_enabled()) return 1;' in body
assert 'ios_safe_read( (uintptr_t)base, &c, 1 )' in body
assert 'ios_safe_read( (uintptr_t)base + size - 1, &c, 1 )' in body

# ios_pe_module_name: the safe branch comes first and uses no plain load of the view.
m = re.search(r'const char \*ios_pe_module_name\( const void \*image_base, size_t image_size \)\n\{.*?\n\}\n', src, re.S)
assert m, 'ios_pe_module_name missing'
body = m.group(0)
safe = body[body.index('if (ios_safe_image_read_enabled())'):body.index('if (!b || image_size < 0x100) return "?";\n    if (b[0]')]
for off in ('(uintptr_t)b, sig, 2', '(uintptr_t)b + 0x3c, &lfanew, 4', '(uintptr_t)b + lfanew + 0x88, &exp_rva, 4',
            '(uintptr_t)b + exp_rva + 0x0c, &name_rva, 4', '(uintptr_t)b + name_rva, nm, cap'):
    assert 'ios_safe_read( ' + off in safe, off
assert 'b[' not in safe and '*(const' not in safe, 'a plain load of the view is left in the safe branch'
assert 'memcpy( out, nm, i + 1 );' in safe, 'the name must be copied out of the view'

# The copy paths probe before they allocate, mprotect_exec once more before the memcpy.
assert src.count('ios_stale_image_log( "mprotect_exec", image_base, image_size );') == 1
assert src.count('ios_stale_image_log( "mprotect_exec (before the copy)", image_base, image_size );') == 1
assert src.count('ios_stale_image_log( "ios_jit_copy_module_for_child", m->pe_base, m->size );') == 1
a = src.index('ios_stale_image_log( "mprotect_exec", image_base, image_size );')
b = src.index('size_t image_alloc = (image_size + page_size - 1)')
assert a < b, 'the first probe must come before the pool allocation and the scans'
c = src.index('ios_stale_image_log( "mprotect_exec (before the copy)", image_base, image_size );')
d = src.index('memcpy((char *)jit_rw_base + offset, image_base, image_size);')
assert c < d and d - c < 1200, 'the second probe must sit right before the memcpy'
e = src.index('ios_stale_image_log( "ios_jit_copy_module_for_child", m->pe_base, m->size );')
f = src.index('offset = ios_pool_alloc_range_tagged(alloc_size, ios_jit_pool_size_global - ios_jit_tail_reserved,')
assert e < f, 'the child copy probes before it takes a pool range'

# Log: capped at 8, one marker text.
assert 'if (__atomic_fetch_add( &logged, 1, __ATOMIC_RELAXED ) >= 8) return;' in src
assert '[stale-image] #%d %s: the view %p+0x%lx can no longer be read' in src

print('check-stale-image: ok')
