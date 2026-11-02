#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2021 donor pool: no permanent region windows, and the overlay's view of the tier
(build/ntdll-unix/virtual_ios.c, app/Madeira/Library.swift).

The first port mapped every donated region VM_FLAGS_ANYWHERE when the app registered it, before
Wine held the 32-bit guest-window placeholder; on device the windows took the only free 4 GB-aligned
slot and 32-bit programs failed at 'guest-window-reserve'. Static anchors only: registration maps a
window only behind MADEIRA_DONOR_WINDOWS=1, a give maps the freed range for its zeroing and unmaps it,
the stats function the overlay reads exists on both sides of the bridge, and the field is offered.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8', errors='replace')
swift = (ROOT / 'app/Madeira/Library.swift').read_text(encoding='utf-8', errors='replace')
bridge = (ROOT / 'app/Madeira/Madeira-Bridging-Header.h').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

add = src[src.index('int madeira_donor_pool_add( unsigned int entry, unsigned long long size )'):src.index('void madeira_donor_pool_set_pressure(')]
check(re.search(r'getenv\( "MADEIRA_DONOR_WINDOWS" \);\s*/\* 1: a permanent ANYWHERE window per region', add) is not None
      and "int permanent = windows && windows[0] == '1';" in add,
      'the permanent windows are opt-in (MADEIRA_DONOR_WINDOWS=1), with the note the config catalog takes')
check('if (permanent && mach_vm_map( mach_task_self(), &window, size, 0, VM_FLAGS_ANYWHERE, entry' in add,
      'registration maps a region window only when they are opted in')
check('ios_donor_reg[n].window = permanent ? (char *)window : NULL;' in add,
      'without them the region keeps no window (NULL)')
check(add.count('VM_FLAGS_ANYWHERE') == 1, 'no other ANYWHERE mapping at registration')

give = src[src.index('static void ios_donor_give( uint64_t off, size_t len )'):src.index('/* bytes of the pool not handed out')]
check('if (ios_donor_reg[r].window) madvise( ios_donor_reg[r].window + off % ios_donor_region, len, MADV_ZERO );' in give,
      'a region with a window is zeroed through it, as before')
check('mach_vm_map( mach_task_self(), &tmp, len, 0, VM_FLAGS_ANYWHERE, ios_donor_reg[r].entry, off % ios_donor_region, FALSE,' in give
      and 'madvise( (void *)tmp, len, MADV_ZERO );' in give and 'mach_vm_deallocate( mach_task_self(), tmp, len );' in give,
      'otherwise the freed range alone is mapped, zeroed and unmapped')
check('ios_donor_free_insert( off, len );' in give and give.index('ios_donor_free_insert') > give.index('mach_vm_deallocate'),
      'the range joins the free list after the zeroing')
check('the range is reused unzeroed' in give, 'a failed temporary window is reported (bounded) and the give still completes')

check('void madeira_swap_overlay_stats( unsigned long long *file_mb, unsigned long long *donor_mb, unsigned long long *donor_pool_mb,' in src
      and '*donor_guarded = ios_donor_guarded;' in src and '* ios_donor_region) >> 20;' in src,
      'madeira_swap_overlay_stats reports file-backed MB, donor MB, the pool size and guarded takes')
check('void madeira_swap_overlay_stats(unsigned long long *file_mb, unsigned long long *donor_mb, unsigned long long *donor_pool_mb,' in bridge,
      'the bridging header declares it for Swift')
check('"RAM", "JIT memory", "Swap & donor", "Battery"' in swift, 'the overlay settings offer the Swap & donor field')
check('madeira_swap_overlay_stats(&file, &donated, &pool, &guarded)' in swift
      and 'if model.overlayFields.contains("Swap & donor") {' in swift,
      'the metrics view samples it once a second while the field is shown')
check('"Donated \\(donatedMB)/\\(donorPoolMB) MB' in swift and '"Swap \\(swapFileMB) MB"' in swift,
      'the pill shows Donated used/pool MB (guarded count when non-zero) and the swap-file MB')

# ml2021: a 32-bit program's memory takes donor RAM, never the swap file, unless swap-wow64 says so
check('IOS_SW_WOW64, IOS_SW_REASONS };' in src and '"churn", "32-bit-ram" };' in src,
      'the census has a reason for 32-bit ranges kept in RAM')
pol = src[src.index('static int ios_swap_wow64_policy( void )'):src.index('static unsigned long long ios_swap_wow_kept;')]
check('madeira_cfg_int( "swap-wow64", 0 )' in pol and 'if (policy < 0 || policy > 2) policy = 0;' in pol,
      'madeira.cfg swap-wow64 (0 donor only, 1 donor then file, 2 never) is read once, out-of-range = default')
