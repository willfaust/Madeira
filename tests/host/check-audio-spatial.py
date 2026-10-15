#!/usr/bin/env python3
"""MADEIRA_AUDIO_SPATIAL=0 in the iOS audio driver (build/ntdll-unix/audio_null_ios.c); no Wine runs.

Compiles ios_audio_spatial_off, ios_audio_is_spatial_probe and ios_is_format_supported against
stubs. With the switch, exactly the probe Wine's SpatialAudioClient_Create makes (shared render,
WAVE_FORMAT_IEEE_FLOAT, mono, 48 kHz, 32-bit) gets AUDCLNT_E_UNSUPPORTED_FORMAT, so no
ISpatialAudioClient is made and the game renders through a plain stream; every other format is
accepted as before, and without the switch the probe is accepted too. create_stream is untouched.
"""
from pathlib import Path
import os, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/audio_null_ios.c").read_text()
bad = 0

def check(what, ok):
    global bad
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        bad = 1

def body(start):
    a = src.index(start)
    return src[a:src.index("\n}\n", a) + 3]

fmt = src[src.index("struct WAVEFORMATEX_stub {"):src.index("};", src.index("struct WAVEFORMATEX_stub {")) + 2]
params = src[src.index("struct is_format_supported_params {"):src.index("};", src.index("struct is_format_supported_params {")) + 2]
harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef uint16_t WORD; typedef uint32_t DWORD, UINT32; typedef int32_t HRESULT; typedef int NTSTATUS; typedef int EDataFlow;
#define eRender 0
#define eCapture 1
#define S_OK 0
#define STATUS_SUCCESS 0
#define LOG_FN_CALL(n, s) do { } while (0)
""" + fmt + "\n" + params + "\n" + body("static int ios_audio_spatial_off(void)") + \
    body("static int ios_audio_is_spatial_probe(const struct is_format_supported_params *p)") + \
    body("static NTSTATUS ios_is_format_supported(void *args) {") + r"""
static HRESULT ask(int flow, int share, WORD tag, WORD ch, DWORD rate, WORD bits) {
    struct WAVEFORMATEX_stub f = { tag, ch, rate, 0, 0, bits, 0 };
    struct is_format_supported_params p = { "dev", flow, share, &f, 12345 };
    ios_is_format_supported(&p);
    return p.result;
}
int main(void) {
    printf("%d %d %d %d %d %d %d\n",
           ask(eRender, 0, 3, 1, 48000, 32),        /* the spatial probe */
           ask(eRender, 0, 0xfffe, 2, 48000, 32),   /* a game's plain stereo stream */
           ask(eRender, 0, 0xfffe, 12, 48000, 32),  /* a 7.1.4 stream */
           ask(eRender, 0, 3, 1, 44100, 32),        /* mono float at another rate */
           ask(eRender, 1, 3, 1, 48000, 32),        /* exclusive mode */
           ask(eCapture, 0, 3, 1, 48000, 32),       /* capture */
           ask(eRender, 0, 1, 1, 48000, 16));       /* mono PCM */
    return 0;
}
"""
REFUSED = str(0x88890008 - (1 << 32))
with tempfile.TemporaryDirectory() as d:
    c = os.path.join(d, "t.c"); exe = os.path.join(d, "t")
    Path(c).write_text(harness)
    r = subprocess.run(["cc", "-std=c11", "-Wall", "-Werror", "-o", exe, c], capture_output=True, text=True)
    check("the switch, the probe test and is_format_supported compile on their own", r.returncode == 0)
    if r.returncode:
        print(r.stderr)
    else:
        for val, want in ((None, ["0"] * 7), ("1", ["0"] * 7), ("00", ["0"] * 7),
                          ("0", [REFUSED] + ["0"] * 6)):
            env = dict(os.environ)
            env.pop("MADEIRA_AUDIO_SPATIAL", None)
            if val is not None:
                env["MADEIRA_AUDIO_SPATIAL"] = val
            out = subprocess.run([exe], capture_output=True, text=True, env=env)
            got = out.stdout.split()
            check("MADEIRA_AUDIO_SPATIAL=%s: %s" % (val, "only the spatial probe is refused" if val == "0" else "everything accepted"),
                  got == want)
            if val == "0":
                check("  ...said once, and the refusal is logged",
                      "spatial audio is left out" in out.stderr and "refused spatial audio's mono-float probe" in out.stderr)

create = body("static NTSTATUS ios_create_stream(void *args) {")
check("create_stream refuses nothing (build 533's 12-channel refusal is gone)",
      "0x88890008" not in create and "MADEIRA_AUDIO_MAX_CHANNELS" not in src)
catalog = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
check("settings catalog lists env.MADEIRA_AUDIO_SPATIAL, not the old key",
      'ConfigOption(key: "env.MADEIRA_AUDIO_SPATIAL"' in catalog and "MADEIRA_AUDIO_MAX_CHANNELS" not in catalog)
print("FAILED" if bad else "PASS: audio spatial switch")
sys.exit(bad)
