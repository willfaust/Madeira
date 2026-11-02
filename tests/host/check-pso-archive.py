#!/usr/bin/env python3
"""pso-archive: compiled pipelines kept in Metal binary archives of our own; a
non-PlayStation pad stays on XInput in the HID pad mode.

Logs 2026-10-26 23:33 and 23:36 (vk-1026-m2, the same game and build): Metal's own
cache had 6,904 of 6,986 pipelines in one session and 19 of the first 500 in the
next, whose warm-up then compiled at 420-550 ms each for minutes while the game
fell to 0.2-4 FPS for seconds at a time. With madeira.cfg pso-archive = 1,
madeira-d3d12 names a folder per executable in its shader cache build directory
(MadeiraCtl op 11) and winemetal looks there first, adding what it had to compile.

Log 2026-10-27 01:00 (the first session with an empty directory): the queue add
compiled every pipeline a second time and kept 1,536 of 6,027 misses; a miss is now
compiled once, into a slot's open archive, and created from it; and each new IPA
started with an empty archive (the build directory is pruned), so the folder now
outlives builds under a size cap.

The same logs: a GameSir pad in env.MADEIRA_PAD_MODE = hid became a generic HID
gamepad off XInput, which the game saw in one run of three.

Static checks on madeira_d3d12.c, winemetal_unix.c (MADEIRA_DXMT_DIR, else the
dxmt submodule), GamepadInput.swift, the GTA V lists and the settings catalog.
"""
from pathlib import Path
import os
import re
import sys

root = Path(__file__).resolve().parents[2]
dxmt = Path(os.environ.get('MADEIRA_DXMT_DIR', root / 'dxmt'))
def read(p):
    return Path(p).read_text().replace('\r\n', '\n')
pe = read(root / 'madeira-d3d12/src/pe/madeira_d3d12.c')
wm = read(dxmt / 'src/winemetal/unix/winemetal_unix.c')
pad = read(root / 'app/Madeira/GamepadInput.swift')
recs = read(root / 'app/Madeira/GameRecommendations.swift')
catalog = read(root / 'app/Madeira/ConfigCatalog.generated.swift')
ok = True


def check(what, cond):
    global ok
    print(('ok   ' if cond else 'FAIL ') + what)
    ok &= bool(cond)


def body(src, sig):
    start = src.index(sig)
    while src.index(';', start) < src.index('{', start):   # a prototype: the definition comes later
        start = src.index(sig, start + 1)
    brace = src.index('{', start)
    depth = 0
    for i in range(brace, len(src)):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
    raise AssertionError('unterminated: ' + sig)


# --- madeira-d3d12 -------------------------------------------------------------
init = body(pe, 'static void mad_pso_archive_init(void)')
check('off by default (madeira.cfg pso-archive)', 'mad_cfg_int_pe("pso-archive", 0) <= 0) return;' in init)
check('a folder per executable and switch set that outlives builds',
      'L"%ls\\\\Madeira\\\\PipelineArchive\\\\%ls-%016llx", base, rt + 1, (unsigned long long)h.a' in init
      and 'GetModuleFileNameW(NULL, exe, MAX_PATH)' in init)
check('MADEIRA_PSO_ARCHIVE_PER_BUILD=1: the build directory, as first written',
      'GetEnvironmentVariableA("MADEIRA_PSO_ARCHIVE_PER_BUILD", v, sizeof v)' in init
      and 'L"%ls\\\\pso-archive-%016llx", g_sc_dir' in init)
check('the unix path goes to winemetal as op 11 and is freed',
      'a.op = 11;' in init and 'HeapFree(GetProcessHeap(), 0, udir);' in init)
check('named once the shader cache directory exists',
      'if (on) { mad_scn_init(); mad_pso_archive_init(); MemoryBarrier(); }' in pe)

# --- winemetal -------------------------------------------------------------------
check('op 11 names the directory (not in remote mode)',
      'case 11:' in wm and 'a->ret = madeira_arch_name((const char *)(uintptr_t)a->ptr);' in wm)
look = body(wm, 'static NSArray *madeira_arch_lookup(id<MTLDevice> device)')
check('no directory: nil, so nothing changes', 'memory_order_acquire) != 2 || !device) return nil;' in look)
check('chunks load once, with the first device', 'dispatch_once(&once, ^{ madeira_arch_load(device); });' in look)
load = body(wm, 'static void madeira_arch_load(id<MTLDevice> device)')
check('an unfinished save, an unreadable chunk and an old one over the cap are deleted',
      load.count('unlink(path);') == 3 and 'strcmp(e->d_name + used, ".metalar")' in load)
save = body(wm, 'static void madeira_arch_save_archive(')
check('a chunk is written to a temporary name, renamed, then joins the lookup list',
      'serializeToURL' in save and 'rename(tmp, path)' in save and 'arrayByAddingObject:a' in save)
