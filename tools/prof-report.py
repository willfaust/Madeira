#!/usr/bin/env python3
"""Report on a [prof] capture (server_ios.c ios_prof_main, MADEIRA_PROF=1).

usage: python3 -I tools/prof-report.py <madeira-prof-*.bin> <game log> <exe> [--jitmap f.bin ...] [--top N]
                           [--thread NAME] [--from HH:MM:SS] [--to HH:MM:SS]

Weights are CPU nanoseconds, so every percentage is a share of the CPU time the
task actually used (runnable-but-waiting threads weigh nothing).

- .bin: 32-byte records (u64 pc, u64 guest rip, u64 extra, u32 weight ns, u16 slot,
  u8 class, u8 flags); class 0 FEX JIT code, 1 ARM64EC image copy (extra = PE
  address), 2 native (extra = lr), 0xfe time mark (pc = mach ns, rip = wall ms).
- .txt next to it: T slot port name / S key fbase file sym+off / J rx size / P period_us.
- JIT host pcs map to guest code only through --jitmap files (a FEX build that writes
  its JIT block map; not part of this tree), then to exe functions through .pdata;
  without them JIT samples are reported by host block. Image PE addresses map to
  modules through the sidecar's M lines or the log's "Load module" lines.
"""
import argparse, bisect, collections, datetime, os, re, struct

ap = argparse.ArgumentParser()
ap.add_argument('bin')
ap.add_argument('log')
ap.add_argument('exe')
ap.add_argument('--jitmap', nargs='*', default=[])
ap.add_argument('--top', type=int, default=25)
ap.add_argument('--thread', help='only threads whose name contains this')
ap.add_argument('--from', dest='t_from')
ap.add_argument('--to', dest='t_to')
ap.add_argument('--keep-waits', action='store_true', help='keep samples caught in a wait (see below)')
args = ap.parse_args()

# sidecar
threads, syms = {}, {}
slot_peb = {}                                  # newer captures: P slot peb
peb_modules = collections.defaultdict(dict)    # peb -> {base: (size, name)} from M lines
txt = args.bin[:-4] + '.txt'
if os.path.exists(txt):
    for line in open(txt, errors='replace'):
        p = line.rstrip('\n').split(' ', 4)
        if p[0] == 'T' and len(p) >= 3:
            threads[int(p[1])] = p[3] if len(p) > 3 else p[2]
        elif p[0] == 'S' and len(p) >= 5:
            syms[int(p[1], 16)] = '%s`%s' % (p[3], p[4])
        elif p[0] == 'P' and len(p) >= 3:
            slot_peb[int(p[1])] = int(p[2], 16)
        elif p[0] == 'M' and len(p) >= 5:
            peb_modules[int(p[1], 16)][int(p[2], 16)] = (int(p[3], 16), os.path.basename(p[4].replace('\\', '/')))
peb_sorted = {peb: sorted((b, sz, n) for b, (sz, n) in mods.items()) for peb, mods in peb_modules.items()}

# modules from the log
module_loads = []
for line in open(args.log, errors='replace'):
    m = re.search(r'Load module (\S+) \([^)]*\): ([0-9A-Fa-f]+)', line)
    if m:
        module_loads.append((int(m.group(2), 16), os.path.basename(m.group(1).replace('\\', '/'))))
module_loads = sorted(set(module_loads))
module_starts = [m[0] for m in module_loads]

# jit maps
recs = []
for path in args.jitmap:
    data = open(path, 'rb').read()
    for off in range(0, len(data) - 31, 32):
        hb, rip, hs, gs, ms, seq = struct.unpack_from('<QQIIII', data, off)
        if rip:
            recs.append((hb, hb + hs, rip, seq))
recs.sort()
jit_starts = [r[0] for r in recs]

def jit_block(host):
    i = bisect.bisect_right(jit_starts, host) - 1
    best = None
    for j in range(i, max(i - 64, -1), -1):
        r = recs[j]
        if r[0] <= host < r[1] and (best is None or r[3] > best[3]):
            best = r
    return best

# exe functions
d = open(args.exe, 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]
nsec = struct.unpack_from('<H', d, pe + 6)[0]
optsz = struct.unpack_from('<H', d, pe + 20)[0]
opt = pe + 24
exe_base = struct.unpack_from('<Q', d, opt + 24)[0]
exe_size = struct.unpack_from('<I', d, opt + 56)[0]
secs = []
for i in range(nsec):
    o = opt + optsz + i * 40
    vs, va, rs, ra = struct.unpack_from('<IIII', d, o + 8)
    secs.append((va, vs, ra, rs))
def file_off(rva):
    for va, vs, ra, rs in secs:
        if va <= rva < va + max(vs, rs):
            return rva - va + ra
