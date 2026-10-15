#!/usr/bin/env python3
"""The WMA decoder transform in build/ntdll-unix/winegstreamer_unixlib_ios.c, on the host; no Wine runs.

WMA v1 and v2 streams are encoded here with FFmpeg's own wmav1/wmav2 encoders (a 440 Hz tone),
pushed through the production wg_transform entries exactly as dlls/winegstreamer/wma_decoder.c
drives them (create, push_data in whole block_align multiples, read_data until
MF_E_TRANSFORM_NEED_MORE_INPUT, drain), and the PCM that comes back must be audio: not silent,
at the level it was encoded at, with a 440 Hz fundamental.  Each stream runs to s16 and to float32
output, mono and stereo, at three sample rates.  A second pass does the same with the
parameter search off (MADEIRA_WMA_SEARCH=0), and one case feeds a stream that no parameter set can
decode (random bytes) to check that the concealment still produces time rather than nothing.

The production file is compiled as it is for the device (winegstreamer_unixlib_ios.c, which also
#includes wg_parser_av_ios.c), against the Wine headers of a configured tree, under ASan/UBSan.

Environment: MADEIRA_FFMPEG_TARBALL (default: build/ffmpeg/src/ffmpeg-7.1.1.tar.xz, the tracked
source), MADEIRA_HOST_FFMPEG (prefix of an existing host build with the components below),
MADEIRA_WINE_BUILD (a configured Wine build tree whose include/ holds config.h and the
widl-generated headers; default: wine/build-macos, the tree build/ntdll-unix/build.sh uses).
"""
from pathlib import Path
import hashlib, os, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
ntdll_unix = root / "build/ntdll-unix"
wine = Path(os.environ.get("MADEIRA_WINE_SRC") or root / "wine")
wine_build = Path(os.environ.get("MADEIRA_WINE_BUILD") or wine / "build-macos")
for need in [wine_build / "include/config.h", wine_build / "include/mfobjects.h", wine / "dlls/winegstreamer/unixlib.h"]:
    if not need.exists():
        sys.exit("SKIP-FAIL: %s is missing; point MADEIRA_WINE_BUILD at a configured Wine tree" % need)

# ------------------------------------------------------------------ 64-bit default
# The binder hands 64-bit (ARM64EC) callers the real table unless MADEIRA_WG_64BIT=0, which
# sends them to the generic stub fallback as before; 32-bit callers get the wow64 table.  A
# 64-bit caller's parser stays refused unless MADEIRA_WG_64BIT=1 (wgp_create64).
virtual = (ntdll_unix / "virtual_ios.c").read_text()
head = '} else if (match && strstr(match, "winegstreamer") && (wow || ios_wg_64bit_enabled())) {'
assert virtual.count('strstr(match, "winegstreamer")') == 1, "exactly one winegstreamer branch"
assert head in virtual, "the winegstreamer branch must be gated on wow || MADEIRA_WG_64BIT"
branch = virtual[virtual.index(head):]
branch = branch[:branch.index("} else if", 10)]
assert "funcs_wow64 = (const void *)winegstreamer_unix_call_wow64_funcs;" in branch
helper = virtual[virtual.index("static BOOL ios_wg_64bit_enabled(void)"):]
helper = helper[:helper.index("}") + 1]
assert 'getenv( "MADEIRA_WG_64BIT" )' in helper and "!(e && e[0] == '0')" in helper, helper
unixlib = (ntdll_unix / "winegstreamer_unixlib_ios.c").read_text()
create64 = unixlib[unixlib.index("static NTSTATUS wgp_create64( void *args )"):]
create64 = create64[:create64.index("\n}\n")]
assert "e[0] == '1'" in create64 and "return STATUS_NOT_IMPLEMENTED;" in create64, create64
table64 = unixlib[unixlib.index("const unixlib_entry_t __wine_unix_call_funcs[] ="):]
table64 = table64[:table64.index("};")]
assert "wgp_create64,                       /* unix_wg_parser_create */" in table64, "64-bit parser create is gated"
fallback = virtual[virtual.index("using stub table"):]
fallback = fallback[:fallback.index("ios_bind_unixlib_table")]
assert "funcs64 = (const void *)ios_stub_unix_call_table;" in fallback
assert "winegstreamer" not in fallback
print("PASS: 64-bit callers get the WMA table unless MADEIRA_WG_64BIT=0, their parser only with =1; "
      "32-bit callers get the wow64 table")

