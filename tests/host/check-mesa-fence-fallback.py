#!/usr/bin/env python3
"""Mesa's D3D12 screen falls back to a local fence only when shared fences are unsupported.

build/mesa-d3d12/patches/optional-shared-fence.patch: madeira_d3d12 answers
CreateFence(D3D12_FENCE_FLAG_SHARED) with E_NOTIMPL, and Mesa used to fail the
whole screen. Compiles the patched d3d12_init_screen_fence from the tree that
build/mesa-d3d12/build.sh extracted and runs it against a model device:
E_NOTIMPL and DXGI_ERROR_UNSUPPORTED give a local fence with external fence and
timeline semaphore support off; every other error still fails.
Needs clang++ (AddressSanitizer/UBSan). SKIP when the Mesa tree is not built.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
screen = root / "build/mesa-d3d12/work/mesa-26.2.4/src/gallium/drivers/d3d12/d3d12_screen.cpp"
if not screen.exists():
    print("SKIP: run build/mesa-d3d12/build.sh first")
    sys.exit(0)
source = screen.read_text()
start = source.index("static bool\nd3d12_init_screen_fence(")
end = source.index("\nbool\nd3d12_init_screen(", start)
helper = source[start:end]
harness = r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
using HRESULT = int32_t;
constexpr HRESULT E_NOTIMPL = (HRESULT)0x80004001;
constexpr HRESULT DXGI_ERROR_UNSUPPORTED = (HRESULT)0x887a0004;
constexpr HRESULT E_OUTOFMEMORY = (HRESULT)0x8007000e;
constexpr HRESULT E_INVALIDARG = (HRESULT)0x80070057;
constexpr HRESULT DXGI_ERROR_DEVICE_REMOVED = (HRESULT)0x887a0005;
#define SUCCEEDED(hr) ((hr) >= 0)
#define IID_PPV_ARGS(p) (p)
#define debug_printf(...) ((void)0)
enum { D3D12_FENCE_FLAG_NONE, D3D12_FENCE_FLAG_SHARED };
struct Fence {} fence;
struct Device {
  HRESULT shared_result, local_result;
  int calls = 0;
  HRESULT CreateFence(uint64_t initial, int flags, Fence **out) {
    assert(initial == 0);
    assert(flags == (calls == 0 ? D3D12_FENCE_FLAG_SHARED : D3D12_FENCE_FLAG_NONE));
    assert(calls < 2);
    ++calls;
    HRESULT result = flags ? shared_result : local_result;
    *out = SUCCEEDED(result) ? &::fence : nullptr;
    return result;
  }
};
struct d3d12_screen {
  Device *dev;
  Fence *fence;
  bool shared_fences_supported;
};
'''
cases = r'''
void check(HRESULT shared, HRESULT local, bool succeeds, bool shareable, int calls) {
  Device dev{shared, local};
  d3d12_screen screen{&dev, nullptr, true};
  assert(d3d12_init_screen_fence(&screen) == succeeds);
  assert(screen.shared_fences_supported == shareable);
  assert((screen.fence != nullptr) == succeeds);
  assert(dev.calls == calls);
}
int main() {
  check(0, E_OUTOFMEMORY, true, true, 1);
  check(E_NOTIMPL, 0, true, false, 2);
  check(DXGI_ERROR_UNSUPPORTED, 0, true, false, 2);
  check(E_OUTOFMEMORY, 0, false, false, 1);
  check(E_INVALIDARG, 0, false, false, 1);
  check(DXGI_ERROR_DEVICE_REMOVED, 0, false, false, 1);
  check(E_NOTIMPL, E_OUTOFMEMORY, false, false, 2);
  check(DXGI_ERROR_UNSUPPORTED, DXGI_ERROR_DEVICE_REMOVED, false, false, 2);
  puts("PASS: shared/local fences, capability state, and failure propagation (8 cases)");
}
'''
with tempfile.TemporaryDirectory() as tmp:
    cpp, exe = Path(tmp) / "test.cpp", Path(tmp) / "test"
    cpp.write_text(harness + helper + cases)
    subprocess.run(["clang++", "-std=c++17", "-fsanitize=address,undefined",
                    "-Wall", "-Wextra", "-Werror", str(cpp), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