smap = src[src.index('static int ios_swap_map( void *base, size_t size, int unix_prot )'):src.index('static void ios_swap_release_range( void *base, size_t size, int copy_back )\n{')]
check('wow = ios_wow_window_covering( hs, he ) != 0;' in smap, 'the map step asks whether the range lies in a WoW64 guest window')
check('if (wow && ios_swap_wow64_policy() == 2) { ios_swap_wow_kept += len; return IOS_SW_WOW64; }' in smap
      and smap.index('ios_swap_wow64_policy() == 2') < smap.index('if (donor_first)   /* ml1150'),
      'policy 2 keeps the range in RAM before the donor attempt')
check('if (wow && ios_swap_wow64_policy() != 1)   /* ml2021: the rest stays RAM, not the file */' in smap
      and smap.index('ios_swap_wow64_policy() != 1') > smap.index('done = ios_swap_donor_pieces( hs, len, unix_prot, size );')
      and smap.index('ios_swap_wow64_policy() != 1') < smap.index('off = ios_swap_take( len );')
      and 'if (!done) return IOS_SW_WOW64;' in smap,
      'the default lets the donor pool serve what it can and stops before the file; nothing taken = kept in RAM')
take = src[src.index('static int ios_donor_guard( size_t len )'):src.index('static int ios_donor_map( char *va, size_t len, int unix_prot, uint64_t off )')]
check('static uint64_t ios_donor_margin;   /* ml2021: 0 =' in src and 'if (ios_donor_margin)' in take
      and 'host free %llu MB < margin %llu MB' in take,
      'the free-RAM margin is off by default (pressure alone guards) and a refusal names the measured free RAM')
# ml2021: the pressure guard is off unless madeira.cfg donor-pool-guard says 1 (critical) or 2 (warning too)
check('madeira_cfg_int( "donor-pool-guard", 0 )' in src and 'if (level < 0 || level > 2) level = 0;' in src
      and 'if (pressure && ((level == 2) || (level == 1 && pressure >= 2)))' in take,
      'pressure notifications stop takes only when donor-pool-guard asks (1 critical, 2 warning too)')
# ml2021: the churn filter spares 64-bit ranges beside a 32-bit program and the 32-bit program's own ranges under the donor-only policy
check('static int ios_swap_churn_exempt( uintptr_t b, size_t size )' in src
      and 'return ios_swap_x64_idle( b, size ) || ios_swap_wow_churn_exempt( b, size ) || ios_swap_footprint_tight();' in src
      and src.count('ios_swap_churn_exempt( b, size )') + src.count('ios_swap_churn_exempt( b, view->size )') >= 2,
      'both churn checks (commit and whole reservation) consult the exemption')
check('if (ios_swap_wow64_policy() != 0) return 0;' in src, "a 32-bit range is exempt only under the donor-only policy (never for the file)")
# ml2021: pieces -- a request is served from the largest piece available when no hole fits it whole
check('static uint64_t ios_donor_take_upto( size_t want, size_t *got )' in take
      and 'if (want > ios_donor_region) want = (size_t)ios_donor_region;' in take
      and 'if (big != ~0u && ios_donor_free[big].len >= room && ios_donor_free[big].len >= IOS_DONOR_MIN_PIECE)' in take
      and 'if (room >= IOS_DONOR_MIN_PIECE)' in take and '#define IOS_DONOR_MIN_PIECE (1u << 20)' in src,
      'a take larger than a region or than any hole gets the largest piece (free entry or bump room) of at least 1 MB')
check('ios_donor_take(' not in src.replace('ios_donor_take_upto(', ''), 'the whole-or-nothing take is gone')
pieces = src[src.index('static size_t ios_swap_donor_pieces( char *hs, size_t len, int unix_prot, size_t key )'):src.index('static int ios_swap_map( void *base, size_t size, int unix_prot )')]
check('while (done < len && ios_swap_n < 16384)' in pieces and 'ios_swap_record( hs + done, got, off | IOS_DONOR_FLAG, key );' in pieces,
      'the map step takes pool pieces until the range is covered or the pool has none, one extent each')
check("donor_first = wow || x64 == 1 || (x64 == 0 && (ios_swap_x64_title || !ios_swap_wow_in_session()));" in smap
      and 'madeira_cfg_int( "swap-x64", 0 )' in src,
      'a 64-bit range goes to the file first while a 32-bit program is in the session (swap-x64 unset), the pool otherwise')
# Log 94 (2026-10-28): a 32-bit helper in a 64-bit title's folder put the title's heap on the file all session.
policy = src[src.index('static int ios_swap_x64_policy( void )\n{'):src.index('static unsigned ios_swap_map_first;')]
check("ios_swap_x64_title = policy == 0 && title && title[0] == '1';" in policy
      and 'getenv( "MADEIRA_SWAP_X64_TITLE" )' in policy,
      'MADEIRA_SWAP_X64_TITLE=1 (a 64-bit title beside 32-bit helpers): donor RAM first under swap-x64 unset only')