# ------------------------------------------------------------------ host FFmpeg
tarball = os.environ.get("MADEIRA_FFMPEG_TARBALL") or str(root / "build/ffmpeg/src/ffmpeg-7.1.1.tar.xz")
FLAGS = [
    "--disable-everything", "--disable-autodetect", "--disable-gpl", "--disable-nonfree", "--disable-version3",
    # the decoder set build/ffmpeg/build.sh ships (WMA family) ...
    "--enable-decoder=wmav1,wmav2,wmapro,wmalossless,xma1,xma2",
    # ... the rest of it, because winegstreamer_unixlib_ios.c #includes the wg_parser core ...
    "--enable-decoder=mp1,mp2,mp3", "--enable-decoder=pcm_u8,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le",
    "--enable-demuxer=mp3,wav,mov", "--enable-parser=mpegaudio",
    # ... and, TEST ONLY, the encoders that make the input streams
    "--enable-encoder=wmav1,wmav2",
    "--disable-programs", "--disable-doc", "--disable-network", "--disable-avdevice", "--disable-swscale",
    "--disable-avfilter", "--disable-postproc", "--enable-avformat", "--enable-avcodec", "--enable-swresample",
    "--disable-asm", "--disable-shared", "--enable-static", "--enable-pic", "--disable-debug",
]
prefix = os.environ.get("MADEIRA_HOST_FFMPEG")
if not prefix:
    key = hashlib.sha256(" ".join(FLAGS).encode()).hexdigest()[:12]
    prefix = str(Path.home() / ".cache/madeira-host-ffmpeg" / ("7.1.1-" + key))
    if not (Path(prefix) / "lib/libavcodec.a").exists():
        assert Path(tarball).exists(), "no FFmpeg tarball at %s" % tarball
        src = Path(prefix + "-src")
        src.mkdir(parents=True, exist_ok=True)
        if not (src / "ffmpeg-7.1.1/configure").exists():
            subprocess.run(["tar", "-xJf", tarball, "-C", str(src)], check=True)
        bld = Path(prefix + "-build"); bld.mkdir(parents=True, exist_ok=True)
        print("building host FFmpeg into", prefix, flush=True)
        log = open(str(bld) + ".log", "w")
        subprocess.run([str(src / "ffmpeg-7.1.1/configure"), "--prefix=" + prefix, "--cc=cc"] + FLAGS,
                       cwd=bld, check=True, stdout=log, stderr=subprocess.STDOUT)
        subprocess.run(["make", "-j%d" % (os.cpu_count() or 4)], cwd=bld, check=True, stdout=log, stderr=subprocess.STDOUT)
        subprocess.run(["make", "install"], cwd=bld, check=True, stdout=log, stderr=subprocess.STDOUT)
inc, lib = Path(prefix) / "include", Path(prefix) / "lib"

