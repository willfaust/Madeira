#!/usr/bin/env python3
"""The D3D9 device lock word and FEX's split CAS, from production source; no Wine, FEX JIT or device runs.

The D3D9 device lock that 32-bit programs contend on can sit misaligned across a
16-byte boundary, so every LOCK CMPXCHG / LOCK XADD on it takes FEX's split CAS
path. That path is upstream FEX's, unchanged: there is no split-lock rollback
(it could leave values no thread wrote), and 32-bit correctness comes from
StrictInProcessSplitLocks, which the WOW64 module turns on by default.

1. The device-lock diagnostics' switches and log tag are present in the imported
   frontend and in the i386 shim (dxmt, willfaust/dxmt#2).
2. FEX's Arm64.cpp has no rollback path, and the WOW64 module applies the
   StrictInProcessSplitLocks default before the context reads its config.
3. FEXCore's DoCAS16/32/64, extracted verbatim, handle the device-word shape
   (a dword at offset 14 of a 16-byte line) and the 64/16-bit split shapes, and
   4 threads x 20000 split LOCK XADD under the strict split-lock mutex keep an
   exact count.
"""
from pathlib import Path
import subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
d9 = (root / "dxmt/src/d3d9/d3d9_multithread.hpp").read_text()
shim = (root / "dxmt/src/d3d9shim/d3d9shim_lock.c").read_text()
arm = (root / "FEX/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp").read_text()
wow = (root / "FEX/Source/Windows/WOW64/Module.cpp").read_text()


def function(source, start):
    a = source.index(start)
    b = source.index("{", a)
    depth, c = 1, b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}")
        c += 1
    return source[a:c]


# ---- 1. D3D9 device-lock diagnostics ----------------------------------------
for text, needles in [
    (d9, ["MADEIRA_D9_LOCK_DIAG", "MADEIRA_D9_LOCK_BACKOFF", "[d3d9-lock-spin]"]),
    (shim, ["MADEIRA_D9_LOCK_DIAG", "MADEIRA_D9_LOCK_BACKOFF", "[d3d9-lock-spin]"]),
]:
    for n in needles:
        assert n in text, f"missing {n!r}"

# ---- 2. no rollback; strict split locks on for 32-bit -----------------------
for gone in ["SplitCASRollback", "MADEIRA_SPLITLOCK_ROLLBACK"]:
    assert gone not in arm, f"{gone} must not exist: the split-lock rollback was dropped"
assert 'CONFIG_STRICTINPROCESSSPLITLOCKS, "1"' in wow, "WOW64 module must default StrictInProcessSplitLocks on"
assert wow.index('CONFIG_STRICTINPROCESSSPLITLOCKS, "1"') < wow.index("Context::CreateNewContext("), \
    "strict split-lock default applied after the context read its config"
print("PASS: device-lock switches present; no split-lock rollback; WOW64 strict split locks default on")

