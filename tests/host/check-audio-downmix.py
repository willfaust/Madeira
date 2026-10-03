#!/usr/bin/env python3
"""Channel downmix of the iOS audio driver (build/ntdll-unix/audio_null_ios.c); no Wine runs.

Compiles the production struct ios_stream, the downmix section (speaker masks, channel-mask
capture, gain table) and ios_mix_stream against stubs, then checks that every client layout
reaches the stereo bus: a 5.1 centre channel lands in both sides at -3 dB, LFE at -10 dB,
surrounds (and the height speakers of a 7.1.4 bed) on their own side at -3 dB, a plain
WAVEFORMATEX gets the standard layout for its channel count, stereo and mono are unchanged,
and MADEIRA_AUDIO_DOWNMIX=0 restores the old first-two-channels mapping.
"""
from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/audio_null_ios.c").read_text()

def cut(start, end):
    a = src.index(start)
    return src[a:src.index(end, a)]

fmt = cut("struct WAVEFORMATEX_stub {", "struct create_stream_params {")
stream = cut("struct ios_stream {", "/* ml739: one stream object per client")
downmix = cut("#define IOS_SPK_FRONT_LEFT", "/* ------------------- Tier-2: RemoteIO real output")
mix = cut("static void ios_mix_stream(", "/* Core Audio real-time thread. See ios_mix_stream")

harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdatomic.h>
#include <math.h>
typedef unsigned char BYTE; typedef uint16_t WORD; typedef uint32_t UINT32, DWORD, UInt32;
typedef void *HANDLE;
""" + fmt + stream + downmix + mix + r"""
static int fails;
#define NEAR(a, b) (fabsf((a) - (b)) < 1e-4f)
static void expect(const char *what, float got, float want)
{
    if (!NEAR(got, want)) { printf("FAIL %s: got %f want %f\n", what, got, want); fails++; }
}

/* One frame through the real mixer: channel `hot` at `v`, every other channel 0. */
static void mix_one(struct ios_stream *s, int bits, int is_float, UINT32 hot, float v, float out[2])
{
    static BYTE ring[64];
    memset(ring, 0, sizeof(ring));
    s->is_float = is_float; s->sample_bits = bits;
    s->frame_bytes = s->channels * (UINT32)bits / 8;
    if (is_float) memcpy(ring + hot * 4, &v, 4);
    else if (bits == 16) { int16_t i = (int16_t)(v * 32767.0f); memcpy(ring + hot * 2, &i, 2); }
    else { int32_t i = (int32_t)(v * 2147483647.0f); memcpy(ring + hot * 4, &i, 4); }
    s->started = 1; s->mixable = 1; s->ring = ring; s->buffer_frames = 1;
    s->sample_rate = 48000;
    atomic_store(&s->play_pos, 0); atomic_store(&s->write_pos, 1);
    out[0] = out[1] = 0.0f;
    ios_mix_stream(s, out, 1, 2, 48000);
}

static void layout(struct ios_stream *s, UINT32 ch, UINT32 mask)
{
    memset(s, 0, sizeof(*s));
    s->channels = ch;
    s->channel_mask = mask;
    ios_build_mix_gains(s, mask);
}

