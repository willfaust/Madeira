#!/usr/bin/env python3
"""x18 trampolines start on the 16 KB page after a .data-shifted image.

Log 2026-10-26 23:43 (vk-1026-m2, d3d12 = vkd3d): vkd3d-proton's d3d12.dll (image
0x24000, .data shifted +0x2000) was copied to pool 0x155f3a000 with its trampolines
at 0x155f5e000, on the image's last 16 KB page, which holds .data and is mapped
without exec. The first patched instruction faulted (BUS EXEC in JIT .data,
mprotect RX refused, insn 0xd53bd079 = mrs x25, tpidrro_el0) and the launcher
reported that the game could not start.

The offset is computed here from the loader's formulas for that image and for the
child copy, then the sources are checked to use the helper.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text().replace('\r\n', '\n')
ok = True
P = 0x4000


def check(what, cond):
    global ok
    print(('ok   ' if cond else 'FAIL ') + what)
    ok &= bool(cond)


def tramp(offset, image_alloc, delta):   # ios_jit_tramp_offset
    return offset - delta + image_alloc + P if delta else offset + image_alloc


for name, base, size, delta, prealloc in (('d3d12.dll', 0xdf38000, 0x24000, 0x2000, 0x4000),
                                           ('vulkan-1.dll', 0xd9fc000, 0x23000, 0x2000, 0x4000),
                                           ('no shift', 0x100000, 0x31000, 0, 0x8000)):
    image_alloc = (size + P - 1) & ~(P - 1)
    alloc = image_alloc + prealloc + (P if delta else 0)
    off = base + delta
    t = tramp(off, image_alloc, delta)
    last_image_page = (off + size - 1) // P
    check('%s: trampolines on a page of their own' % name, t % P == 0 and t // P > last_image_page)
    check('%s: trampolines end inside the allocation' % name, t + prealloc <= base + alloc)
    old = off + image_alloc
    if delta:
        check('%s: the old offset shared the last image page' % name, old // P == last_image_page)

check('helper and its kill switch', 'static size_t ios_jit_tramp_offset( size_t offset, size_t image_alloc, size_t data_delta )' in src
      and 'return data_delta ? offset - data_delta + image_alloc + 0x4000 : offset + image_alloc;' in src
      and 'getenv( "MADEIRA_X18_TRAMP_ALIGN" )' in src)
check('the parent copy uses it',
      '? ios_jit_tramp_offset( offset, image_alloc, data_delta ) : offset + image_alloc;' in src)
check('the child copy uses it',
      '? ios_jit_tramp_offset( offset, (m->size + pg - 1) & ~(pg - 1), ios_jit_data_align_delta( m->pe_base, m->size ) )' in src
      and ': offset + (alloc_size - child_tramp_prealloc);' in src)
check('the allocation still has the extra page whenever the image is shifted',
      'size_t alloc_size = image_alloc + tramp_prealloc + (data_delta ? page_size : 0);' in src
      and 'if (data_delta) alloc_size += pg;' in src)

sys.exit(0 if ok else 1)
