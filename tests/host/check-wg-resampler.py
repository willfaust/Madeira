#!/usr/bin/env python3
"""The wg_transform audio resampler (winegstreamer's resampler: CLSID_CResamplerMediaObject and
wg_resampler) on libswresample, through the unix call entries; no Wine runs.

Media Foundation's topology loader puts the resampler between a source's PCM and the audio
renderer, which takes only the device mix format. This port's wg_transform refused PCM input
("input format tag 0x1 is not a WMA family stream"), resampler_create failed, the audio branch of
Senren Banka's WMV movie topology failed with it, and the movie never presented. The transform now
converts PCM and float of any rate and 1 to 8 channels with libswresample.

Checks, under ASan/UBSan:
  - Senren's case (48 kHz S16 stereo -> 44.1 and 48 kHz float stereo): the tone's frequency and level,
    the frame count after drain, gap-free timestamps from the input's, chunked reads;
  - formats in and out: u8, s16, s24 (packed), s32, f32, f64; identity is bit-exact; s24 out within
    one step; WAVE_FORMAT_EXTENSIBLE (5.1 to stereo, stereo float to mono);
  - check_audio_transform_support()'s probe (nBlockAlign and nAvgBytesPerSec 0) is accepted;
  - back-pressure (MF_E_NOTACCEPTING, get_status), flush, a new output type mid-stream (and
    get_output_type's two-phase answer), drain;
  - refusals: 12-bit PCM, 9 channels, PCM to AAC; MADEIRA_WG_RESAMPLER=0; a WMA stream still
    reaches the WMA decoder.
Needs MADEIRA_WINE_BUILD (a configured Wine tree), a C compiler and the FFmpeg tarball, as
check-wma-decoder.py.
"""
from pathlib import Path
import os, subprocess, sys, tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from host_ffmpeg import host_ffmpeg   # the shared host build, made under a lock

root = Path(__file__).resolve().parents[2]
ntdll_unix = root / "build/ntdll-unix"
glue = (ntdll_unix / "winegstreamer_unixlib_ios.c").read_text()
wine = Path(os.environ.get("MADEIRA_WINE_SRC") or root / "wine")
wine_build = Path(os.environ.get("MADEIRA_WINE_BUILD") or wine / "build-macos")
for need in [wine_build / "include/config.h", wine_build / "include/mfobjects.h", wine / "dlls/winegstreamer/unixlib.h"]:
    if not need.exists():
        sys.exit("SKIP-FAIL: %s is missing; point MADEIRA_WINE_BUILD at a configured Wine tree" % need)

# ------------------------------------------------------------------ source checks
row = glue[glue.index("static const struct wg_transform_ops rs_transform_ops ="):]
row = row[:row.index("};")]
for fn in ["rs_claims", "rs_create", "rs_destroy", "rs_get_output_type", "rs_set_output_type", "rs_push_data",
           "rs_read_data", "rs_get_status", "rs_drain", "rs_flush"]:
    assert fn in row, ("the resampler's row", fn)
kinds = glue[glue.index("static const struct wg_transform_ops *const transform_kinds[] ="):]
kinds = kinds[:kinds.index("};")]
assert kinds.index("&rs_transform_ops") < kinds.index("&wma_transform_ops"), \
    "the resampler claims raw audio before the WMA decoder claims all audio"
print("PASS: the resampler is a row of transform_kinds, ahead of the WMA decoder (the 64-bit entries and the "
      "wow64 thunks go through the same dispatch)")

# ------------------------------------------------------------------ host FFmpeg (check-wma-decoder.py's, shared cache)
tarball = os.environ.get("MADEIRA_FFMPEG_TARBALL") or str(root / "build/ffmpeg/src/ffmpeg-7.1.5.tar.xz")
FLAGS = [
    "--disable-everything", "--disable-autodetect", "--disable-gpl", "--disable-nonfree", "--disable-version3",
    "--enable-decoder=wmav1,wmav2,wmapro,wmalossless,xma1,xma2",
    "--enable-decoder=mp1,mp2,mp3", "--enable-decoder=pcm_u8,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le",
    "--enable-demuxer=mp3,wav,mov", "--enable-parser=mpegaudio",
    "--enable-encoder=wmav1,wmav2",
    "--disable-programs", "--disable-doc", "--disable-network", "--disable-avdevice", "--disable-swscale",
    "--disable-avfilter", "--disable-postproc", "--enable-avformat", "--enable-avcodec", "--enable-swresample",
    "--disable-asm", "--disable-shared", "--enable-static", "--enable-pic", "--disable-debug",
]
prefix = host_ffmpeg(FLAGS, tarball, tag="", override=os.environ.get("MADEIRA_HOST_FFMPEG"))
inc, lib = prefix / "include", prefix / "lib"

