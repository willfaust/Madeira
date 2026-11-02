#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Indexed Direct3D 9 draws store only the index bytes they read
(build/dxmt-patches/0001-d3d9-index-range-per-draw.patch).

DXMT's 32-bit Direct3D 9 path hands the game a host mirror of each index
buffer and, before every draw after a write lock (and before every draw while
a lock is held), renamed the buffer and copied the whole mirror into it. An
engine that keeps one big index buffer mapped while it draws, or locks a little
of it before each draw, spends its render thread in that copy. The patch makes
the draw store only its StartIndex .. StartIndex + count bytes, renaming only
after a write lock without NOOVERWRITE.

Checks the patch's text, that every dxmt patch applies in order on the pinned
dxmt, and then compiles the patched refreshRange, renameBeforeStore,
indexRangeEnabled/noteIndexRangeStore and the Lock bookkeeping out of the
patched source against fakes and runs them:
- random lock / write / draw sequences in which the GPU runs every recorded
  draw only at the very end: each draw must then read exactly the bytes the
  mirror held when it was recorded, as long as the application keeps
  NOOVERWRITE's promise (and writes anywhere after a plain or DISCARD lock,
  including outside any window it announced);
- a buffer held mapped across many draws and a lock per draw: each draw stores
  its own bytes only, with no rename;