# ------------------------------------------------------------------ harness
harness = r"""
#include "winegstreamer_unixlib_ios.c"
#include <math.h>

/* What the device build gets from wg_parser_apple_ios.c. */
const struct mav_video_backend mav_apple_video_backend;
const struct mav_audio_backend mav_apple_audio_backend;

static int failures;
#define CHECK(c, ...) do { if (!(c)) { printf( "FAIL %s: ", name ); printf( __VA_ARGS__ ); printf( "\n" ); failures++; goto done; } } while (0)

/* A 440 Hz tone at -6 dBFS, encoded with FFmpeg's own WMA encoder. */
struct stream
{
    uint8_t *data;          /* whole packets, block_align each */
    size_t size;
    uint8_t extradata[64];
    int extradata_size;
    int block_align;
    int64_t bit_rate;
};

static int encode( enum AVCodecID id, int rate, int channels, int64_t bit_rate, double seconds, struct stream *s )
{
    const AVCodec *codec = avcodec_find_encoder( id );
    AVCodecContext *c = avcodec_alloc_context3( codec );
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    int64_t n = 0, total = (int64_t)(seconds * rate);
    int ch, i, err;

    memset( s, 0, sizeof(*s) );
    c->sample_rate = rate;
    c->bit_rate = bit_rate;
    c->sample_fmt = AV_SAMPLE_FMT_FLTP;
    av_channel_layout_default( &c->ch_layout, channels );
    if ((err = avcodec_open2( c, codec, NULL )) < 0) return err;
    frame->nb_samples = c->frame_size;
    frame->format = c->sample_fmt;
    av_channel_layout_copy( &frame->ch_layout, &c->ch_layout );
    av_frame_get_buffer( frame, 0 );
    for (;;)
    {
        int flush = n >= total;
        if (!flush)
        {
            av_frame_make_writable( frame );
            for (i = 0; i < frame->nb_samples; i++, n++)
                for (ch = 0; ch < channels; ch++)
                    ((float *)frame->extended_data[ch])[i] = 0.5f * (float)sin( 2 * M_PI * 440.0 * n / rate );
            frame->pts = n;
        }
        if ((err = avcodec_send_frame( c, flush ? NULL : frame )) < 0) return err;
        while ((err = avcodec_receive_packet( c, pkt )) >= 0)
        {
            if (pkt->size != c->block_align) return -1000 - pkt->size;
            s->data = realloc( s->data, s->size + pkt->size );
            memcpy( s->data + s->size, pkt->data, pkt->size );
            s->size += pkt->size;
            av_packet_unref( pkt );
        }
        if (err == AVERROR_EOF) break;
        if (err != AVERROR(EAGAIN)) return err;
        if (flush) break;
    }
    s->block_align = c->block_align;
    s->bit_rate = c->bit_rate;
    s->extradata_size = c->extradata_size;
    memcpy( s->extradata, c->extradata, c->extradata_size );
    avcodec_free_context( &c );
    av_frame_free( &frame );
    av_packet_free( &pkt );
    return 0;
}

struct wfx_buf { WAVEFORMATEX wfx; BYTE extra[64]; };

/* Push and read the way wma_decoder.c's ProcessInput/ProcessOutput loop does, and keep
 * every PCM byte that comes back (as mono float for the analysis). */
static int run( const char *name, enum AVCodecID id, WORD tag, int rate, int channels, int64_t bit_rate,
                DWORD declared_avg_bytes, BOOL flt, BOOL garbage )
{
    struct wg_transform_create_params create = {0};
    struct wg_transform_push_data_params push = {0};
    struct wg_transform_read_data_params read = {0};
    struct wfx_buf in = {{0}}, out = {{0}};
    struct stream s;
    float *pcm = NULL;
    size_t frames = 0, off, chunk, cap = 0;
    BYTE outbuf[65536];
    struct wg_sample sample;
    double energy = 0, peak = 0;
    size_t crossings = 0, i;
    int err, packets_per_push = 3;

    if ((err = encode( id, rate, channels, bit_rate, 2.0, &s )))
    {
        printf( "FAIL %s: encoder refused (%d)\n", name, err );
        failures++;
        return 1;
    }
    if (garbage)
    {
        unsigned int seed = 1234;
        for (i = 0; i < s.size; i++) s.data[i] = (BYTE)((seed = seed * 1103515245 + 12345) >> 16);
    }

    in.wfx.wFormatTag = tag;
    in.wfx.nChannels = channels;
    in.wfx.nSamplesPerSec = rate;
    in.wfx.nAvgBytesPerSec = declared_avg_bytes ? declared_avg_bytes : (DWORD)(s.bit_rate / 8);
    in.wfx.nBlockAlign = s.block_align;
    in.wfx.wBitsPerSample = flt ? 32 : 16;   /* wma_decoder.c writes the output size back into it */
    in.wfx.cbSize = s.extradata_size;
    memcpy( in.extra, s.extradata, s.extradata_size );
    out.wfx.wFormatTag = flt ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM;
    out.wfx.nChannels = channels;
    out.wfx.nSamplesPerSec = rate;
    out.wfx.wBitsPerSample = flt ? 32 : 16;
    out.wfx.nBlockAlign = channels * out.wfx.wBitsPerSample / 8;
    out.wfx.nAvgBytesPerSec = rate * out.wfx.nBlockAlign;

    create.input_type.major = madeira_MFMediaType_Audio;
    create.input_type.format_size = sizeof(WAVEFORMATEX) + s.extradata_size;
    create.input_type.u.audio = &in.wfx;
    create.output_type.major = madeira_MFMediaType_Audio;
    create.output_type.format_size = sizeof(WAVEFORMATEX);
    create.output_type.u.audio = &out.wfx;
    CHECK( !wma_transform_create( &create ) && create.transform, "create failed" );

    chunk = (size_t)s.block_align * packets_per_push;
    for (off = 0; off <= s.size; )
    {
        HRESULT hr;

        memset( &sample, 0, sizeof(sample) );
        if (off < s.size)
        {
            size_t n = s.size - off < chunk ? s.size - off : chunk;
            sample.size = sample.max_size = (UINT32)n;
            sample.data = (UINT64)(UINT_PTR)(s.data + off);
            push.transform = create.transform;
            push.sample = &sample;
            CHECK( !wma_transform_push_data( &push ), "push_data failed" );
            hr = push.result;
            if (hr == MF_E_NOTACCEPTING) goto drain_out;
            CHECK( hr == S_OK, "push result %#x", (unsigned)hr );
            off += n;
        }
        else
        {
            CHECK( !wma_transform_drain( &create.transform ), "drain failed" );
            off++;
        }
    drain_out:
        for (;;)
        {
            memset( &sample, 0, sizeof(sample) );
            sample.max_size = sizeof(outbuf);
            sample.data = (UINT64)(UINT_PTR)outbuf;
            read.transform = create.transform;
            read.sample = &sample;
            CHECK( !wma_transform_read_data( &read ), "read_data failed" );
            if (read.result == MF_E_TRANSFORM_NEED_MORE_INPUT) break;
            CHECK( read.result == S_OK && sample.size, "read result %#x size %u", (unsigned)read.result, sample.size );
            CHECK( sample.size % out.wfx.nBlockAlign == 0, "partial frame (%u bytes)", sample.size );
            {
                size_t n = sample.size / out.wfx.nBlockAlign, k;
                if (frames + n > cap) { cap = (frames + n) * 2; pcm = realloc( pcm, cap * sizeof(float) ); }
                for (k = 0; k < n; k++)
                {
                    float v;
                    if (flt) v = ((float *)outbuf)[k * channels];
                    else v = ((int16_t *)outbuf)[k * channels] / 32768.0f;
                    pcm[frames + k] = v;
                }
                frames += n;
            }
        }
    }

    /* The analysis window skips the decoder's priming and the encoder's tail. */
    CHECK( frames >= (size_t)rate, "only %zu frames came back for 2 s of audio", frames );
    {
        size_t a = frames / 4, b = frames - frames / 4;
        for (i = a; i < b; i++)
        {
            double v = pcm[i];
            energy += v * v;
            if (fabs( v ) > peak) peak = fabs( v );
            if (i > a && (pcm[i - 1] < 0) != (v < 0)) crossings++;
        }
        energy = sqrt( energy / (b - a) );
        if (garbage)
        {
            /* Nothing can decode random bytes: what must come back is TIME (silence of the
             * promised length), never noise at many times full scale. */
            CHECK( peak <= 3.0, "undecodable input came back as %.2f full scale", peak );
            printf( "PASS %s: undecodable stream concealed as %zu frames, peak %.3f\n", name, frames, peak );
        }
        else
        {
            double freq = crossings / 2.0 * rate / (b - a);
            CHECK( energy > 0.2, "silent or near-silent: rms %.4f (peak %.4f) over %zu frames", energy, peak, frames );
            CHECK( peak < 1.0, "peak %.3f: not the tone that was encoded", peak );
            CHECK( fabs( freq - 440.0 ) < 10.0, "fundamental %.1f Hz, expected 440", freq );
            printf( "PASS %s: %zu frames, rms %.3f, peak %.3f, %.1f Hz\n", name, frames, energy, peak, freq );
        }
    }
done:
    if (create.transform) wma_transform_destroy( &create.transform );
    free( pcm );
    free( s.data );
    return 0;
}

int main( int argc, char **argv )
{
    static const int rates[] = { 22050, 32000, 44100 };
    char name[128];
    int r, ch, v, f;

    for (v = 1; v <= 2; v++)
        for (r = 0; r < 3; r++)
            for (ch = 1; ch <= 2; ch++)
                for (f = 0; f <= 1; f++)
                {
                    snprintf( name, sizeof(name), "wmav%d %d Hz %dch -> %s%s", v, rates[r], ch, f ? "float32" : "s16",
                              argc > 1 ? " (search off)" : "" );
                    run( name, v == 1 ? AV_CODEC_ID_WMAV1 : AV_CODEC_ID_WMAV2, v == 1 ? WAVE_FORMAT_MSAUDIO1 : WAVE_FORMAT_WMAUDIO2,
                         rates[r], ch, ch * 64000, 0, f, FALSE );
                }
    /* A low bit rate; and honest streams whose (channels, rate, bit rate) is a row of
     * libavformat/xwma.c's "fake bit rate" table.  FFmpeg's encoder writes zeroed codec data
     * with flags2 = 1 (no bit reservoir), which is not what an xWMA caller's synthetic codec
     * data looks like (flags2 = 31), so these must decode at the rate they declare.
     *
     * Not covered here: bit-reservoir (superframe) streams and the parameter search for them.
     * FFmpeg has no encoder for them; the search was developed against streams taken from
     * real content, which cannot be committed. */
    for (v = 1; v <= 2; v++)
        for (f = 0; f <= 1; f++)
        {
            static const struct { int rate, ch, br; } rows[] =
                { { 22050, 2, 24000 }, { 44100, 1, 96000 }, { 22050, 1, 48000 }, { 22050, 2, 48000 } };
            int k;
            for (k = 0; k < 4; k++)
            {
                snprintf( name, sizeof(name), "wmav%d %d Hz %dch at %d bit/s -> %s%s", v, rows[k].rate, rows[k].ch,
                          rows[k].br, f ? "float32" : "s16", argc > 1 ? " (search off)" : "" );
                run( name, v == 1 ? AV_CODEC_ID_WMAV1 : AV_CODEC_ID_WMAV2,
                     v == 1 ? WAVE_FORMAT_MSAUDIO1 : WAVE_FORMAT_WMAUDIO2,
                     rows[k].rate, rows[k].ch, rows[k].br, 0, f, FALSE );
            }
        }
    run( "wmav2 44100 Hz 2ch, random bytes", AV_CODEC_ID_WMAV2, WAVE_FORMAT_WMAUDIO2, 44100, 2, 128000, 0, TRUE, TRUE );
    printf( "%s: %d failure(s)\n", failures ? "FAIL" : "PASS", failures );
    return failures ? 1 : 0;
}
"""

