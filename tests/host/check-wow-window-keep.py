#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2020 (build/ntdll-unix/virtual_ios.c), from the device logs of 2026-10-25 (a 64-bit launcher
chain under the Dock with a 32-bit title's guest-window placeholder held from session start):

- a guest window or placeholder is its own process's: map_reserved_area_inner skips it for a
  request that is not constrained to the caller's window, map_fixed_area refuses a fixed map
  into it from another process (MADEIRA_WOW_WINDOW_KEEP=0 reverts);
- the window's overrun guard is its own top host page, so the gap above a window stays 4 GB-
  aligned; the guest ceiling stops one host page short of 4 GB (MADEIRA_WOW_GUARD_INSIDE=0 reverts);
- a hinted reservation at a 4 GB boundary for up to 4 GB walks the 4 GB-aligned bases of the top
  band before a kernel pick, and map_view leaves the first aligned gigabyte above the windows to
  such an ask (MADEIRA_JUMBO_ALIGNED=0 reverts);
- a 32-bit image's executable range that runs past the image view only within the view's last
  host page is still the image's (ios_guest_image_is_host_data, the nearest-image test).

Static anchors only.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(name, stop='\n}\n'):
    i = src.index(name)
    return src[i:src.index(stop, i)]

for key, note in (('MADEIRA_WOW_WINDOW_KEEP', '0: other programs'),
                  ('MADEIRA_WOW_GUARD_INSIDE', '0: a 32-bit guest window reserves 4 GB plus a guard page'),
                  ('MADEIRA_JUMBO_ALIGNED', '0: a hinted reservation at a 4 GB boundary')):
    check(re.search(r'getenv\( "%s" \);\s*/\* %s' % (key, re.escape(note)), src) is not None
          and ("getenv( \"%s\" )" % key) in src and src.count('"%s"' % key) == 1,
          f'{key} is read once with the note the config catalog takes, default on')

cov = body('static ULONG_PTR ios_wow_window_covering(')
check('ios_wow_slot_reservation( &ios_wow_windows[i] )' in cov and 'ios_wow_placeholders[i].guard_owned' in cov,
      'the covering test walks live windows and placeholders with their guard pages')
op = body('static int ios_wow_reserved_area_open(')
check('return lo >= wb && hi > lo && hi <= wb + IOS_WOW_WINDOW_SIZE + ios_wow_guard_size();' in op
      and 'ios_wow_limits_in_window(' not in op,
      "a reserved area that is a window is open only to a request confined to that window (containment, "
      "not the strict limits test: map_view's end is exclusive and the boot PEB asks for the whole window)")
# ml2220 (device logs 108-110): adjacent windows' reserved areas merge, so the window holding the request
# decides, not the first window in the area (env.MADEIRA_WOW_AREA_BY_REQUEST=0 reverts).
check('ULONG_PTR own = ios_wow_window_covering( (void *)lo, (void *)(lo + 1) );' in op
      and 'if (own && own < (ULONG_PTR)end && own + IOS_WOW_WINDOW_SIZE > (ULONG_PTR)start) wb = own;' in op
      and 'if (ios_wow_area_by_request() && hi > lo)' in op,
      'a merged reserved area is judged by the window that holds the request')
check('getenv( "MADEIRA_WOW_AREA_BY_REQUEST" )' in body('static int ios_wow_area_by_request('),
      'env.MADEIRA_WOW_AREA_BY_REQUEST=0 judges by the first window in the area, as before')
inner = src[src.index('static void *map_reserved_area_inner('):src.index('static NTSTATUS map_fixed_area(')]
check(inner.count('if (!ios_wow_reserved_area_open( start, end, limit_low, limit_high )) continue;') == 2,
      'both scan directions of map_reserved_area_inner skip a window that is not the caller\'s')
fixed = src[src.index('static NTSTATUS map_fixed_area('):src.index('static NTSTATUS map_fixed_area(') + 1500]
check('if (ios_wow_fixed_map_refused( start, end )) return STATUS_CONFLICTING_ADDRESSES;' in fixed,
      'map_fixed_area refuses a fixed map into another process\'s window or placeholder')
ref = body('static int ios_wow_fixed_map_refused(')
check('wb == ios_wow_base()' in ref and 'MADEIRA_WOW_WINDOW_KEEP=0 reverts' in ref,
      'the refusal names the window and the switch, and lets the owning process through')

wt = body('static int ios_wow_window_try( ULONG_PTR base, unsigned *guard_owned )')
check('if (ios_wow_guard_inside())' in wt
      and 'anon_mmap_tryfixed( (void *)base, IOS_WOW_WINDOW_SIZE, PROT_NONE, MAP_NORESERVE )' in wt
      and 'mmap_add_reserved_area( (void *)base, IOS_WOW_WINDOW_SIZE );' in wt
      and wt.index('if (ios_wow_guard_inside())') < wt.index('/* preferred: the 4 GB window plus our own guard page */'),
      'with the guard inside, the window reserves exactly 4 GB (guard_owned stays 0) before the old guard-page paths')
ceil = body('static ULONG_PTR ios_wow_ceiling_for_charact(')
check('if (laa && ios_wow_guard_inside()) return limit_4g - ios_wow_guard_size() - 1;' in ceil,
      'the 4 GB guest ceiling stops one host page short so no guest view reaches the guard')

jw = src[src.index('/* Madeira ml2020: a hint at a 4 GB boundary for up to 4 GB'):]
jw = jw[:jw.index('sc_decided:')]
check("!((ULONG_PTR)hint & 0xffffffffULL) && *size_ptr <= 0x100000000ULL" in jw
      and 'for (a = 0x7b00000000ULL; a >= 0x7000000000ULL && st2; a -= 0x100000000ULL, tries++)' in jw
      and 'st2 = allocate_virtual_memory( &pick, &csz, type, protect, 0, 0, 0, 0 );' in jw
      and jw.index('ios_jumbo_aligned_enabled()') < jw.index('pick = NULL;'),
      'a 4 GB-aligned hint walks the aligned bases of the top band before the kernel pick')
hi = src[src.index('void *hs = wow_hi_start;'):src.index('void *hs = wow_hi_start;') + 900]
check("hs = (char *)hs + 0x40000000ULL;" in hi and 'if (!ptr && hs != wow_hi_start)' in hi,
      'map_view leaves the first aligned gigabyte above the windows and falls back to it when the rest is full')

img = body('static int ios_guest_image_is_host_data( const void *base, size_t size )')
check('if (!(view = find_view( base, 0 ))) return 0;' in img
      and 'ROUND_SIZE( view->base, view->size, host_page_mask )' in img
      and 'return (view->protect & SEC_IMAGE) != 0;' in img,
      "a range past an image view only within its last host page is still the image's (host data)")
check("(uintptr_t)base + size > (uintptr_t)image_base + ROUND_SIZE( image_base, image_size, host_page_mask )" in src,
      'the nearest-image test rounds the image end to the host page too')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    for key in ('MADEIRA_WOW_WINDOW_KEEP', 'MADEIRA_WOW_GUARD_INSIDE', 'MADEIRA_JUMBO_ALIGNED', 'MADEIRA_WOW_AREA_BY_REQUEST'):
        check(f'key: "env.{key}"' in text, f'the config catalog documents env.{key}')

print(f'check-wow-window-keep: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