- DISCARD renames once; a plain lock renames once;
- a static buffer drawn in pieces is stored once and then left alone;
- the out-of-memory fallback keeps refreshWholeMirror's order;
- MADEIRA_D3D9_INDEX_RANGE=0 goes back to the whole-buffer refresh.
"""
from pathlib import Path
import shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
patches = root / 'build/dxmt-patches'
patch_path = patches / '0001-d3d9-index-range-per-draw.patch'
patch = patch_path.read_text(encoding='utf-8')
catalog = (root / 'app/Madeira/ConfigCatalog.generated.swift').read_text(encoding='utf-8')
gen = (root / 'build/tools/gen-config-catalog.py').read_text(encoding='utf-8')
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


files = sorted(l.split(' b/')[-1] for l in patch.splitlines() if l.startswith('diff --git'))
check(files == ['src/d3d9/d3d9_buffer.cpp', 'src/d3d9/d3d9_buffer.hpp',
                'src/d3d9/d3d9_device.cpp', 'src/d3d9/d3d9_device.hpp'],
      'touches the d3d9 buffer and device files only')
added = '\n'.join(l[1:] for l in patch.splitlines() if l.startswith('+') and not l.startswith('+++'))
removed = '\n'.join(l[1:] for l in patch.splitlines() if l.startswith('-') and not l.startswith('---'))
check('env::getEnvVar("MADEIRA_D3D9_INDEX_RANGE") != "0"' in added, 'MADEIRA_D3D9_INDEX_RANGE=0 turns it off, on by default')
check('void refreshRange(UINT begin, UINT end);' in added and 'MTLD3D9IndexBuffer::refreshRange(UINT begin, UINT end)' in added,
      'the index buffer gets refreshRange')
check('BuildDrawCapture(UINT ib_begin = 0, UINT ib_end = UINT_MAX);' in added,
      'BuildDrawCapture refreshes everything by default, as before')
check(added.count('draw.cap = BuildDrawCapture(0, 0);') == 8,
      'the eight draws that read no bound index buffer store none of it')
check('draw.cap = BuildDrawCapture(static_cast<UINT>(ib_begin), static_cast<UINT>(ib_end));' in added
      and 'uint64_t(StartIndex) * ib_index_size' in added and 'uint64_t(index_count) * ib_index_size' in added,
      'DrawIndexedPrimitive passes the bytes it reads, in 64-bit arithmetic')
check('if (ib_begin == 0 && ib_end == UINT_MAX)\n      m_indexBuffer->refreshWholeMirror();\n    else\n      m_indexBuffer->refreshRange(ib_begin, ib_end);' in added,
      'BuildDrawCapture picks whole or range')
check('ConfigOption(key: "env.MADEIRA_D3D9_INDEX_RANGE"' in catalog and '"env.MADEIRA_D3D9_INDEX_RANGE": {' in gen,
      'catalog lists env.MADEIRA_D3D9_INDEX_RANGE')

FIXTURE_HEAD = r'''
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <vector>
typedef unsigned int UINT;
typedef uint32_t DWORD;
typedef int32_t HRESULT;
#define D3DLOCK_READONLY 0x00000010L
#define D3DLOCK_NOOVERWRITE 0x00001000L
#define D3DLOCK_DISCARD 0x00002000L
#define FAILED(hr) ((HRESULT)(hr) < 0)
#define SUCCEEDED(hr) ((HRESULT)(hr) >= 0)
static const char *g_env = "";
static int g_warns, g_infos, g_rename_calls, g_rename_failures, g_drains, g_in_place;
static bool g_drain_ok = true, g_gpu_idle;
static uint64_t g_stored, g_store_calls;
namespace env { std::string getEnvVar(const char *) { return g_env; } }
struct Logger {
  static void warn(const std::string &) { ++g_warns; }
  static void info(const std::string &) { ++g_infos; }
};
static bool buffer_lock_updates_dirty(DWORD flags) { return !(flags & D3DLOCK_READONLY); }
struct Name {
  std::vector<uint8_t> bytes;
  void updateContents(uint64_t offset, const void *data, uint64_t length, uint32_t sub) {
    assert(sub == 0 && length > 0 && offset + length <= bytes.size());
    std::memcpy(bytes.data() + offset, data, length);
    g_stored += length;
    ++g_store_calls;
  }
};
struct Dynamic {
  std::vector<std::unique_ptr<Name>> gens;
  Name *immediateName() { return gens.back().get(); }
  uint32_t immediateSuballocation() { return 0; }
};
struct DynamicRef {
  Dynamic d;
  Dynamic *operator->() { return &d; }
  Dynamic *ptr() { return &d; }
};
struct Device {
  uint64_t m_currentCmdSeq = 2;
  std::atomic<uint64_t> m_cachedSignaled{1};
  bool drainForDynamicRename() { ++g_drains; g_gpu_idle = g_drain_ok; return g_drain_ok; }
  void noteRenameInPlace() { assert(g_gpu_idle); ++g_in_place; }
};
// A rename installs a fresh generation that holds none of the mirror's bytes.
static HRESULT renameDynamicBuffer(Device *, Dynamic *dynamic, uint64_t, uint64_t) {
  ++g_rename_calls;
  if (g_rename_failures > 0) { --g_rename_failures; return -1; }
  auto fresh = std::make_unique<Name>();
  fresh->bytes.assign(dynamic->gens.back()->bytes.size(), 0xcd);
  dynamic->gens.push_back(std::move(fresh));
  return 0;
}
struct MTLD3D9IndexBuffer {
  Device device;
  Device *m_device = &device;
  DynamicRef m_dynamic;
  void *m_hostPtr = nullptr;
  UINT m_size = 0;
  bool m_dirty = false, m_writeLocked = false, m_direct = false, m_renameDue = false, m_renameEachStore = false;
  UINT m_currentBegin = 0, m_currentEnd = 0;
  struct { uint32_t count = 0; uint32_t increment() { return ++count; }
           uint32_t decrement() { return count ? --count : 0; } } m_lockCount;
  int whole = 0;
  // Counted only: dxmt's own tests/d3d9/check_dynamic_rename_wait.py runs the real one.
  void refreshWholeMirror() { ++whole; }
  bool renameBeforeStore();
  void refreshRange(UINT begin, UINT end);
  void lockWrite(DWORD Flags);
  void unlock();
  explicit MTLD3D9IndexBuffer(std::vector<uint8_t> &mirror) {
    m_hostPtr = mirror.data();
    m_size = static_cast<UINT>(mirror.size());
    auto first = std::make_unique<Name>();
    first->bytes.assign(mirror.size(), 0xab);
    m_dynamic.d.gens.push_back(std::move(first));
  }
};
'''

FIXTURE_TAIL = r'''
struct Recorded { size_t gen; UINT begin, end; std::vector<uint8_t> want; };
struct Model {
  std::vector<uint8_t> mirror;
  MTLD3D9IndexBuffer ib;
  std::vector<Recorded> draws;
  explicit Model(UINT size) : mirror(size), ib(mirror) {}
  void draw(UINT begin, UINT end) {
    ib.refreshRange(begin, end);
    end = std::min<UINT>(end, (UINT)mirror.size());
    if (begin >= end) return;
    draws.push_back({ib.m_dynamic.d.gens.size() - 1, begin, end,
                     std::vector<uint8_t>(mirror.begin() + begin, mirror.begin() + end)});
  }
  // The GPU runs every recorded draw now, against the generation it was recorded with.
  void verify() {
    for (auto &d : draws) {
      auto &bytes = ib.m_dynamic.d.gens[d.gen]->bytes;
      assert(std::equal(d.want.begin(), d.want.end(), bytes.begin() + d.begin));
    }
  }
};
static void reset_counters() {
  g_stored = g_store_calls = 0;
  g_rename_calls = g_rename_failures = g_drains = g_in_place = g_warns = 0;
  g_drain_ok = true; g_gpu_idle = false;
}
static bool overlaps(UINT b, UINT e, const std::vector<std::pair<UINT, UINT>> &ranges) {
  for (auto &r : ranges) if (b < r.second && r.first < e) return true;
  return false;
}
static void random_run(uint32_t seed, UINT size) {
  std::mt19937 rng(seed);
  Model m(size);
  // A DEFAULT buffer's contents are undefined until the application writes
  // them, so the run starts with one plain lock over random contents.
  for (auto &b : m.mirror) b = (uint8_t)rng();
  m.ib.lockWrite(0);
  m.ib.unlock();
  // What draws recorded since the last plain or DISCARD write lock read: the
  // bytes NOOVERWRITE promises not to change.
  std::vector<std::pair<UINT, UINT>> in_use;
  bool locked = false, writable = false, nooverwrite = false;
  // Renames: one per plain or DISCARD write lock, and one per draw while such
  // a lock is held (each of those draws keeps its own copy).
  int rename_budget = 1;
  for (int step = 0; step < 600; ++step) {
    unsigned op = rng() % 10;
    if (!locked && op < 3) {
      static const DWORD choices[] = {0, D3DLOCK_DISCARD, D3DLOCK_NOOVERWRITE, D3DLOCK_NOOVERWRITE,
                                      D3DLOCK_NOOVERWRITE, D3DLOCK_READONLY};
      DWORD flags = choices[rng() % 6];
      m.ib.lockWrite(flags);
      locked = true;
      writable = !(flags & D3DLOCK_READONLY);
      nooverwrite = flags & D3DLOCK_NOOVERWRITE;
      if (writable && !nooverwrite) { in_use.clear(); ++rename_budget; }
    } else if (locked && writable && op < 6) {
      for (int tries = 0; tries < 8; ++tries) {
        UINT b = rng() % size, e = std::min<UINT>(size, b + 1 + rng() % 96);
        if (nooverwrite && overlaps(b, e, in_use)) continue;
        for (UINT i = b; i < e; ++i) m.mirror[i] = (uint8_t)rng();
        break;
      }
    } else if (locked && op < 7) {
      m.ib.unlock();
      locked = false;
    } else {
      UINT b = rng() % size, e = b + 1 + rng() % 128;   // may run past the end: clamped
      if (locked && writable && !nooverwrite) ++rename_budget;
      m.draw(b, e);
      in_use.push_back({b, std::min<UINT>(e, size)});
    }
  }
  m.verify();
  assert((int)m.ib.m_dynamic.d.gens.size() - 1 <= rename_budget);
  assert(m.ib.whole == 0);
}
int main() {
  reset_counters();
  for (uint32_t seed = 1; seed <= 400; ++seed) random_run(seed, 64 + seed % 7 * 512 + seed % 5);

  // Held mapped across many draws (NOOVERWRITE): each draw stores its own
  // bytes, nothing else, and nothing renames.
  { reset_counters(); Model m(1 << 21);
    m.ib.lockWrite(D3DLOCK_NOOVERWRITE);
    for (UINT i = 0; i < 200; ++i) { for (UINT k = 0; k < 6144; ++k) m.mirror[i * 6144 + k] = (uint8_t)(i + k); m.draw(i * 6144, (i + 1) * 6144); }
    assert(g_stored == 200u * 6144 && g_rename_calls == 0 && m.ib.m_dirty);
    m.ib.unlock();
    m.verify(); }

  // A NOOVERWRITE lock before each draw: the same.
  { reset_counters(); Model m(1 << 21);
    for (UINT i = 0; i < 200; ++i) {
      m.ib.lockWrite(D3DLOCK_NOOVERWRITE);
      for (UINT k = 0; k < 6144; ++k) m.mirror[i * 6144 + k] = (uint8_t)(i * 3 + k);
      m.ib.unlock();
      m.draw(i * 6144, (i + 1) * 6144);
    }
    assert(g_stored == 200u * 6144 && g_rename_calls == 0);
    // A draw whose bytes are current stores nothing.
    m.draw(199 * 6144, 200 * 6144); assert(g_stored == 200u * 6144);
    // DISCARD at the wrap renames once; the earlier draws keep their bytes.
    m.ib.lockWrite(D3DLOCK_DISCARD);
    std::memset(m.mirror.data(), 0x5a, 6144);
    m.ib.unlock();
    m.draw(0, 6144); m.draw(0, 6144);
    assert(g_rename_calls == 1 && m.ib.m_dynamic.d.gens.size() == 2);
    m.verify(); }

  // Held under a plain or DISCARD lock, a draw keeps its bytes even when the
  // application rewrites them before unlocking: every store renames then.
  { reset_counters(); Model m(4096);
    m.ib.lockWrite(D3DLOCK_DISCARD);
    std::memset(m.mirror.data(), 1, 256); m.draw(0, 256);
    std::memset(m.mirror.data(), 2, 256); m.draw(0, 256);
    std::memset(m.mirror.data(), 3, 256);
    m.ib.unlock();
    m.draw(0, 256); m.draw(0, 256);
    assert(g_rename_calls == 3 && g_stored == 3 * 256);
    m.verify(); }

  // A plain lock (what every lock outside the DEFAULT pool becomes) renames once.
  { reset_counters(); Model m(4096);
    m.ib.lockWrite(0); m.ib.unlock(); m.draw(0, 100); m.draw(100, 200);
    assert(g_rename_calls == 1);
    m.verify(); }

  // A static buffer drawn piece by piece is stored once, then left alone.
  { reset_counters(); Model m(8192);
    m.ib.lockWrite(0); m.ib.unlock();
    for (UINT i = 0; i < 8; ++i) m.draw(i * 1024, (i + 1) * 1024);
    assert(g_stored == 8192 && !m.ib.m_dirty);
    for (UINT i = 0; i < 8; ++i) m.draw(i * 1024, (i + 1) * 1024);
    assert(g_stored == 8192 && g_rename_calls == 1);
    m.verify(); }

  // A gap no larger than the new range is stored with it, so the current
  // bytes stay one interval; a far range does not drag the gap in.
  { reset_counters(); Model m(65536);
    m.ib.lockWrite(0); m.ib.unlock();
    m.draw(0, 1000); m.draw(1500, 2500); assert(g_stored == 2500);
    m.draw(60000, 60100); assert(g_stored == 2600);
    m.verify(); }

  // Empty and out-of-range draws store nothing; a direct-mapped or clean buffer neither.
  { reset_counters(); Model m(4096);
    m.ib.lockWrite(D3DLOCK_NOOVERWRITE); m.ib.unlock();
    m.draw(100, 100); m.draw(5000, 6000); assert(g_store_calls == 0);
    m.ib.m_direct = true; m.draw(0, 64); assert(g_store_calls == 0);
    m.ib.m_direct = false; m.ib.m_dirty = false; m.draw(0, 64); assert(g_store_calls == 0); }

  // Out of video memory: refreshWholeMirror's order. Wait for the GPU and try
  // again; a second failure stores into the current generation (GPU idle); a
  // failed wait skips the store and keeps the rename due.
  { reset_counters(); Model m(4096);
    m.ib.lockWrite(0); m.ib.unlock();
    g_rename_failures = 1; m.draw(0, 64);
    assert(g_drains == 1 && g_rename_calls == 2 && m.ib.m_dynamic.d.gens.size() == 2 && g_in_place == 0);
    m.verify(); }
  { reset_counters(); Model m(4096);
    m.ib.lockWrite(0); m.ib.unlock();
    g_rename_failures = 2; m.draw(0, 64);
    assert(g_drains == 1 && g_in_place == 1 && m.ib.m_dynamic.d.gens.size() == 1 && g_stored == 64);
    m.verify(); }
  { reset_counters(); Model m(4096);
    m.ib.lockWrite(0); m.ib.unlock();
    g_rename_failures = 1; g_drain_ok = false; m.draw(0, 64);
    assert(g_drains == 1 && g_store_calls == 0 && m.ib.m_renameDue && g_warns == 1);
    // The skipped draw read stale contents, as refreshWholeMirror's would; the next one is current.
    g_drain_ok = true; m.draw(0, 64);
    assert(g_stored == 64 && !m.ib.m_renameDue);
    auto &last = m.draws.back();
    assert(std::equal(last.want.begin(), last.want.end(), m.ib.m_dynamic.d.gens[last.gen]->bytes.begin())); }
  std::puts("ok");
}
'''

OFF_MAIN = r'''
int main() {
  g_env = "0";
  std::vector<uint8_t> mirror(4096, 1);
  MTLD3D9IndexBuffer ib(mirror);
  ib.lockWrite(D3DLOCK_NOOVERWRITE); ib.unlock();
  ib.refreshRange(0, 64); ib.refreshRange(0, 0);
  assert(ib.whole == 2 && g_store_calls == 0);
  std::puts("ok");
}
'''


def extract(source, head):
    start = source.index(head)
    return source[start:source.index('\n}\n', start) + 3]


def lock_block(source):
    start = source.index('MTLD3D9IndexBuffer::Lock(UINT OffsetToLock')
    begin = source.index('  if (buffer_lock_updates_dirty(Flags)) {', start)
    end = source.index('\n  }\n', source.index('m_renameEachStore = true;', begin)) + 5
    return source[begin:end]


def unlock_block(source):
    start = source.index('MTLD3D9IndexBuffer::Unlock() {')
    begin = source.index('  if (m_lockCount.decrement() == 0) {', start)
    return source[begin:source.index('\n  }\n', begin) + 5]


def compile_and_run(folder, name, text):
    src = folder / (name + '.cpp')
    src.write_text(text)
    cxx = shutil.which('c++') or shutil.which('clang++') or shutil.which('g++')
    flags = ['-std=c++20', '-O1', '-g', '-Wall', '-Wextra', '-Werror']
    if sys.platform != 'win32':
        flags += ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    build = subprocess.run([cxx, *flags, str(src), '-o', str(folder / name)], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stdout + build.stderr)
        return False
    run = subprocess.run([str(folder / name)], capture_output=True, text=True)
    if run.returncode != 0:
        print(run.stdout + run.stderr)
    return run.returncode == 0 and run.stdout.strip() == 'ok'


dxmt = root / 'dxmt'
if not (dxmt / 'src/d3d9/d3d9_buffer.cpp').exists() or not shutil.which('git'):
    print('SKIP: dxmt submodule not checked out, patch not applied or run')
else:
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / 'dxmt'
        subprocess.run(['git', 'worktree', 'add', '--detach', '-q', str(work), 'HEAD'], cwd=dxmt, check=True)
        try:
            ok = True
            for p in sorted(patches.glob('*.patch')):
                if subprocess.run(['git', 'apply', '--reverse', '--check', str(p)], cwd=work,
                                  capture_output=True).returncode == 0:
                    continue
                r = subprocess.run(['git', 'apply', str(p)], cwd=work, capture_output=True, text=True)
                if r.returncode != 0:
                    print(r.stderr)
                    ok = False
                    break
            check(ok, 'every dxmt patch applies in order on the pinned dxmt')
            if ok:
                source = (work / 'src/d3d9/d3d9_buffer.cpp').read_text(encoding='utf-8')
                helpers_start = source.index('bool\nindexRangeEnabled() {')
                helpers = source[helpers_start:source.index('IndexRangeStats g_indexRangeStats;\n') +
                                 len('IndexRangeStats g_indexRangeStats;\n')]
                body = (helpers + '\n' +
                        extract(source, 'bool\nMTLD3D9IndexBuffer::renameBeforeStore() {') + '\n' +
                        extract(source, 'void\nMTLD3D9IndexBuffer::refreshRange(UINT begin, UINT end) {') + '\n' +
                        'void\nMTLD3D9IndexBuffer::lockWrite(DWORD Flags) {\n' + lock_block(source) +
                        '  m_lockCount.increment();\n}\n' +
                        'void\nMTLD3D9IndexBuffer::unlock() {\n' + unlock_block(source) + '}\n')
                # The pinned file from git: the build may have patched the checkout already.
                pinned = subprocess.run(['git', 'show', 'HEAD:src/d3d9/d3d9_buffer.cpp'], cwd=dxmt, check=True,
                                        capture_output=True, text=True).stdout
                for name in ['MTLD3D9VertexBuffer', 'MTLD3D9IndexBuffer']:
                    head = 'void\n' + name + '::refreshWholeMirror() {'
                    check(extract(source, head) == extract(pinned, head), name + '::refreshWholeMirror is unchanged')
                folder = Path(tmp)
                check(compile_and_run(folder, 'range', FIXTURE_HEAD + body + FIXTURE_TAIL),
                      'every recorded draw reads the bytes it was recorded with; stores stay per draw')
                check(compile_and_run(folder, 'off', FIXTURE_HEAD + body + OFF_MAIN),
                      'MADEIRA_D3D9_INDEX_RANGE=0 refreshes the whole buffer instead')
        finally:
            subprocess.run(['git', 'worktree', 'remove', '--force', str(work)], cwd=dxmt, capture_output=True)

print('PASS' if failures == 0 else 'FAILED (%d)' % failures)
sys.exit(1 if failures else 0)