with tempfile.TemporaryDirectory() as tmp:
    h = Path(tmp) / "wma_host.c"
    h.write_text(harness)
    exe = Path(tmp) / "wma_host"
    cc = os.environ.get("CC", "cc")
    cmd = [cc, "-O1", "-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined",
           "-fno-strict-aliasing", "-Wno-int-conversion", "-Wno-implicit-function-declaration",
           "-include", str(wine_build / "include/config.h"),
           "-I" + str(ntdll_unix), "-I" + str(wine / "dlls/winegstreamer"),
           "-I" + str(wine_build / "include"), "-I" + str(wine / "include"), "-I" + str(inc),
           "-D__WINESRC__", "-D_NTSYSTEM_", "-D_ACRTIMP=", "-DWINBASEAPI=", "-DWINE_UNIX_LIB",
           str(h), "-o", str(exe),
           str(lib / "libavformat.a"), str(lib / "libavcodec.a"), str(lib / "libswresample.a"), str(lib / "libavutil.a"),
           "-lm", "-lpthread"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-6000:], r.stderr[-6000:])
        sys.exit("FAIL: harness did not compile")
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=1")
    env.pop("MADEIRA_WMA_SEARCH", None)
    ok = True
    for label, extra_env, args in [("parameter search on (default)", {}, []),
                                   ("MADEIRA_WMA_SEARCH=0", {"MADEIRA_WMA_SEARCH": "0"}, ["off"])]:
        print("--- %s ---" % label, flush=True)
        r = subprocess.run([str(exe)] + args, env=dict(env, **extra_env), capture_output=True, text=True)
        sys.stdout.write(r.stdout)
        if r.returncode:
            ok = False
            tail = [l for l in r.stderr.splitlines() if not l.startswith("[wma]")][-40:]
            print("\n".join(tail))
            print("[wma] lines (first 40):")
            print("\n".join([l for l in r.stderr.splitlines() if l.startswith("[wma]")][:40]))
    sys.exit(0 if ok else "FAIL: WMA decoder host test")