add = body(wm, 'static void madeira_arch_add(id descriptor, int kind)')
check('adds run on the archive queue with a copy of the descriptor',
      '[descriptor copy]' in add and 'dispatch_async(madeira_arch_q' in add and '[copy release];' in add)
check('a chunk every MADEIRA_ARCH_CHUNK pipelines, else 10 s after the last add',
      '>= MADEIRA_ARCH_CHUNK) madeira_arch_save();' in add and 'madeira_arch_arm();' in add)
check('render (twice) and compute look in the saved chunks first, failing on a miss',
      wm.count('options:(MTLPipelineOption)(options | MTLPipelineOptionFailOnBinaryArchiveMiss)') == 3)
check('a miss is created as before and added',
      wm.count('if (madeira_arch && params->ret_pso && !err) madeira_arch_add(descriptor, 0);') == 2 and
      wm.count('if (madeira_arch && params->ret_pso && !err) madeira_arch_add(descriptor, 1);') == 1)
check("a caller's own archives are left alone", wm.count('descriptor.binaryArchives ? nil : madeira_arch_lookup(') == 3)

# --- inline add (log 90: the queue add compiled every pipeline twice) ----------------
create = body(wm, 'static obj_handle_t madeira_arch_create(')
check('inline: off with MADEIRA_PSO_ARCHIVE_INLINE=0', 'getenv("MADEIRA_PSO_ARCHIVE_INLINE")' in wm)
check('inline: a free slot only (trylock), else the queue path',
      'os_unfair_lock_trylock(&madeira_arch_slots[i].lock)' in create and 'if (!s) return 0;' in create)
check('inline: compiled once by the add, created from that archive',
      'addRenderPipelineFunctionsWithDescriptor:descriptor error:&e' in create and
      '[descriptor setBinaryArchives:@[ s->open ]];' in create and '[descriptor setBinaryArchives:nil];' in create)
check('inline: a full slot goes to the queue to be saved',
      '>= MADEIRA_ARCH_CHUNK) {' in create and 'madeira_arch_save_handed(s->open, s->n);' in create)
check('inline: tried before the queue path at all three sites',
      wm.count('= madeira_arch_create(') == 3 and wm.count('if (!params->ret_pso) {\n    err = NULL;') == 3)
check('idle slots are saved by the timer',
      'madeira_arch_save_archive(s->open, s->n);' in body(wm, 'static void madeira_arch_arm(void)'))

# --- kept across builds, capped ---------------------------------------------------------
check('cap: MADEIRA_PSO_ARCHIVE_MB, default 1024', 'getenv("MADEIRA_PSO_ARCHIVE_MB")' in load and ': 1024ull) << 20;' in load)
check('cap: over it, the oldest chunks go at load down to three quarters',
      'qsort(files, nfiles, sizeof *files, madeira_arch_file_cmp);' in load and 'prune = total > cap;' in load
      and 'if (prune && total > cap / 4 * 3) {' in load)
check('cap: a full directory takes no adds (queue and inline)',
      'if (madeira_arch_full()) return;' in add and 'madeira_arch_full()) return 0;' in create)
check('cap: a saved chunk counts toward it',
      'atomic_fetch_add_explicit(&madeira_arch_bytes, (unsigned long long)st.st_size' in save)

# --- recommendations and catalog --------------------------------------------------
for ident in ('gta5e-steam', 'gta5e-other'):
    m = re.search(r'id: "%s", title: "[^"]+", version: (\d+),\n\s*config: """\n(.*?)"""' % ident, recs, re.S)
    check('%s carries pso-archive = 1' % ident, m is not None and '\n        pso-archive = 1\n' in m.group(2))
check('catalog: pso-archive, default 0, Direct3D 12',
      re.search(r'key: "pso-archive", title: "", kind: \.int, defaultValue: "0", category: "Direct3D 12"', catalog) is not None)

# --- HID pad mode ------------------------------------------------------------------
sess = body(pad, '@MainActor func beginPadSession()')
check('hid mode: a paired pad that is not a PlayStation one stays on XInput',
      'if mode.value == "hid", first != nil, !sony, !Self.optIn("MADEIRA_HIDPAD_AUTO_GENERIC") {' in sess)
i = sess.index('MADEIRA_HIDPAD_AUTO_GENERIC")')
check('... before MADEIRA_HIDPAD is exported, with XInput rumble kept',
      i < sess.index('setenv("MADEIRA_HIDPAD", kind, 1)') and
      'beginPadOutput(xinput: output.xinput, hid: false, value: output.value)\n            return' in sess[i:])
check('catalog: env.MADEIRA_HIDPAD_AUTO_GENERIC, default 0',
      re.search(r'key: "env.MADEIRA_HIDPAD_AUTO_GENERIC", title: "[^"]+", kind: \.bool, defaultValue: "0"', catalog) is not None)

sys.exit(0 if ok else 1)