# ------------------------------------------------------------------ harness
harness = r"""
#include "winegstreamer_unixlib_ios.c"
#include <math.h>

const struct mav_video_backend mav_apple_video_backend;
const struct mav_audio_backend mav_apple_audio_backend;

static int failures;
#define CHECK(c, ...) do { if (!(c)) { printf( "FAIL %s:%d: ", __func__, __LINE__ ); printf( __VA_ARGS__ ); printf( "\n" ); failures++; return 1; } } while (0)

static const GUID sub_pcm = { WAVE_FORMAT_PCM, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
static const GUID sub_float = { WAVE_FORMAT_IEEE_FLOAT, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

enum fmt { U8, S16, S24, S32, F32, F64 };
static const int fmt_bits[] = { 8, 16, 24, 32, 32, 64 };
static const char *fmt_name[] = { "u8", "s16", "s24", "s32", "f32", "f64" };

/* A WAVEFORMATEX, or WAVEFORMATEXTENSIBLE with `mask`; `probe`: as check_audio_transform_support() (no
 * nBlockAlign / nAvgBytesPerSec). */
static struct wg_media_type make_type( WAVEFORMATEXTENSIBLE *w, enum fmt f, int rate, int channels, DWORD mask, int probe )
{
    struct wg_media_type t = {0};
    memset( w, 0, sizeof(*w) );
    w->Format.wFormatTag = f >= F32 ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM;
    w->Format.nChannels = channels;
    w->Format.nSamplesPerSec = rate;
    w->Format.wBitsPerSample = fmt_bits[f];
    if (!probe)
    {
        w->Format.nBlockAlign = channels * fmt_bits[f] / 8;
        w->Format.nAvgBytesPerSec = rate * w->Format.nBlockAlign;
    }
    t.major = madeira_MFMediaType_Audio;
    t.u.audio = &w->Format;
    t.format_size = sizeof(WAVEFORMATEX);
    if (mask)
    {
        w->Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
        w->Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
        w->Samples.wValidBitsPerSample = fmt_bits[f];
        w->dwChannelMask = mask;
        w->SubFormat = f >= F32 ? sub_float : sub_pcm;
        t.format_size = sizeof(WAVEFORMATEXTENSIBLE);
    }
    return t;
}

static void put( uint8_t *p, enum fmt f, double v )
{
    double c = v > 1 ? 1 : v < -1 ? -1 : v;
    int32_t i;
    switch (f)
    {
    case U8:  *p = (uint8_t)lrint( c * 127 + 128 ); break;
    case S16: i = (int32_t)lrint( c * 32767 ); memcpy( p, &i, 2 ); break;
    case S24: i = (int32_t)lrint( c * 8388607 ); p[0] = (uint8_t)i; p[1] = (uint8_t)(i >> 8); p[2] = (uint8_t)(i >> 16); break;
    case S32: i = (int32_t)lrint( c * 2147483647.0 ); memcpy( p, &i, 4 ); break;
    case F32: { float x = (float)v; memcpy( p, &x, 4 ); break; }
    case F64: memcpy( p, &v, 8 ); break;
    }
}

static double get( const uint8_t *p, enum fmt f )
{
    int32_t i = 0; float x; double d;
    switch (f)
    {
    case U8:  return (p[0] - 128) / 128.0;
    case S16: { int16_t s; memcpy( &s, p, 2 ); return s / 32768.0; }
    case S24: i = (int32_t)((uint32_t)p[0] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 24) >> 8; return i / 8388608.0;
    case S32: memcpy( &i, p, 4 ); return i / 2147483648.0;
    case F32: memcpy( &x, p, 4 ); return x;
    case F64: memcpy( &d, p, 8 ); return d;
    }
    return 0;
}

struct run
{
    wg_transform_t t;
    uint8_t *out; size_t out_frames, out_cap;   /* every output frame, in order */
    int64_t first_pts, next_pts, max_gap; int pts_gaps, have_pts, discontinuities, incomplete;
    int out_frame;
};

static int read_all( struct run *r, size_t max_read )
{
    for (;;)
    {
        struct wg_transform_read_data_params read = {0};
        struct wg_sample sample = {0};
        uint8_t buf[65536];
        sample.max_size = (UINT32)(max_read < sizeof(buf) ? max_read : sizeof(buf));
        sample.data = (UINT64)(UINT_PTR)buf;
        read.transform = r->t; read.sample = &sample;
        CHECK( !wg_transform_read_data( &read ), "read_data" );
        if (read.result == MF_E_TRANSFORM_NEED_MORE_INPUT) { CHECK( !sample.size, "size with NEED_MORE_INPUT" ); return 0; }
        CHECK( read.result == S_OK && sample.size && sample.size % r->out_frame == 0, "read %#x size %u", (unsigned)read.result, sample.size );
        CHECK( sample.flags & WG_SAMPLE_FLAG_HAS_DURATION, "duration flag" );
        if (sample.flags & WG_SAMPLE_FLAG_HAS_PTS)
        {
            if (!r->have_pts) r->first_pts = sample.pts;
            else
            {
                /* a frame at 44.1 kHz is 226.76 ticks: where a push re-anchors, rounding moves a
                 * boundary by a tick or two, never by a frame */
                int64_t gap = llabs( (long long)(sample.pts - r->next_pts) );
                if (gap > r->max_gap) r->max_gap = gap;
                if (gap > 2) r->pts_gaps++;
            }
            r->have_pts = 1;
            r->next_pts = sample.pts + sample.duration;
        }
        if (sample.flags & WG_SAMPLE_FLAG_DISCONTINUITY) r->discontinuities++;
        if (sample.flags & WG_SAMPLE_FLAG_INCOMPLETE) r->incomplete++;
        if ((r->out_frames + sample.size / r->out_frame) * r->out_frame > r->out_cap)
        {
            r->out_cap = ((r->out_frames + sample.size / r->out_frame) * r->out_frame) * 2;
            r->out = realloc( r->out, r->out_cap );
        }
        memcpy( r->out + r->out_frames * r->out_frame, buf, sample.size );
        r->out_frames += sample.size / r->out_frame;
    }
}

/* Pushes `in` (`frames` frames of `in_frame` bytes) in `chunk`-frame samples with pts, reading after
 * each push; drains at the end. */
static int stream( struct run *r, const uint8_t *in, size_t frames, int in_frame, int rate, size_t chunk, size_t max_read,
                   int64_t pts0 )
{
    size_t off = 0;
    while (off < frames)
    {
        struct wg_transform_push_data_params push = {0};
        struct wg_transform_get_status_params status = {0};
        struct wg_sample sample = {0};
        size_t n = frames - off < chunk ? frames - off : chunk;
        sample.size = sample.max_size = (UINT32)(n * in_frame);
        sample.data = (UINT64)(UINT_PTR)(in + off * in_frame);
        sample.flags = WG_SAMPLE_FLAG_HAS_PTS | (off ? 0 : WG_SAMPLE_FLAG_DISCONTINUITY);
        sample.pts = pts0 + (int64_t)off * 10000000 / rate;
        push.transform = r->t; push.sample = &sample;
        CHECK( !wg_transform_push_data( &push ) && push.result == S_OK, "push %#x", (unsigned)push.result );
        status.transform = r->t;
        CHECK( !wg_transform_get_status( &status ), "get_status" );
        if (read_all( r, max_read )) return 1;
        off += n;
    }
    CHECK( !wg_transform_drain( &r->t ), "drain" );
    return read_all( r, max_read );
}

static int create( struct run *r, struct wg_media_type in, struct wg_media_type out )
{
    struct wg_transform_create_params c = {0};
    c.input_type = in; c.output_type = out;
    memset( r, 0, sizeof(*r) );
    CHECK( !wg_transform_create( &c ) && c.transform, "create" );
    r->t = c.transform;
    r->out_frame = out.u.audio->nChannels * out.u.audio->wBitsPerSample / 8;
    return 0;
}

static void destroy( struct run *r ) { wg_transform_destroy( &r->t ); free( r->out ); }

/* frequency (zero crossings) and rms of channel `ch` over the middle half */
static void analyse( const struct run *r, enum fmt f, int channels, int ch, int rate, double *freq, double *rms )
{
    size_t a = r->out_frames / 4, b = r->out_frames - r->out_frames / 4, i, crossings = 0;
    double e = 0, prev = 0;
    int bps = fmt_bits[f] / 8;
    for (i = a; i < b; i++)
    {
        double v = get( r->out + (i * channels + ch) * bps, f );
        e += v * v;
        if (i > a && (prev < 0) != (v < 0)) crossings++;
        prev = v;
    }
    *rms = sqrt( e / (b - a) );
    *freq = crossings / 2.0 * rate / (b - a);
}

static uint8_t *tone( enum fmt f, int rate, int channels, double seconds, size_t *frames )
{
    size_t n = (size_t)(seconds * rate), i; int c, bps = fmt_bits[f] / 8;
    uint8_t *buf = malloc( n * channels * bps );
    for (i = 0; i < n; i++)
        for (c = 0; c < channels; c++)
            put( buf + (i * channels + c) * bps, f, 0.5 * sin( 2 * M_PI * 440 * (double)i / rate ) * (c == 0 || channels < 3 ? 1 : 0.5) );
    *frames = n;
    return buf;
}

/* Senren's: 48 kHz S16 stereo from the WMA decoder to the mix format */
static int test_senren( int out_rate )
{
    WAVEFORMATEXTENSIBLE wi, wo; struct run r; size_t frames; double freq, rms, want;
    uint8_t *in = tone( S16, 48000, 2, 2.0, &frames );
    int64_t pts0 = 1234567;

    if (create( &r, make_type( &wi, S16, 48000, 2, 0, 0 ), make_type( &wo, F32, out_rate, 2, 0, 0 ) )) return 1;
    if (stream( &r, in, frames, 4, 48000, 1024, 3000, pts0 )) return 1;
    want = (double)frames * out_rate / 48000;
    CHECK( fabs( r.out_frames - want ) <= 2, "%zu frames out, want %.0f", r.out_frames, want );
    analyse( &r, F32, 2, 1, out_rate, &freq, &rms );
    CHECK( fabs( freq - 440 ) < 1.0 && fabs( rms - 0.5 / sqrt( 2 ) ) < 0.01, "%.2f Hz rms %.4f", freq, rms );
    CHECK( r.have_pts && llabs( (long long)(r.first_pts - pts0) ) < 20000 && !r.pts_gaps,
           "pts: first %lld (in %lld), %d gaps, largest %lld", (long long)r.first_pts, (long long)pts0, r.pts_gaps,
           (long long)r.max_gap );
    CHECK( llabs( (long long)(r.next_pts - (pts0 + (int64_t)r.out_frames * 10000000 / out_rate)) ) <= 2 + 10000000 / out_rate,
           "pts at the end %lld, frames say %lld", (long long)r.next_pts, (long long)(pts0 + (int64_t)r.out_frames * 10000000 / out_rate) );
    CHECK( r.discontinuities == 1 && r.incomplete > 0, "discontinuities %d, incomplete reads %d", r.discontinuities, r.incomplete );
    destroy( &r ); free( in );
    printf( "PASS: s16 48000 Hz 2ch -> f32 %d Hz 2ch: %zu frames for %zu, 440 Hz at rms %.4f, pts from the input's without "
            "gaps (largest step error %lld x 100 ns) or drift, chunked reads\n", out_rate, r.out_frames, frames, rms,
            (long long)r.max_gap );
    return 0;
}

static int test_formats( void )
{
    static const enum fmt all[] = { U8, S16, S24, S32, F32, F64 };
    unsigned int i, j; int tested = 0;
    for (i = 0; i < 6; i++)
        for (j = 0; j < 6; j++)
        {
            WAVEFORMATEXTENSIBLE wi, wo; struct run r; size_t frames, k; double freq, rms, maxerr = 0;
            enum fmt fi = all[i], fo = all[j];
            uint8_t *in = tone( fi, 44100, 2, 1.0, &frames );
            int ib = fmt_bits[fi] / 8, ob = fmt_bits[fo] / 8;
            /* step of the coarser side, plus libswresample's rounding on the way */
            double tol = (fi == U8 || fo == U8) ? 2.0 / 128 : (fi == S16 || fo == S16) ? 2.0 / 32768 : 2.0 / 8388608;

            if (create( &r, make_type( &wi, fi, 44100, 2, 0, 0 ), make_type( &wo, fo, 44100, 2, 0, 0 ) )) return 1;
            if (stream( &r, in, frames, 2 * ib, 44100, 4410, 1 << 20, 0 )) return 1;
            CHECK( r.out_frames == frames, "%s -> %s: %zu frames for %zu", fmt_name[fi], fmt_name[fo], r.out_frames, frames );
            for (k = 0; k < frames * 2; k++)
            {
                double e = fabs( get( r.out + k * ob, fo ) - get( in + k * ib, fi ) );
                if (e > maxerr) maxerr = e;
            }
            CHECK( maxerr <= tol, "%s -> %s: error %.3g > %.3g", fmt_name[fi], fmt_name[fo], maxerr, tol );
            if (fi == fo) CHECK( !memcmp( r.out, in, frames * 2 * ib ), "%s -> %s is not bit-exact", fmt_name[fi], fmt_name[fo] );
            /* 1 Hz per zero crossing in this window, and u8's quantisation sits on 0 */
            analyse( &r, fo, 2, 0, 44100, &freq, &rms );
            CHECK( fabs( freq - 440 ) < 2.5, "%s -> %s: %.2f Hz", fmt_name[fi], fmt_name[fo], freq );
            destroy( &r ); free( in ); tested++;
        }
    printf( "PASS: %d format pairs of u8 s16 s24 s32 f32 f64 at 44100 Hz: every sample within the coarser format's step; "
            "identity bit-exact\n", tested );
    return 0;
}

static int test_channels( void )
{
    WAVEFORMATEXTENSIBLE wi, wo; struct run r; size_t frames; double freq, rms, rms_r;
    uint8_t *in;

    /* 5.1 (EXTENSIBLE, float) to stereo S16 */
    in = tone( F32, 48000, 6, 1.0, &frames );
    if (create( &r, make_type( &wi, F32, 48000, 6, 0x3f, 0 ), make_type( &wo, S16, 48000, 2, 0, 0 ) )) return 1;
    if (stream( &r, in, frames, 24, 48000, 960, 1 << 20, 0 )) return 1;
    analyse( &r, S16, 2, 0, 48000, &freq, &rms ); analyse( &r, S16, 2, 1, 48000, &freq, &rms_r );
    CHECK( r.out_frames == frames && fabs( freq - 440 ) < 2.5 && rms > 0.05 && rms_r > 0.05, "5.1 -> stereo: %zu frames, %.1f Hz, rms %.3f / %.3f",
           r.out_frames, freq, rms, rms_r );
    destroy( &r ); free( in );

    /* mono to stereo, both channels the tone; stereo EXTENSIBLE float to mono */
    in = tone( S16, 22050, 1, 1.0, &frames );
    if (create( &r, make_type( &wi, S16, 22050, 1, 0, 0 ), make_type( &wo, F32, 44100, 2, 0x3, 0 ) )) return 1;
    if (stream( &r, in, frames, 2, 22050, 500, 1 << 20, 0 )) return 1;
    analyse( &r, F32, 2, 0, 44100, &freq, &rms ); analyse( &r, F32, 2, 1, 44100, &freq, &rms_r );
    CHECK( fabs( (double)r.out_frames - 2.0 * frames ) <= 2 && fabs( freq - 440 ) < 2.5 && fabs( rms - rms_r ) < 1e-6 && rms > 0.2,
           "mono 22050 -> stereo 44100: %zu frames, %.1f Hz, rms %.3f / %.3f", r.out_frames, freq, rms, rms_r );
    destroy( &r ); free( in );

    in = tone( F32, 44100, 2, 1.0, &frames );
    if (create( &r, make_type( &wi, F32, 44100, 2, 0x3, 0 ), make_type( &wo, S16, 44100, 1, 0, 0 ) )) return 1;
    if (stream( &r, in, frames, 8, 44100, 441, 1 << 20, 0 )) return 1;
    analyse( &r, S16, 1, 0, 44100, &freq, &rms );
    CHECK( r.out_frames == frames && fabs( freq - 440 ) < 2.5 && rms > 0.2, "stereo -> mono: %.1f Hz rms %.3f", freq, rms );
    destroy( &r ); free( in );
    printf( "PASS: channels: 5.1 (EXTENSIBLE) -> stereo, mono 22050 -> stereo 44100 (EXTENSIBLE), stereo -> mono\n" );
    return 0;
}

static int test_protocol( void )
{
    WAVEFORMATEXTENSIBLE wi, wo, w2; struct run r; size_t frames; double freq, rms;
    struct wg_transform_create_params c = {0};
    struct wg_transform_push_data_params push = {0};
    struct wg_transform_get_status_params status = {0};
    struct wg_transform_get_output_type_params got = {0};
    struct wg_transform_set_output_type_params set = {0};
    struct wg_sample sample = {0};
    uint8_t *in = tone( S16, 48000, 2, 1.0, &frames ), fmtbuf[64];

    /* resampler_create()'s probe: no nBlockAlign, no nAvgBytesPerSec */
    c.input_type = make_type( &wi, S16, 44100, 1, 0, 1 ); c.output_type = make_type( &wo, F32, 44100, 1, 0, 1 );
    CHECK( !wg_transform_create( &c ) && c.transform, "check_audio_transform_support()'s probe" );
    CHECK( !wg_transform_destroy( &c.transform ), "destroy" );

    if (create( &r, make_type( &wi, S16, 48000, 2, 0, 0 ), make_type( &wo, F32, 48000, 2, 0, 0 ) )) return 1;
    /* back-pressure */
    sample.size = sample.max_size = 4800 * 4; sample.data = (UINT64)(UINT_PTR)in;
    sample.flags = WG_SAMPLE_FLAG_HAS_PTS; sample.pts = 0;
    push.transform = r.t; push.sample = &sample;
    CHECK( !wg_transform_push_data( &push ) && push.result == S_OK, "push" );
    status.transform = r.t;
    CHECK( !wg_transform_get_status( &status ) && !status.accepts_input, "accepts input with output waiting" );
    CHECK( !wg_transform_push_data( &push ) && push.result == MF_E_NOTACCEPTING, "second push: %#x", (unsigned)push.result );
    /* flush: nothing waits, and the next push starts at its own pts */
    CHECK( !wg_transform_flush( &r.t ), "flush" );
    CHECK( !wg_transform_get_status( &status ) && status.accepts_input, "accepts input after flush" );
    if (read_all( &r, 1 << 20 ) || r.out_frames) { printf( "FAIL: output after flush\n" ); return 1; }
    sample.pts = 50000000;
    CHECK( !wg_transform_push_data( &push ) && push.result == S_OK, "push after flush" );
    if (read_all( &r, 1 << 20 )) return 1;
    CHECK( r.have_pts && r.first_pts == 50000000 && r.discontinuities == 1, "after flush: pts %lld, %d discontinuities",
           (long long)r.first_pts, r.discontinuities );

    /* get_output_type: two-phase */
    got.transform = r.t;
    CHECK( wg_transform_get_output_type( &got ) == STATUS_BUFFER_TOO_SMALL && got.media_type.format_size == sizeof(WAVEFORMATEX),
           "size query" );
    got.media_type.u.format = fmtbuf;
    CHECK( !wg_transform_get_output_type( &got ) && !memcmp( fmtbuf, &wo, sizeof(WAVEFORMATEX) ), "output type verbatim" );

    /* a new output type: 44.1 kHz S16 mono from here on */
    set.transform = r.t; set.media_type = make_type( &w2, S16, 44100, 1, 0, 0 );
    CHECK( !wg_transform_set_output_type( &set ), "set_output_type" );
    got.media_type.format_size = sizeof(fmtbuf);
    CHECK( !wg_transform_get_output_type( &got ) && !memcmp( fmtbuf, &w2, sizeof(WAVEFORMATEX) ), "new output type verbatim" );
    free( r.out ); r.out = NULL; r.out_frames = r.out_cap = 0; r.have_pts = 0; r.out_frame = 2;
    if (stream( &r, in, frames, 4, 48000, 2048, 1 << 20, 0 )) return 1;
    analyse( &r, S16, 1, 0, 44100, &freq, &rms );
    CHECK( fabs( (double)r.out_frames - frames * 44100.0 / 48000 ) <= 2 && fabs( freq - 440 ) < 2.5 && rms > 0.3,
           "after set_output_type: %zu frames, %.1f Hz, rms %.3f", r.out_frames, freq, rms );
    set.media_type = make_type( &w2, S16, 44100, 12, 0, 0 );
    CHECK( wg_transform_set_output_type( &set ) == STATUS_NOT_SUPPORTED, "12-channel output type refused" );
    destroy( &r ); free( in );
    printf( "PASS: check_audio_transform_support()'s probe; back-pressure; flush; get_output_type two-phase and verbatim; "
            "a new output type mid-stream (48000 stereo f32 -> 44100 mono s16)\n" );
    return 0;
}

static int test_refusals( int disabled )
{
    WAVEFORMATEXTENSIBLE wi, wo; struct wg_transform_create_params c = {0};
    NTSTATUS st;

    c.input_type = make_type( &wi, S16, 44100, 2, 0, 0 ); c.output_type = make_type( &wo, F32, 44100, 2, 0, 0 );
    st = wg_transform_create( &c );
    if (disabled)
    {
        CHECK( st == STATUS_NOT_SUPPORTED && !c.transform, "MADEIRA_WG_RESAMPLER=0 refuses: %#x", (unsigned)st );
        printf( "PASS: MADEIRA_WG_RESAMPLER=0 refuses the resampler\n" );
        return 0;
    }
    CHECK( !st && c.transform, "create" ); wg_transform_destroy( &c.transform );
    wi.Format.wBitsPerSample = 12;
    CHECK( wg_transform_create( &c ) == STATUS_NOT_SUPPORTED && !c.transform, "12-bit PCM refused" );
    c.input_type = make_type( &wi, S16, 44100, 9, 0, 0 );
    CHECK( wg_transform_create( &c ) == STATUS_NOT_SUPPORTED && !c.transform, "9 channels refused" );
    c.input_type = make_type( &wi, S16, 44100, 2, 0, 0 );
    wo.Format.wFormatTag = 0x1610;   /* AAC */
    CHECK( wg_transform_create( &c ) == STATUS_NOT_SUPPORTED && !c.transform, "PCM to AAC refused" );
    /* a WMA stream still reaches the WMA decoder (its own test decodes it) */
    {
        struct { WAVEFORMATEX wfx; BYTE extra[6]; } wma = {{ WAVE_FORMAT_WMAUDIO2, 2, 44100, 16000, 2973, 16, 6 }, { 0, 0, 0, 0, 0x1f, 0 }};
        c.input_type.u.audio = &wma.wfx; c.input_type.format_size = sizeof(wma);
        c.output_type = make_type( &wo, S16, 44100, 2, 0, 0 );
        CHECK( !wg_transform_create( &c ) && c.transform && get_wma_transform( c.transform ) && !get_rs_transform( c.transform ),
               "WMA still goes to the WMA decoder" );
        wg_transform_destroy( &c.transform );
    }
    printf( "PASS: refused: 12-bit PCM, 9 channels, PCM to AAC; a WMA stream still reaches the WMA decoder\n" );
    return 0;
}

int main( int argc, char **argv )
{
    setvbuf( stdout, NULL, _IONBF, 0 );
    if (argc > 1) return test_refusals( 1 );
    if (test_senren( 48000 ) || test_senren( 44100 ) || test_formats() || test_channels() || test_protocol()
        || test_refusals( 0 ))
        return 1;
    return failures != 0;
}
"""

with tempfile.TemporaryDirectory() as tmp:
    h = Path(tmp) / "resampler_host.c"
    h.write_text(harness)
    exe = Path(tmp) / "resampler_host"
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
    env = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
    env["ASAN_OPTIONS"] = "detect_leaks=1"
    ok = True
    for args, extra in [([], {}), (["off"], {"MADEIRA_WG_RESAMPLER": "0"})]:
        r = subprocess.run([str(exe)] + args, env=dict(env, **extra), capture_output=True, text=True, timeout=300)
        sys.stdout.write(r.stdout)
        bad = "ERROR: AddressSanitizer" in r.stderr or "runtime error" in r.stderr
        if r.returncode or bad:
            ok = False
            print(r.stderr[-4000:])
        if not args:
            lines = [l for l in r.stderr.splitlines() if l.startswith("[resampler]")]
            assert any("created s16 48000 Hz 2ch -> f32 44100 Hz 2ch" in l for l in lines), lines
            for l in lines[:6]:
                print("  " + l)
    sys.exit(0 if ok else "FAIL: resampler host test")
