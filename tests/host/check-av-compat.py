#!/usr/bin/env python3
"""Run the patched FEX/DXMT policies and the Wine parser policy on the host."""

import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]


def patched_source(module, name, patch):
    # Use the pinned file, even when a local runtime build has applied the patch.
    source = subprocess.check_output(
        ["git", "-C", str(root / module), "show", "HEAD:" + name]
    )
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / name
        path.parent.mkdir(parents=True)
        path.write_bytes(source)
        subprocess.run(["git", "apply", str(root / patch)], cwd=temp, check=True)
        return path.read_text()


def section(text, start, stop):
    first = text.index(start)
    return text[first:text.index(stop, first)]


fex = patched_source(
    "FEX", "Source/Windows/Common/CPUFeatures.cpp",
    "build/fex-patches/0002-ios-arm64ec-independent-denormals.patch",
)
fex = section(fex, '    const char* Probe = getenv("FEX_MADEIRA_HOSTPROBE");\n    const auto Has',
              '    LogMan::Msg::IFmt("FEX: ml1231')
fex = fex.replace("    FEX_CONFIG_OPT(HostFeaturesOverride, HOSTFEATURES);\n", "")
dxmt = patched_source(
    "dxmt", "src/d3d11/d3d11.cpp",
    "build/dxmt-patches/0002-d3d11-video-device-fallback.patch",
)
dxmt = section(dxmt, "  if (Flags & D3D11_CREATE_DEVICE_VIDEO_SUPPORT)", "  Com<IMTLDXGIAdapter>")
wine = (root / "build/ntdll-unix/winegstreamer_unixlib_ios.c").read_text()
formats = section(wine, "static BOOL wg_cpu_video_requested", "static pthread_once_t wgp_config_once")
parser = section(wine, "static NTSTATUS wgp_create64(", "/* The index layout below")

preamble = r'''
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <strings.h>
#include <cstdint>
#include <string>
using std::getenv;
using BOOL = bool;
using NTSTATUS = int;
constexpr int STATUS_NOT_IMPLEMENTED = -1;
static NTSTATUS wgp_create(void *) { return 123; }
enum mav_pixel_format {
    MAV_PIX_NV12, MAV_PIX_I420, MAV_PIX_YV12, MAV_PIX_YUY2,
    MAV_PIX_BGRx, MAV_PIX_BGRA, MAV_PIX_RGBA
};
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define mav_log(...) do {} while (0)
namespace FEXCore::Config {
    enum HostFeatures { ENABLEAFP = 1, DISABLEAFP = 2, DISABLELRCPC2 = 4 };
}
namespace env {
    static std::string getEnvVar(const char *name) {
        const char *value = getenv(name);
        return value ? value : "";
    }
}
constexpr unsigned D3D11_CREATE_DEVICE_VIDEO_SUPPORT = 0x800;
constexpr int DXGI_ERROR_UNSUPPORTED = -1;
static bool use_afp(uint64_t config) {
    auto HostFeaturesOverride = [config] { return config; };
    struct { bool SupportsTSOImm9, SupportsAFP; } HostFeatures = {};
'''
checks = r'''
static void setting(const char *key, const char *value) {
    if (value) assert(setenv(key, value, 1) == 0);
    else assert(unsetenv(key) == 0);
}
int main() {
    using namespace FEXCore::Config;
    const char *denormals = "MADEIRA_FEX_INDEPENDENT_DENORMALS";
    const char *probe = "FEX_MADEIRA_HOSTPROBE";
    setting(denormals, nullptr);
    setting(probe, "AFP=1,FLAGM=1");
    assert(!use_afp(0));
    setting(denormals, "1");
    assert(use_afp(0));
    assert(!use_afp(DISABLEAFP));
    const char *missing_probes[] = {"AFP=0", "AFP=?", "LRCPC2=1", "OTHERAFP=1", nullptr};
    for (const char *missing : missing_probes) {
        setting(probe, missing);
        assert(!use_afp(0));
    }
    setting(probe, "AFP=0");
    assert(!use_afp(ENABLEAFP));
    setting(probe, "AFP=?");
    assert(use_afp(ENABLEAFP)); // preserve the existing explicit expert override

    const char *cpu = "MADEIRA_MF_CPU_VIDEO";
    const char *format = "MADEIRA_WG_VIDEO_FORMAT";
    const char *parser = "MADEIRA_WG_64BIT";
    const char *device = "MADEIRA_D3D11_NO_VIDEO_DEVICE";
    constexpr unsigned video = D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
    setting(cpu, nullptr);
    setting(format, nullptr);
    setting(parser, nullptr);
    setting(device, nullptr);
    assert(wg_video_native_format() == MAV_PIX_NV12);
    assert(wgp_create64(nullptr) == STATUS_NOT_IMPLEMENTED);
    assert(create_device(video) == 0);

    setting(cpu, "1");
    assert(wg_video_native_format() == MAV_PIX_BGRA);
    assert(wgp_create64(nullptr) == 123);
    assert(create_device(video) == DXGI_ERROR_UNSUPPORTED);
    assert(create_device(0) == 0 && create_device(0x20) == 0);

    setting(format, "nv12");
    setting(parser, "0");
    setting(device, "0");
    assert(wg_video_native_format() == MAV_PIX_NV12);
    assert(wgp_create64(nullptr) == STATUS_NOT_IMPLEMENTED);
    assert(create_device(video) == 0);

    setting(cpu, "0");
    setting(format, "argb32");
    setting(parser, "1");
    setting(device, "1");
    assert(wg_video_native_format() == MAV_PIX_BGRA);
    assert(wgp_create64(nullptr) == 123);
    assert(create_device(video) == DXGI_ERROR_UNSUPPORTED && create_device(0) == 0);
}
'''
with tempfile.TemporaryDirectory() as temp:
    source = Path(temp) / "policies.cpp"
    binary = Path(temp) / "policies"
    source.write_text(preamble + fex + '''
    return HostFeatures.SupportsAFP;
}
static int create_device(unsigned Flags) {
''' + dxmt + "  return 0;\n}\n" + formats + parser + checks)
    subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("AFP host gating and Media Foundation opt-in/override checks passed")