idle = src[src.index('static int ios_swap_x64_idle( uintptr_t b, size_t size )'):src.index('static int ios_swap_wow64_policy( void );')]
check('if (keep || (title_keep && ios_swap_x64_title) || !ios_swap_broad || !ios_swap_wow_in_session()) return 0;' in idle
      and 'ios_swap_x64_policy();   /* sets ios_swap_x64_title */' in idle
      and "title_keep = !(t && t[0] == '0');" in idle and 'getenv( "MADEIRA_SWAP_TITLE_CHURN" )' in idle,
      'such a title keeps the churn filter (log 96: skipped, its hot churny memory went to the file); '
      'MADEIRA_SWAP_TITLE_CHURN=0 skips it')
tight = src[src.index('static int ios_swap_footprint_tight( void )'):src.index('static int ios_swap_churn_exempt( uintptr_t b, size_t size )')]
check('getenv( "MADEIRA_SWAP_CHURN_TIGHT_MB" )' in tight and ': 768;' in tight
      and 'tight = left && left < ((unsigned long long)margin << 20);' in tight and 'now - checked >= 250000000ull' in tight,
      'under 768 MB left before the memory limit (read every 250 ms) the churn filter yields; 0 = never')
check('|| ios_swap_footprint_tight();' in src[src.index('static int ios_swap_churn_exempt( uintptr_t b, size_t size )'):][:300],
      'both churn skips (a commit and a whole reservation) go through the exemption')
cv = (ROOT / 'app/Madeira/ContentView.swift').read_text()
dgs = (ROOT / 'app/Madeira/DockGameSession.swift').read_text()
check('if MadeiraConfig.flag("MADEIRA_DOCK_X64_TITLE"),' in cv
      and 'DockGameSession.largestProgramMachine(in: gameFolder, machine: DockInstallers.machine) == 0x8664 {' in cv
      and 'setenv("MADEIRA_SWAP_X64_TITLE", "1", 1)' in cv and 'unsetenv("MADEIRA_SWAP_X64_TITLE")' in cv,
      'a Dock start exports it when the game folder\'s largest program is 64-bit (env.MADEIRA_DOCK_X64_TITLE = 0: never)')
check('static func largestProgramMachine(in folder: URL, machine: (URL) -> UInt16?, limit: Int = 400) -> UInt16? {' in dgs
      and 'guard name.lowercased().hasSuffix(".exe"), !isRedistributable(name) else { continue }' in dgs,
      'the largest program: the same two-level walk as the 32-bit check, redistributables left out')
check('if (!donor_first && !file_only && (done = ios_swap_donor_pieces( hs, len, unix_prot, size )) != 0)' in smap,
      'with the file first, the pool is the fallback when the file refuses (not for a browser\'s range)')
# Log 99: the whole 4 GB pool went to a Chromium helper's PartitionAlloc reservation, touched or not.
check('file_only = !wow && (ios_swap_map_mode == 1 || ios_swap_browser());' in smap
      and 'if (file_only) { donor_first = 0; ios_swap_whole_file += len; }' in smap,
      'a Chromium browser\'s range (or an opt-in large whole reservation) is backed by the file only; a 32-bit program\'s keeps its rule')
br = src[src.index('static int ios_swap_browser( void )\n{'):]
br = br[:br.index('\n}\n')]
check('getenv( "MADEIRA_DONOR_BROWSERS" )' in br and "give = e && e[0] == '1';" in br and 'return !give && ios_avail_phys_chromium();' in br,
      'browsers are kept off the pool unless MADEIRA_DONOR_BROWSERS=1')
check('if (view->size > ios_donor_whole_max()) ios_swap_map_mode = 1;' in src
      and 'getenv( "MADEIRA_DONOR_WHOLE_MAX_MB" )' in src and ': 0;' in src[src.index('static uint64_t ios_donor_whole_max( void )'):][:600],
      'MADEIRA_DONOR_WHOLE_MAX_MB: opt-in, off by default (a game\'s big heap is hot)')
mode2 = smap[smap.index('if (ios_swap_map_mode == 2)'):smap.index('/* ml1257: in broad the cap is the disk')]
check('done = ios_swap_donor_pieces( hs, len, unix_prot, size );' in mode2 and 'if (!done) return IOS_SW_CHURN;' in mode2,
      'donor-only mapping: pool pieces or nothing, before the disk cap (no file involved)')
c2d = src[src.index('static int ios_swap_churn_to_donor( const void *base, size_t size )'):]
c2d = c2d[:c2d.index('\n}\n')]
check('getenv( "MADEIRA_DONOR_CHURN" )' in c2d and 'if (!on || ios_donor_room() < size) return 0;' in c2d
      and 'if (ios_wow_window_covering( base, (const char *)base + size )) return 0;' in c2d and 'if (ios_swap_browser()) return 0;' in c2d,
      'a churny size takes donor RAM while the pool has room (MADEIRA_DONOR_CHURN=0: anonymous as before)')