pdata_rva, pdata_sz = struct.unpack_from('<II', d, opt + 112 + 3 * 8)
po = file_off(pdata_rva)
funcs = sorted(struct.unpack_from('<II', d, po + 12 * i) for i in range(pdata_sz // 12))
func_starts = [f[0] for f in funcs]

def module_in_process(peb, address):
    mods = peb_sorted.get(peb)
    if not mods:
        return None
    i = bisect.bisect_right([m[0] for m in mods], address) - 1
    if i >= 0 and address < mods[i][0] + mods[i][1]:
        return '%s+%#x' % (mods[i][2], (address - mods[i][0]) & ~0xf)
    return None

def guest_name(rip, peb=None):
    if exe_base <= rip < exe_base + exe_size:
        rva = rip - exe_base
        i = bisect.bisect_right(func_starts, rva) - 1
        if i >= 0 and funcs[i][0] <= rva < funcs[i][1]:
            return 'exe+%#x' % funcs[i][0]
        return 'exe+%#x(no pdata)' % (rva & ~0xff)
    if peb is not None:
        named = module_in_process(peb, rip)
        if named:
            return named
        if peb in peb_sorted:
            return '%#x(not in its process)' % (rip & ~0xf)
    i = bisect.bisect_right(module_starts, rip) - 1
    if i >= 0:
        return '%s+%#x' % (module_loads[i][1], (rip - module_loads[i][0]) & ~0xf)
    return '%#x' % rip

def native_name(pc):
    return syms.get(pc & ~0xf, '%#x' % (pc & ~0xf))

def hms_to_ms(s, day_ms):
    h, m, sec = (int(x) for x in s.split(':'))
    return day_ms + ((h * 60 + m) * 60 + sec) * 1000

# samples. A thread that ran and then blocked is sampled in its wait, so its pc says
# nothing about where the weight went: newer captures flag running samples (flags
# bit 1) and only those count; older ones drop samples whose pc is a known wait.
WAITS = ('__ulock_wait', 'semaphore_timedwait_trap', 'semaphore_wait_trap', 'mach_msg2_trap', '__select',
         'kevent', '__semwait_signal', '__psynch_cvwait', '__psynch_mutexwait', 'swtch_pri', '__workq_kernreturn',
         'wait_select_reply', 'read_reply_data', '__sigsuspend', 'poll')
data = open(args.bin, 'rb').read()
has_run_flag = any(data[off + 31] & 2 for off in range(0, len(data) - 31, 32))
dropped_wait = 0
wall_ms = None
t_lo = t_hi = None
by_class = collections.Counter()
by_thread = collections.Counter()
by_func = collections.Counter()          # (class tag, name)
by_thread_func = collections.defaultdict(collections.Counter)
native_callers = collections.defaultdict(collections.Counter)
unmapped_jit = 0
first_ms = last_ms = None
for off in range(0, len(data) - 31, 32):
    pc, rip, extra, w, slot, cls, flags = struct.unpack_from('<QQQIHBB', data, off)
    if cls == 0xfe:
        wall_ms = rip
        if first_ms is None:
            first_ms = rip
            day = datetime.datetime.fromtimestamp(rip / 1000).replace(hour=0, minute=0, second=0, microsecond=0)
            day_ms = int(day.timestamp() * 1000)
            t_lo = hms_to_ms(args.t_from, day_ms) if args.t_from else None
            t_hi = hms_to_ms(args.t_to, day_ms) if args.t_to else None
        last_ms = rip
        continue
    if wall_ms is not None and ((t_lo and wall_ms < t_lo) or (t_hi and wall_ms > t_hi)):
        continue
    tname = threads.get(slot, '') or 'slot%d' % slot
    if args.thread and args.thread not in tname:
        continue
    if not args.keep_waits:
        if has_run_flag:
            blocked = not flags & 2
        else:
            blocked = cls == 2 and any(w in native_name(pc) or w in native_name(extra) for w in WAITS)
        if blocked:
            dropped_wait += w
            continue
    if cls == 0:
        blk = jit_block(pc)
        if blk:
            name = 'jit  ' + guest_name(blk[2], slot_peb.get(slot))
        else:
            unmapped_jit += w
            name = 'jit  ? (rip %s)' % (guest_name(rip) if flags & 1 else '-')
    elif cls == 1:
        name = 'ec   ' + guest_name(extra, slot_peb.get(slot))
    else:
        name = 'nat  ' + native_name(pc)
        native_callers[name][native_name(extra)] += w
    by_class[cls] += w
    by_thread[tname] += w
    by_func[name] += w
    by_thread_func[tname][name] += w

total = sum(by_class.values())
if not total:
    raise SystemExit('no samples in range')
span = (last_ms - first_ms) / 1000.0 if first_ms is not None and last_ms != first_ms else 0
if not args.keep_waits:
    print('dropped %.1f CPU s of samples caught in a wait (%s)' % (dropped_wait / 1e9,
          'not running when sampled' if has_run_flag else 'old capture: pc in a known wait'))
print('%.1f CPU s%s: JIT %.0f%%, ARM64EC images %.0f%%, native %.0f%%; JIT unmapped %.1f%%' % (
    total / 1e9, ' over %.0f s wall (%.2f cores avg)' % (span, total / 1e9 / span) if span else '',
    100.0 * by_class[0] / total, 100.0 * by_class[1] / total, 100.0 * by_class[2] / total, 100.0 * unmapped_jit / total))
print('\nthreads (share of all CPU):')
for name, w in by_thread.most_common(15):
    print('  %5.1f%%  %s%s' % (100.0 * w / total, name, '  %.2f cores' % (w / 1e9 / span) if span else ''))
print('\nfunctions:')
acc = 0
for name, w in by_func.most_common(args.top):
    acc += w
    line = '  %5.2f%%  cum %5.1f%%  %s' % (100.0 * w / total, 100.0 * acc / total, name)
    if name in native_callers:
        line += '   <- ' + ', '.join('%s %.0f%%' % (c, 100.0 * cw / w) for c, cw in native_callers[name].most_common(2))
    print(line)
for tname, _ in by_thread.most_common(4):
    tw = by_thread[tname]
    print('\n%s (%.1f%% of all): ' % (tname, 100.0 * tw / total))
    for name, w in by_thread_func[tname].most_common(10):
        print('  %5.1f%%  %s' % (100.0 * w / tw, name))