int main(int argc, char **argv)
{
    struct ios_stream s;
    float o[2];
    const float m3 = 0.70710678f, m10 = 0.316f;
    int off = argc > 1 && !strcmp(argv[1], "off");

    /* dwChannelMask capture: offset 20 of a WAVEFORMATEXTENSIBLE, nothing otherwise */
    {
        BYTE ext[40] = {0};
        struct WAVEFORMATEX_stub *f = (struct WAVEFORMATEX_stub *)ext;
        uint32_t m = 0x3f;
        f->wFormatTag = 0xFFFE; f->cbSize = 22; memcpy(ext + 20, &m, 4);
        if (ios_fmt_channel_mask(f) != 0x3f) { puts("FAIL mask capture"); fails++; }
        f->wFormatTag = 3;
        if (ios_fmt_channel_mask(f) != 0) { puts("FAIL mask on plain format"); fails++; }
        f->wFormatTag = 0xFFFE; f->cbSize = 0;
        if (ios_fmt_channel_mask(f) != 0) { puts("FAIL mask with short cbSize"); fails++; }
        if (ios_fmt_channel_mask(NULL) != 0) { puts("FAIL mask of NULL"); fails++; }
    }

    if (off) {
        /* rollback: channel 0 left, channel 1 right, the rest dropped */
        layout(&s, 6, 0x3f);
        mix_one(&s, 32, 1, 0, 0.5f, o); expect("off FL->L", o[0], 0.5f); expect("off FL->R", o[1], 0.0f);
        mix_one(&s, 32, 1, 1, 0.5f, o); expect("off FR->L", o[0], 0.0f); expect("off FR->R", o[1], 0.5f);
        mix_one(&s, 32, 1, 2, 0.5f, o); expect("off FC->L", o[0], 0.0f); expect("off FC->R", o[1], 0.0f);
        layout(&s, 1, 0);
        mix_one(&s, 16, 0, 0, 0.5f, o); expect("off mono->L", o[0], 0.5f); expect("off mono->R", o[1], 0.5f);
        if (fails) return 1;
        puts("ok");
        return 0;
    }

    /* 5.1 float32 with an explicit mask, and the same with no mask (plain WAVEFORMATEX) */
    for (int pass = 0; pass < 2; pass++) {
        layout(&s, 6, pass ? 0 : 0x3f);
        mix_one(&s, 32, 1, 0, 0.5f, o); expect("5.1 FL->L", o[0], 0.5f); expect("5.1 FL->R", o[1], 0.0f);
        mix_one(&s, 32, 1, 1, 0.5f, o); expect("5.1 FR->L", o[0], 0.0f); expect("5.1 FR->R", o[1], 0.5f);
        mix_one(&s, 32, 1, 2, 0.5f, o); expect("5.1 FC->L", o[0], 0.5f * m3); expect("5.1 FC->R", o[1], 0.5f * m3);
        mix_one(&s, 32, 1, 3, 0.5f, o); expect("5.1 LFE->L", o[0], 0.5f * m10); expect("5.1 LFE->R", o[1], 0.5f * m10);
        mix_one(&s, 32, 1, 4, 0.5f, o); expect("5.1 BL->L", o[0], 0.5f * m3); expect("5.1 BL->R", o[1], 0.0f);
        mix_one(&s, 32, 1, 5, 0.5f, o); expect("5.1 BR->L", o[0], 0.0f); expect("5.1 BR->R", o[1], 0.5f * m3);
    }
    /* 5.1 as 16-bit and 32-bit integer: the same centre fold */
    layout(&s, 6, 0x3f);
    mix_one(&s, 16, 0, 2, 0.5f, o); expect("5.1 s16 FC->L", o[0], 0.5f * m3); expect("5.1 s16 FC->R", o[1], 0.5f * m3);
    mix_one(&s, 32, 0, 2, 0.5f, o); expect("5.1 s32 FC->L", o[0], 0.5f * m3); expect("5.1 s32 FC->R", o[1], 0.5f * m3);

    /* 7.1 (back + side pairs) */
    layout(&s, 8, 0x63f);
    mix_one(&s, 32, 1, 6, 0.5f, o); expect("7.1 SL->L", o[0], 0.5f * m3); expect("7.1 SL->R", o[1], 0.0f);
    mix_one(&s, 32, 1, 7, 0.5f, o); expect("7.1 SR->L", o[0], 0.0f); expect("7.1 SR->R", o[1], 0.5f * m3);

    /* 7.1.4 (ml1227: Wine's spatial audio bed): the four height speakers fold into their side at -3 dB */
    layout(&s, 12, 0x2d63f);
    mix_one(&s, 32, 1, 2, 0.5f, o); expect("7.1.4 FC->L", o[0], 0.5f * m3); expect("7.1.4 FC->R", o[1], 0.5f * m3);
    mix_one(&s, 32, 1, 8, 0.5f, o); expect("7.1.4 TFL->L", o[0], 0.5f * m3); expect("7.1.4 TFL->R", o[1], 0.0f);
    mix_one(&s, 32, 1, 9, 0.5f, o); expect("7.1.4 TFR->L", o[0], 0.0f); expect("7.1.4 TFR->R", o[1], 0.5f * m3);
    mix_one(&s, 32, 1, 10, 0.5f, o); expect("7.1.4 TBL->L", o[0], 0.5f * m3); expect("7.1.4 TBL->R", o[1], 0.0f);
    mix_one(&s, 32, 1, 11, 0.5f, o); expect("7.1.4 TBR->L", o[0], 0.0f); expect("7.1.4 TBR->R", o[1], 0.5f * m3);

    /* stereo and mono are what they always were */
    layout(&s, 2, 0x3);
    mix_one(&s, 16, 0, 0, 0.5f, o); expect("stereo L->L", o[0], 0.5f); expect("stereo L->R", o[1], 0.0f);
    mix_one(&s, 16, 0, 1, 0.5f, o); expect("stereo R->L", o[0], 0.0f); expect("stereo R->R", o[1], 0.5f);
    layout(&s, 1, 0x4);
    mix_one(&s, 32, 1, 0, 0.5f, o); expect("mono->L", o[0], 0.5f); expect("mono->R", o[1], 0.5f);

    /* a mask naming fewer speakers than channels folds the rest in rather than dropping them */
    layout(&s, 4, 0x3);
    mix_one(&s, 32, 1, 3, 0.5f, o); expect("unnamed->L", o[0], 0.25f); expect("unnamed->R", o[1], 0.25f);

    if (fails) return 1;
    puts("ok");
    return 0;
}
"""
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "downmix.c"; c.write_text(harness)
    exe = Path(t) / "downmix"
    subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wno-unused-function", "-fsanitize=address,undefined",
                    str(c), "-o", str(exe), "-lm"], check=True)
    env = {k: v for k, v in os.environ.items() if k != "MADEIRA_AUDIO_DOWNMIX"}
    out = subprocess.run([str(exe)], capture_output=True, text=True, env=env)
    assert out.returncode == 0 and out.stdout.strip() == "ok", (out.returncode, out.stdout, out.stderr)
    print("PASS: 5.1/7.1/7.1.4 fold centre and LFE into both sides and surrounds and height speakers into their own; "
          "plain formats get the standard layout; stereo and mono unchanged")
    env["MADEIRA_AUDIO_DOWNMIX"] = "0"
    out = subprocess.run([str(exe), "off"], capture_output=True, text=True, env=env)
    assert out.returncode == 0 and out.stdout.strip() == "ok", (out.returncode, out.stdout, out.stderr)
    print("PASS: MADEIRA_AUDIO_DOWNMIX=0 restores the first-two-channels mapping")