commit = src[src.index('static void ios_swap_commit( void *base, size_t size, unsigned int vprot, struct file_view *view )'):]
commit = commit[:commit.index('\n}\n')]
check('else if (why == IOS_SW_CHURN && ios_swap_churn_to_donor( base, size ))' in commit
      and 'ios_swap_map_mode = 2;' in commit and 'ios_swap_map_mode = 0;' in commit,
      'a churny commit tries donor RAM, and the mode is reset after the map')
check(src.count('for (i = ios_swap_map_first; i < ios_swap_n; i++) ios_swap_ext[i].resv = 1;') == 2
      and 'ios_swap_map_first = ios_swap_n;' in smap,
      'a reservation marks every extent its map call created')
check('32-bit kept in RAM %llu MB' in src, 'the donor stats line reports host free RAM and the MB kept in RAM for 32-bit programs')
check('MadeiraConfig.set("swap-wow64", choice.isEmpty ? nil : choice)' in swift and '"swap-wow64",' in swift,
      'Settings offers the 32-bit programs picker and the key is featured (not listed twice)')

# Log 96: the video budget's trim counts the donated pages against the RAM cap (winemetal, in the
# dxmt submodule; present in the build workspace).
wm_path = ROOT / 'dxmt/src/winemetal/unix/winemetal_unix.c'
if wm_path.exists():
    wm = wm_path.read_text(encoding='utf-8', errors='replace')
    check('unsigned long long *donor_pool_mb, unsigned long long *donor_guarded) __attribute__((weak));' in wm,
          'winemetal reads the donated MB through the stats function (a weak reference)')
    check('on = madeira_cfg_int("vram-count-donor", 0) != 0;' in wm, 'madeira.cfg vram-count-donor = 1 counts the donor (off by default)')
    dyn = wm[wm.index('static uint64_t madeira_ml1075_dynamic_budget(uint64_t base) {'):wm.index('static uint64_t madeira_ml1042_video_budget(uint64_t metal_recommended) {')]
    check('if (cap && foot + donor > room && foot + donor - room > over) over = foot + donor - room;' in dyn
          and 'if (over) budget = base > over ? base - over : 0;' in dyn,
          'the footprint and the donated pages together are held vram-trim-mb below the RAM cap; the larger excess trims')
else:
    print('SKIP: dxmt submodule not checked out here')

# ml2200: donor-pool-mb without swap-mb maps the donor pool alone, no swap file (madeira.cfg donor-only = 0: off).
wpb = (ROOT / 'app/Madeira/WineProcessBridge.m').read_text(encoding='utf-8', errors='replace')
check('long onlyPoolMB = capMB >= 64 ? 0 : (long)madeira_cfg_int("donor-pool-mb", 0);' in wpb
      and 'if (onlyPoolMB >= 512 && madeira_cfg_int("donor-only", 1)) {' in wpb
      and 'setenv("MADEIRA_SWAP_DONOR_ONLY", "1", 1);' in wpb,
      'the app starts the donor pool without swap-mb and asks ntdll for the donor-only tier')
init = src[src.index('static void ios_swap_init( void )\n{'):]
init = init[:init.index('\n}\n') + 3]
check('(d = getenv( "MADEIRA_SWAP_DONOR_ONLY" )) && d[0] == \'1\'' in init
      and 'ios_swap_cap = ios_swap_logical = 0;' in init and 'ios_swap_donor_only = 1;' in init,
      'the donor-only tier has no file space: every file take is refused, only donated RAM is mapped')
check('if (ios_swap_broad && !ios_swap_donor_only && ios_swap_disk_used() >= ios_swap_cap)' in src,
      'the broad disk-cap check does not refuse the donor-first path in donor-only mode')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_DONOR_WINDOWS"' in text, 'the config catalog documents env.MADEIRA_DONOR_WINDOWS')
    check('key: "swap-wow64"' in text, 'the config catalog documents swap-wow64')
    check('key: "vram-count-donor"' in text, 'the config catalog documents vram-count-donor')
    check('key: "donor-only"' in text, 'the config catalog documents donor-only')
    check('key: "env.MADEIRA_SWAP_TITLE_CHURN"' in text, 'the config catalog documents env.MADEIRA_SWAP_TITLE_CHURN')
    for key in ('env.MADEIRA_DONOR_WHOLE_MAX_MB', 'env.MADEIRA_DONOR_CHURN', 'env.MADEIRA_DONOR_BROWSERS'):
        check('key: "%s"' % key in text, 'the config catalog documents %s' % key)

print(f'check-donor-pool: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
