#!/usr/bin/env python3
"""ml1490 D3D9 upload-ring bound (DXMT); no Wine, Metal or guest runs.

Device log 185: while a 32-bit D3D9 title loaded, DXMT's census showed the staging ring at
955 MB live in 83 blocks with 3 frees, and the process pinned at its memory ceiling. Texture
uploads stage into m_uploadRing, and a block is recycled only after the command buffer that
reads it retires; a loading screen uploads for a long time without Present, so nothing
retired. Part A runs the production RingBumpState (extracted from
dxmt_ring_bump_allocator.hpp, with a counting allocator) through that loading pattern, with
and without the ml1490 settle policy. Part B checks the source invariants of the policy.
"""
from pathlib import Path
import re, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
dx = root / "research/dxmt/src"
ring = (dx / "dxmt/dxmt_ring_bump_allocator.hpp").read_text()

# Part A: the real ring template with a counting allocator.
body = ring[ring.index("#if defined(__i386__) && !defined(DXMT_MADEIRA)\nconstexpr size_t kStagingBlockSize"):]
body = body[:body.index("class GpuPrivateBufferBlockAllocator")] + \
    body[body.index("template <typename Allocator, size_t BlockSize, class mutex>\nstd::pair"):]
body = body.replace("} // namespace dxmt", "")
harness = r"""
#include <cstdint>
#include <cstdio>
#include <cstddef>
#include <mutex>
#include <queue>
#include <string>
#include <utility>
#include <algorithm>
#define WARN(...) do {} while (0)
namespace dxmt {
namespace env { inline std::string getEnvVar(const char *) { return ""; } }
using mutex = std::mutex;
inline uint64_t align(uint64_t v, uint64_t a) { return (v + a - 1) & ~(a - 1); }
""" + body + r"""
struct CountingAllocator {
  static inline uint64_t live = 0, peak = 0, made = 0;
  struct Block {
    uint64_t size = 0;
    Block() = default;
    Block(const Block &) = delete;
    Block(Block &&m) : size(m.size) { m.size = 0; }
    ~Block() { live -= size; }
  };
  Block allocate(size_t n) { Block b; b.size = n; live += n; made++; peak = std::max(peak, live); return b; }
};
}
using namespace dxmt;
// One loading screen: 900 uploads of 1.2 MB (about 1 GB) with no Present in between.
static uint64_t run(bool settle) {
  CountingAllocator::live = CountingAllocator::peak = CountingAllocator::made = 0;
  {
    RingBumpState<CountingAllocator> ring{CountingAllocator{}};
    uint64_t seq = 1, coherent = 0, staged = 0, commit_signal = 0;
    const uint64_t threshold = 64ull << 20;
    for (int i = 0; i < 900; i++) {
      const size_t bytes = 1200 * 1024;
      ring.allocate(seq, coherent, bytes, 16);
      staged += bytes;
      if (settle && staged >= threshold) {
        // settleUploadPressure: wait for the previous commit's copies, then commit this one.
        if (commit_signal) coherent = std::max(coherent, commit_signal);
        ring.seal_latest();          // commitCurrentChunkTimed seals m_uploadRing
        seq += 1;                    // FlushDrawBatch
        commit_signal = seq;         // emitCmdbufTailSignal signals this value ...
        seq += 1;                    // ... then bumps the sequence
        ring.free_blocks(coherent);
        staged = 0;
      }
    }
  }
  return CountingAllocator::peak;
}
int main() {
  const uint64_t before = run(false), after = run(true);
  std::printf("ring peak: without settle %llu MB, with settle %llu MB\n",
              (unsigned long long)(before >> 20), (unsigned long long)(after >> 20));
  if (before < (900ull << 20)) { std::printf("FAIL: the unsettled ring should hold the whole load\n"); return 1; }
  if (after > (224ull << 20)) { std::printf("FAIL: the settled ring should stay near two thresholds\n"); return 1; }
  return 0;
}
"""
with tempfile.TemporaryDirectory() as t:
    src = Path(t) / "ring.cpp"; src.write_text(harness)
    exe = Path(t) / "ring"
    subprocess.run(["g++", "-std=c++20", "-O1", "-Wall", "-fsanitize=address,undefined", str(src), "-o", str(exe)], check=True)
    out = subprocess.run([str(exe)], capture_output=True, text=True)
    print(out.stdout, end="")
    assert out.returncode == 0, out.stdout + out.stderr