# ---- 3. upstream split CAS on the device-word shape ----------------------------
pieces = [
    function(arm, "static uint64_t LoadAcquire64("),
    function(arm, "static bool StoreCAS64("),
    function(arm, "static uint32_t LoadAcquire32("),
    function(arm, "static bool StoreCAS32("),
    function(arm, "static uint8_t LoadAcquire8("),
    function(arm, "static bool StoreCAS8("),
    "template<typename T>\nusing CASExpectedFn = T (*)(T Src, T Expected);\ntemplate<typename T>\nusing CASDesiredFn = T (*)(T Src, T Desired);\n",
    "template<bool Retry>\n" + function(arm, "static uint16_t DoCAS16("),
    "template<bool Retry>\n" + function(arm, "static uint32_t DoCAS32("),
    "template<bool Retry>\n" + function(arm, "static uint64_t DoCAS64("),
]
code = r"""
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <optional>
#include <thread>
#include <vector>
#define FEXCORE_TELEMETRY_SET(a, b) do {} while (0)
namespace FEXCore::Utils::SpinWaitLock {
template<typename T> struct UniqueSpinMutex {
  T* M;
  explicit UniqueSpinMutex(T* m) : M(m) { T z = 0; auto a = std::atomic_ref<T>(*M); while (!a.compare_exchange_weak(z, 1)) { z = 0; } }
  ~UniqueSpinMutex() { std::atomic_ref<T>(*M).store(0); }
};
}
""" + "\n".join(pieces) + r"""
static uint32_t ExpId32(uint32_t, uint32_t E) { return E; }
static uint32_t DesId32(uint32_t, uint32_t D) { return D; }
static uint32_t Nop32(uint32_t S, uint32_t) { return S; }
static uint32_t Add32(uint32_t S, uint32_t D) { return S + D; }
static uint64_t ExpId64(uint64_t, uint64_t E) { return E; }
static uint64_t DesId64(uint64_t, uint64_t D) { return D; }
static uint16_t ExpId16(uint16_t, uint16_t E) { return E; }
static uint16_t DesId16(uint16_t, uint16_t D) { return D; }
alignas(64) static uint8_t buf[64];
static uint32_t rd32(int off) { uint32_t v; memcpy(&v, buf + off, 4); return v; }
static uint64_t rd64(int off) { uint64_t v; memcpy(&v, buf + off, 8); return v; }
int main() {
  uint32_t strict = 0;
  // (a) LOCK CMPXCHG on the device word: dword at offset 14, crossing 16. -1 -> 0.
  memset(buf, 0, sizeof buf); buf[12] = 0x11; buf[13] = 0x22; buf[18] = 0x33; buf[19] = 0x44;
  uint32_t m1 = 0xffffffffu; memcpy(buf + 14, &m1, 4);
  uint32_t r = DoCAS32<false>(0, 0xffffffffu, reinterpret_cast<uint64_t>(buf + 14), ExpId32, DesId32, &strict);
  assert(r == 0xffffffffu && rd32(14) == 0);
  assert(buf[12] == 0x11 && buf[13] == 0x22 && buf[18] == 0x33 && buf[19] == 0x44);   // neighbours untouched
  // a failing compare reports the current value and stores nothing
  r = DoCAS32<false>(5, 0x12345678u, reinterpret_cast<uint64_t>(buf + 14), ExpId32, DesId32, &strict);
  assert(r == 0 && rd32(14) == 0);
  // (b) LOCK XADD across the boundary: 0x0000ffff + 1 carries into the upper half.
  uint32_t v = 0x0000ffffu; memcpy(buf + 14, &v, 4);
  r = DoCAS32<true>(1, 0, reinterpret_cast<uint64_t>(buf + 14), Nop32, Add32, &strict);
  assert(r == 0x0000ffffu && rd32(14) == 0x00010000u);
  // (c) 64-bit at offset 12 and 16-bit at offset 15.
  memset(buf, 0, sizeof buf); uint64_t q = ~0ull; memcpy(buf + 12, &q, 8);
  uint64_t r64 = DoCAS64<false>(0x0123456789abcdefull, ~0ull, reinterpret_cast<uint64_t>(buf + 12), ExpId64, DesId64, &strict);
  assert(r64 == ~0ull && rd64(12) == 0x0123456789abcdefull);
  memset(buf, 0, sizeof buf); buf[15] = 0xff; buf[16] = 0xff;
  uint16_t r16 = DoCAS16<false>(0x1234, 0xffff, reinterpret_cast<uint64_t>(buf + 15), ExpId16, DesId16, &strict);
  assert(r16 == 0xffff && buf[15] == 0x34 && buf[16] == 0x12);
  // (d) contention: 4 threads x 20000 split LOCK XADD on the device word, strict mutex on.
  memset(buf, 0, sizeof buf); strict = 0;
  std::vector<std::thread> t;
  for (int i = 0; i < 4; i++) t.emplace_back([&] { for (int k = 0; k < 20000; k++)
      DoCAS32<true>(1, 0, reinterpret_cast<uint64_t>(buf + 14), Nop32, Add32, &strict); });
  for (auto& x : t) x.join();
  assert(rd32(14) == 80000u);
  assert(buf[12] == 0 && buf[13] == 0 && buf[18] == 0 && buf[19] == 0);
  puts("PASS: upstream split CAS on the device-word shape; 4x20000 split XADD exact under the strict split-lock mutex");
  return 0;
}
"""

with tempfile.TemporaryDirectory() as tmp:
    t = Path(tmp)
    (t / "cas.cpp").write_text(code)
    subprocess.run(["c++", "-std=c++20", "-O1", "-g", "-pthread", "-fsanitize=address,undefined",
                    "-o", str(t / "cas"), str(t / "cas.cpp")] +
                   (["-latomic"] if sys.platform != "darwin" else []), check=True)
    subprocess.run([str(t / "cas")], check=True)
print("PASS: D3D9 device lock / split-lock checks")