print("PASS: the production ring grows with an unsubmitted load and stays bounded when settled")

# Part B: source invariants.
dev = (dx / "d3d9/d3d9_device.cpp").read_text()
hpp = (dx / "d3d9/d3d9_device.hpp").read_text()
surf = (dx / "d3d9/d3d9_surface.cpp").read_text()
tex = (dx / "d3d9/d3d9_texture.cpp").read_text()
init = (dx / "dxmt/dxmt_resource_initializer.cpp").read_text()


def function(source, start):
    i = source.index(start); b = source.index("{", i); depth = 1; k = b + 1
    while depth:
        depth += (source[k] == "{") - (source[k] == "}"); k += 1
    return source[i:k]


settle = function(dev, "MTLD3D9Device::settleUploadPressure() {")
assert 'getEnvVar("DXMT_D9_UPLOAD_COMMIT_MB")' in settle and "if (!threshold ||" in settle, "switch and threshold"
assert settle.index("waitForGpuOrDeviceError(m_uploadCommitSignal)") < settle.index("forceFlushAndCommit();") \
    < settle.index("m_uploadCommitSignal = m_currentCmdSeq - 1;"), "wait for the previous commit, commit, remember its signal"
assert "m_uploadRing.free_blocks(" in settle and "[d9-upload-commit] ml1490" in settle, "trim and log"
stage = function(dev, "MTLD3D9Device::stageTextureUpload(")
assert stage.rstrip().endswith("noteUploadBytes(total_bytes);\n}"), "only a staged upload is counted"
assert "settleUploadPressure" not in stage, "never settled inside the staging call itself"
commit = function(dev, "MTLD3D9Device::commitCurrentChunkTimed(unsigned reason) {")
assert commit.index("m_dxmtQueue->CommitCurrentChunk();") < commit.index("m_uploadedBytesSinceCommit = 0;"), "any commit resets the count"
unlock = function(surf, "MTLD3D9Surface::UnlockRect() {")
assert unlock.rstrip().endswith("m_device->settleUploadPressure();\n  return D3D_OK;\n}"), "settled at the end of Unlock"
for name in ["MTLD3D9Device::UpdateTexture(", "MTLD3D9Device::UpdateSurface("]:
    f = function(dev, name)
    assert f.index("LockDevice();") < f.index("settleUploadPressure();") < f.index("return D3DERR_INVALIDCALL"), name
draw = dev[dev.index("if (m_renamedBytesSinceCommit >= kRenameBytesBeforeImplicitCommit)\n    forceFlushAndCommit();"):]
assert draw.index("settleUploadPressure();") < draw.index("MTLD3D9Device::QueueBlitOp("), "settled on the draw boundary"
assert "settleUploadPressure" not in function(tex, "MTLD3D9Texture::sweepManagedUpload() {"), "never inside the pre-draw sweep"
assert "void settleUploadPressure();" in hpp and "m_uploadedBytesSinceCommit = 0;" in hpp

zero = function(init, "ResourceInitializer::allocateZeroBuffer(size_t size) {")
assert 'getEnvVar("DXMT_ZERO_BUFFER_POW2")' in zero and "length <<= 1;" in zero, "power-of-two growth behind a switch"
assert zero.index("mem_census_sub(MEMOWN_INIT_UPLOAD, zero_buffer_census_)") < zero.index("zero_buffer_ = device_.newBuffer"), \
    "the replaced buffer leaves the census"
print("PASS: settle points are API and draw boundaries only, commits reset the count, zero buffer grows by powers of two")
