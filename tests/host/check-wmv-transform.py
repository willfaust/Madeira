#!/usr/bin/env python3
"""The WMV video transform in build/ntdll-unix/winegstreamer_unixlib_ios.c, on the host; no Wine runs.

Sabbat of the Witch (32-bit, KiriKiri) decodes its WMV3 cutscenes with the WMVideo Decoder DMO,
which in Wine is video_decoder.c's wmv_decoder_create() on a wg_transform. This port's transform
refused every video stream, so the DMO could not even be created and the cutscenes were white.

1. Source checks: both unix call tables route the transform rows to the kind dispatcher
   (wg_transform_*, wow64_wg_transform_* for the five entries whose argument block holds a
   pointer); the WMV kind is a row of the kind table; MADEIRA_WG_WMV_TRANSFORM is read once; the
   facts of our Wine pin the transform is built on still hold (wmv_decoder_create's WMV3 probe,
   no allow_format_change for WMV, the DMO's NEED_MORE_INPUT -> S_FALSE and INCOMPLETE mapping,
   the DMO wrapper looping on INCOMPLETE); docs/MEDIA.md and the settings catalog list it.
2. Host FFmpeg 7.1.5 from the tracked tarball with check-wg-parser-asf.py's exact component list
   (so the two share one cached build): the port's WMV/WMA decoders plus TEST-ONLY wmv1/wmv2/wmav2
   encoders.
3. Compiles the production file under ASan/UBSan against a configured Wine tree's headers and
   drives it through __wine_unix_call_funcs / __wine_unix_call_wow64_funcs:
   - WMV7 (wmv1) and WMV8 (wmv2): create, push, read, drain, flush; every picture bit-exact against
     an independent libavcodec decode, in order;
   - every output format (NV12 YV12 I420 IYUV YUY2 UYVY YVYU RGB32 ARGB32 ABGR32 RGB24 RGB565
     RGB555), top-down and bottom-up, at the default layout and at a 2D buffer's stride: sizes,
     every pixel (YUV exact, RGB against an independent BT.601 conversion), the bytes around them
     untouched; a wider frame with an aperture, an aperture offset, a smaller and a larger frame;
   - timestamps and durations as video_decoder.c expects them (preserved, irregular, none with and
     without a frame rate), sync points, discontinuities, never INCOMPLETE;
   - the queue limit, get_status, drain with frames still queued, flush and decode after it,
     set_output_type mid-stream with pictures pending, get_output_type's two phases, a format
     change when allowed, a buffer too small, two threads;
   - the DMO wrapper's one-read-per-input loop at video_decoder.c's attributes;
   - refusals: H.264, WMVP, VC1S, raw video in; NV11, RGB8, AYUV out; no frame size; a sequence
     header libavcodec refuses; audio in with video out;
   - WMV3 / WVC1 / WMVA by codec-id plumbing ONLY (FFmpeg cannot encode them): the
     wmv_decoder_create() probe (WMV3 1920x1080, no sequence header) is accepted with the decoder
     closed and swallows input without crashing; with a hand-built sequence header the right
     libavcodec decoder opens, and garbage frames are rejected without output or crash;
   - the wow64 thunks with 32-bit argument blocks in memory below 4 GB (MAP_32BIT; skipped where
     the host has none), output identical to the 64-bit entries;
   - a WMA v2 stream through the same dispatcher (check-wma-decoder.py is the full WMA check);
   and again with MADEIRA_WG_WMV_TRANSFORM=0: every video create refused, WMA unaffected.

Environment: MADEIRA_FFMPEG_TARBALL (default: build/ffmpeg/src/ffmpeg-7.1.5.tar.xz),
MADEIRA_HOST_FFMPEG_ASF (prefix of an existing host build with the components below),
MADEIRA_WINE_BUILD (a configured Wine build tree whose include/ holds config.h and the
widl-generated headers; default: wine/build-macos).
"""
from pathlib import Path
import hashlib, os, re, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
ntdll_unix = root / "build/ntdll-unix"
wine = Path(os.environ.get("MADEIRA_WINE_SRC") or root / "wine")
wine_build = Path(os.environ.get("MADEIRA_WINE_BUILD") or wine / "build-macos")
glue = (ntdll_unix / "winegstreamer_unixlib_ios.c").read_text()
unixlib_h = (wine / "dlls/winegstreamer/unixlib.h").read_text()
failures = []


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        failures.append(what)


def body(text, start, end="\n}\n"):
    if start not in text:
        return ""
    b = text[text.index(start):]
    return b[:b.index(end) + len(end)] if end in b else b


# ------------------------------------------------------------------ 1. source checks
enum_body = unixlib_h[unixlib_h.index("enum unix_funcs"):]
enum_body = enum_body[enum_body.index("{") + 1:enum_body.index("unix_wg_funcs_count")]
enum_names = re.findall(r"\b(unix_wg_\w+)\s*,", enum_body)


def table(name):
    b = body(glue, "const unixlib_entry_t %s[] =" % name, "};")
    rows = re.findall(r"^\s*(\w+),\s*/\*\s*(unix_wg_\w+)\s*\*/", b, re.M)
    return [r[1] for r in rows], dict((r[1], r[0]) for r in rows)


order64, native = table("__wine_unix_call_funcs")
order32, wow64 = table("__wine_unix_call_wow64_funcs")
check(order64 == enum_names and order32 == enum_names, "both call tables follow enum unix_funcs entry for entry")
pointer_rows = {"create", "get_output_type", "set_output_type", "push_data", "read_data"}
rows_ok = True
for n in enum_names:
    if not n.startswith("unix_wg_transform_"):
        continue
    short = n[len("unix_wg_transform_"):]
    rows_ok &= native.get(n) == "wg_transform_" + short
    rows_ok &= wow64.get(n) == ("wow64_wg_transform_" + short if short in pointer_rows else "wg_transform_" + short)
check(rows_ok, "transform rows: wg_transform_* dispatchers; wow64 thunks for the five pointer-carrying ones, "
               "the other five shared")
kinds = body(glue, "static const struct wg_transform_ops *const transform_kinds[] =", "};")
check("&wma_transform_ops," in kinds and "&wmv_transform_ops," in kinds, "WMA and WMV are rows of the kind table")
create = body(glue, "static NTSTATUS transform_create( struct wg_transform_create_params *params )")
check("transform_kinds[i]->claims( params )" in create and "transform_kinds[i]->create( params )" in create,
      "transform_create gives the create to the first kind that claims the input")
switch = body(glue, "static BOOL wmv_transform_switch_on(void)")
check(glue.count('getenv( "MADEIRA_WG_WMV_TRANSFORM" )') == 1 and 'getenv( "MADEIRA_WG_WMV_TRANSFORM" )' in switch
      and "static int on = -1;" in switch, "MADEIRA_WG_WMV_TRANSFORM is read once, in wmv_transform_switch_on")
check("wmv_transform_switch_on()" in body(glue, "static BOOL wmv_claims("), "the WMV kind claims nothing when switched off")
wmv_read = body(glue, "static NTSTATUS wmv_read_data(")
check(wmv_read and "|= WG_SAMPLE_FLAG_INCOMPLETE" not in wmv_read and "WG_SAMPLE_FLAG_INCOMPLETE" in wmv_read,
      "the WMV read clears WG_SAMPLE_FLAG_INCOMPLETE and never sets it")
check("mav_convert_picture( &g.vout, transform->bt709, &planes, data, &g.layout );" in wmv_read,
      "pictures are written by wg_parser_av_ios.c's mav_convert_picture")
# the Wine pin
vd = (wine / "dlls/winegstreamer/video_decoder.c").read_text()
wmv_create = body(vd, "HRESULT wmv_decoder_create(")
check(".guidFormat = MFVideoFormat_WMV3," in wmv_create and ".guidFormat = MFVideoFormat_I420," in wmv_create
      and "check_video_transform_support(&input_format, &output_format)" in wmv_create,
      "pin: wmv_decoder_create() probes a WMV3 -> I420 transform with no codec private data")
check(vd.count("allow_format_change = TRUE") == 1 and "allow_format_change = TRUE" in body(vd, "HRESULT h264_decoder_create("),
      "pin: only the H.264 decoder allows a format change")
dmo_out = body(vd, "static HRESULT WINAPI media_object_ProcessOutput(")
check("hr == MF_E_TRANSFORM_NEED_MORE_INPUT" in dmo_out and "hr = S_FALSE;" in dmo_out,
      "pin: the DMO's ProcessOutput turns NEED_MORE_INPUT into S_FALSE")
ws = (wine / "dlls/winegstreamer/wg_sample.c").read_text()
check("buffer->dwStatus |= DMO_OUTPUT_DATA_BUFFERF_INCOMPLETE" in body(ws, "HRESULT wg_transform_read_dmo("),
      "pin: WG_SAMPLE_FLAG_INCOMPLETE becomes DMO_OUTPUT_DATA_BUFFERF_INCOMPLETE")
dw = (wine / "dlls/qasf/dmowrapper.c").read_text()
check("more_data = TRUE;" in body(dw, "static HRESULT process_output(") and "} while (more_data);" in dw,
      "pin: the DMO wrapper calls ProcessOutput again while INCOMPLETE is set")
media = (root / "docs/MEDIA.md").read_text()
check("MADEIRA_WG_WMV_TRANSFORM" in media and "check-wmv-transform.py" in media
      and "WMV, resampler" not in media, "docs/MEDIA.md documents the WMV transform, its switch and this check")
catalog = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
check('key: "env.MADEIRA_WG_WMV_TRANSFORM"' in catalog, "the settings catalog lists env.MADEIRA_WG_WMV_TRANSFORM")

for need in [wine_build / "include/config.h", wine_build / "include/mfobjects.h"]:
    if not need.exists():
        sys.exit("SKIP-FAIL: %s is missing; point MADEIRA_WINE_BUILD at a configured Wine tree" % need)

# ------------------------------------------------------------------ 2. host FFmpeg
# check-wg-parser-asf.py's list, verbatim: the same key, so one cached build serves both.
tarball = os.environ.get("MADEIRA_FFMPEG_TARBALL") or str(root / "build/ffmpeg/src/ffmpeg-7.1.5.tar.xz")
FLAGS = [
    "--disable-everything", "--disable-autodetect", "--disable-gpl", "--disable-nonfree", "--disable-version3",
    "--enable-decoder=wmav1,wmav2,wmapro,wmalossless", "--enable-decoder=mp1,mp2,mp3",
    "--enable-decoder=pcm_u8,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le",
    "--enable-decoder=wmv1,wmv2,wmv3,vc1,msmpeg4v1,msmpeg4v2,msmpeg4v3",
    "--enable-demuxer=mp3,wav,mov,asf", "--enable-parser=mpegaudio",
    # TEST ONLY: input synthesis
    "--enable-encoder=wmv1,wmv2,msmpeg4v3,wmav2", "--enable-muxer=asf",
    "--disable-programs", "--disable-doc", "--disable-network", "--disable-avdevice", "--disable-swscale",
    "--disable-avfilter", "--disable-postproc", "--enable-avformat", "--enable-avcodec", "--enable-swresample",
    "--disable-asm", "--disable-shared", "--enable-static", "--enable-pic", "--disable-debug",
]
prefix = os.environ.get("MADEIRA_HOST_FFMPEG_ASF")
if not prefix:
    key = hashlib.sha256(" ".join(FLAGS).encode()).hexdigest()[:12]
    prefix = str(Path.home() / ".cache/madeira-host-ffmpeg" / ("7.1.5-asf-" + key))
    if not (Path(prefix) / "lib/libavformat.a").exists():
        assert Path(tarball).exists(), "no FFmpeg tarball at build/ffmpeg/src (tracked) and no MADEIRA_FFMPEG_TARBALL"
        src = Path(prefix + "-src"); src.mkdir(parents=True, exist_ok=True)
        if not (src / "ffmpeg-7.1.5/configure").exists():
            subprocess.run(["tar", "-xJf", tarball, "-C", str(src)], check=True)
        bld = Path(prefix + "-build"); bld.mkdir(parents=True, exist_ok=True)
        print("building host FFmpeg into", prefix, flush=True)
        log = open(str(bld) + ".log", "w")
        subprocess.run([str(src / "ffmpeg-7.1.5/configure"), "--prefix=" + prefix, "--cc=cc"] + FLAGS,
                       cwd=bld, check=True, stdout=log, stderr=subprocess.STDOUT)
        subprocess.run(["make", "-j%d" % (os.cpu_count() or 4)], cwd=bld, check=True, stdout=log, stderr=subprocess.STDOUT)
        subprocess.run(["make", "install"], cwd=bld, check=True, stdout=log, stderr=subprocess.STDOUT)
inc, lib = Path(prefix) / "include", Path(prefix) / "lib"

# ------------------------------------------------------------------ 3. harness
harness = r"""
#include "winegstreamer_unixlib_ios.c"
#include <math.h>
#include <sys/mman.h>

/* What the device build gets from wg_parser_apple_ios.c. */
const struct mav_video_backend mav_apple_video_backend;
const struct mav_audio_backend mav_apple_audio_backend;

static int failures, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { printf( "FAIL %s:%d: ", __func__, __LINE__ ); printf( __VA_ARGS__ ); \
    printf( "\n" ); fflush( stdout ); failures++; return 1; } } while (0)
#define PASS(...) do { printf( "PASS " __VA_ARGS__ ); printf( "\n" ); fflush( stdout ); } while (0)

#define W 176
#define H 144
#define FPS 25
#define GOP 12
#define FRAMES 40
#define TICK (10000000 / FPS)

/* ---- entries, through the real tables ---- */
static NTSTATUS call64( unsigned int code, void *args ) { return __wine_unix_call_funcs[code]( args ); }
static NTSTATUS call32( unsigned int code, void *args ) { return __wine_unix_call_wow64_funcs[code]( args ); }

/* ---- media types ---- */
static const GUID video_base = { 0, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
#define FCC(a,b,c,d) ((UINT32)(a) | ((UINT32)(b) << 8) | ((UINT32)(c) << 16) | ((UINT32)(d) << 24))

struct vfmt { MFVIDEOFORMAT f; BYTE extra[64]; };

static struct wg_media_type make_video( struct vfmt *v, UINT32 fourcc, UINT32 w, UINT32 h, UINT32 fps_n, UINT32 fps_d,
                                        const BYTE *extra, UINT32 extra_size, BOOL bottom_up )
{
    struct wg_media_type type;

    memset( v, 0, sizeof(*v) );
    v->f.dwSize = sizeof(v->f) + extra_size;
    v->f.guidFormat = video_base;
    v->f.guidFormat.Data1 = fourcc;
    v->f.videoInfo.dwWidth = w;
    v->f.videoInfo.dwHeight = h;
    v->f.videoInfo.FramesPerSecond.Numerator = fps_n;
    v->f.videoInfo.FramesPerSecond.Denominator = fps_d;
    if (bottom_up) v->f.videoInfo.VideoFlags |= MFVideoFlag_BottomUpLinearRep;
    if (extra_size) memcpy( v->extra, extra, extra_size );
    type.major = madeira_MFMediaType_Video;
    type.format_size = v->f.dwSize;
    type.u.video = &v->f;
    return type;
}

/* ---- the streams: a moving pattern encoded by FFmpeg's own encoders, and an independent decode ---- */
struct packet { uint8_t *data; int size, key; };
struct picture { uint8_t y[W * H], u[W * H / 4], v[W * H / 4]; };
struct stream
{
    UINT32 fourcc;
    struct packet packets[FRAMES];
    uint8_t extradata[64];
    int extradata_size;
    struct picture ref[FRAMES];     /* libavcodec's own decode, in order */
};
static struct stream wmv1, wmv2;

static int encode( enum AVCodecID id, struct stream *s )
{
    const AVCodec *enc = avcodec_find_encoder( id ), *dec = avcodec_find_decoder( id );
    AVCodecContext *c = avcodec_alloc_context3( enc ), *d = avcodec_alloc_context3( dec );
    AVFrame *frame = av_frame_alloc(), *out = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    int i, n = 0, got = 0, x, y, err;

    c->width = W; c->height = H;
    c->time_base = (AVRational){ 1, FPS };
    c->pix_fmt = AV_PIX_FMT_YUV420P;
    c->gop_size = GOP;
    c->max_b_frames = 0;
    c->bit_rate = 1500000;
    if ((err = avcodec_open2( c, enc, NULL )) < 0) return err;
    frame->format = c->pix_fmt; frame->width = W; frame->height = H;
    av_frame_get_buffer( frame, 0 );
    for (i = 0; i <= FRAMES; i++)
    {
        if (i < FRAMES)
        {
            av_frame_make_writable( frame );
            for (y = 0; y < H; y++)
                for (x = 0; x < W; x++)
                {
                    int box = x >= 20 + 3 * i && x < 60 + 3 * i && y >= 30 + i && y < 80 + i;
                    frame->data[0][y * frame->linesize[0] + x] = box ? 220 : (uint8_t)(32 + (x + 2 * y + 4 * i) % 160);
                }
            for (y = 0; y < H / 2; y++)
                for (x = 0; x < W / 2; x++)
                {
                    frame->data[1][y * frame->linesize[1] + x] = (uint8_t)(64 + (x * 3 + i) % 128);
                    frame->data[2][y * frame->linesize[2] + x] = (uint8_t)(200 - (y * 2 + i) % 128);
                }
            frame->pts = i;
        }
        if ((err = avcodec_send_frame( c, i < FRAMES ? frame : NULL )) < 0) return err;
        while (avcodec_receive_packet( c, pkt ) >= 0)
        {
            if (n >= FRAMES) return -1000;
            s->packets[n].data = malloc( pkt->size );
            memcpy( s->packets[n].data, pkt->data, pkt->size );
            s->packets[n].size = pkt->size;
            s->packets[n].key = !!(pkt->flags & AV_PKT_FLAG_KEY);
            n++;
            av_packet_unref( pkt );
        }
    }
    if (n != FRAMES) return -2000 - n;
    s->extradata_size = c->extradata_size;
    if (c->extradata_size > (int)sizeof(s->extradata)) return -3000;
    if (c->extradata_size) memcpy( s->extradata, c->extradata, c->extradata_size );

    /* the reference: a plain libavcodec decode of the same packets */
    d->width = W; d->height = H; d->thread_count = 1;
    if (s->extradata_size)
    {
        d->extradata = av_mallocz( s->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE );
        memcpy( d->extradata, s->extradata, s->extradata_size );
        d->extradata_size = s->extradata_size;
    }
    if ((err = avcodec_open2( d, dec, NULL )) < 0) return err;
    for (i = 0; i <= FRAMES; i++)
    {
        if (i < FRAMES)
        {
            pkt->data = s->packets[i].data; pkt->size = s->packets[i].size;
            err = avcodec_send_packet( d, pkt );
        }
        else err = avcodec_send_packet( d, NULL );
        if (err < 0) return err;
        while (avcodec_receive_frame( d, out ) >= 0)
        {
            if (got >= FRAMES || out->width != W || out->height != H || out->format != AV_PIX_FMT_YUV420P) return -4000;
            for (y = 0; y < H; y++) memcpy( s->ref[got].y + y * W, out->data[0] + y * out->linesize[0], W );
            for (y = 0; y < H / 2; y++)
            {
                memcpy( s->ref[got].u + y * W / 2, out->data[1] + y * out->linesize[1], W / 2 );
                memcpy( s->ref[got].v + y * W / 2, out->data[2] + y * out->linesize[2], W / 2 );
            }
            got++;
            av_frame_unref( out );
        }
    }
    pkt->data = NULL; pkt->size = 0;
    avcodec_free_context( &c ); avcodec_free_context( &d );
    av_frame_free( &frame ); av_frame_free( &out ); av_packet_free( &pkt );
    return got == FRAMES ? 0 : -5000 - got;
}

/* ---- an independent oracle for where each byte goes ---- */
enum { F_NV12, F_YV12, F_I420, F_IYUV, F_YUY2, F_UYVY, F_YVYU, F_BGRX, F_BGRA, F_RGBA, F_BGR, F_565, F_555, F_COUNT };
static const struct { const char *name; UINT32 tag; int bpp; } formats[F_COUNT] =
{
    { "NV12", FCC('N','V','1','2'), 1 }, { "YV12", FCC('Y','V','1','2'), 1 }, { "I420", FCC('I','4','2','0'), 1 },
    { "IYUV", FCC('I','Y','U','V'), 1 }, { "YUY2", FCC('Y','U','Y','2'), 2 }, { "UYVY", FCC('U','Y','V','Y'), 2 },
    { "YVYU", FCC('Y','V','Y','U'), 2 }, { "RGB32", 22, 4 }, { "ARGB32", 21, 4 }, { "ABGR32", 32, 4 },
    { "RGB24", 20, 3 }, { "RGB565", 23, 2 }, { "RGB555", 24, 2 },
};
static int planar( int f ) { return f <= F_IYUV; }
static int packed_yuv( int f ) { return f >= F_YUY2 && f <= F_YVYU; }
static UINT32 align4( UINT32 x ) { return (x + 3) & ~3u; }

struct geom
{
    int f, flip;
    UINT32 fw, fh, s0, s1;
    size_t off1, off2, size;
    UINT32 rx, ry, rw, rh;      /* the region the picture goes to */
};

static void geom_init( struct geom *g, int f, UINT32 fw, UINT32 fh, int flip, UINT32 stride )
{
    UINT32 ch = (fh + 1) / 2;
    memset( g, 0, sizeof(*g) );
    g->f = f; g->fw = fw; g->fh = fh; g->flip = flip;
    if (f == F_NV12) g->s0 = g->s1 = (fw + 1) & ~1u;
    else if (planar( f )) { g->s0 = align4( fw ); g->s1 = align4( (fw + 1) / 2 ); }
    else if (f == F_BGR) g->s0 = align4( fw * 3 );
    else if (formats[f].bpp == 4) g->s0 = fw * 4;
    else g->s0 = align4( fw * 2 );
    if (stride) { g->s0 = stride; g->s1 = f == F_NV12 ? stride : stride / 2; }
    if (planar( f ))
    {
        g->off1 = (size_t)g->s0 * fh;
        g->off2 = g->off1 + (size_t)g->s1 * ch;
        g->size = f == F_NV12 ? g->off2 : g->off2 + (size_t)g->s1 * ch;
    }
    else g->size = (size_t)g->s0 * fh;
    g->rw = fw; g->rh = fh;
}

static int clip8( double v ) { return v < 0 ? 0 : v > 255 ? 255 : (int)lround( v ); }

/* BT.601, video range: what an untagged SD stream is. */
static void rgb_of( int Y, int U, int V, int *r, int *g, int *b )
{
    double y = (Y - 16) * 255.0 / 219.0, u = (U - 128) * 255.0 / 224.0, v = (V - 128) * 255.0 / 224.0;
    *r = clip8( y + 1.402 * v );
    *g = clip8( y - 0.344136 * u - 0.714136 * v );
    *b = clip8( y + 1.772 * u );
}

/* Byte offsets of display pixel (x, y): luma (or the packed pixel), and for planar formats Cb, Cr. */
static void locate( const struct geom *g, UINT32 x, UINT32 y, size_t *luma, size_t *cb, size_t *cr )
{
    UINT32 row = g->flip ? g->fh - 1 - y : y, ch = (g->fh + 1) / 2, crow = g->flip ? ch - 1 - y / 2 : y / 2;

    *cb = *cr = 0;
    if (planar( g->f ))
    {
        *luma = (size_t)g->s0 * row + x;
        if (g->f == F_NV12)
        {
            *cb = g->off1 + (size_t)g->s1 * crow + (x / 2) * 2;
            *cr = *cb + 1;
        }
        else
        {
            size_t first = g->off1 + (size_t)g->s1 * crow + x / 2, second = g->off2 + (size_t)g->s1 * crow + x / 2;
            *cb = g->f == F_YV12 ? second : first;
            *cr = g->f == F_YV12 ? first : second;
        }
    }
    else *luma = (size_t)g->s0 * row + (size_t)(packed_yuv( g->f ) ? (x / 2) * 4 : x * formats[g->f].bpp);
}

/* Checks `buf` (pre-filled with 0xCD, `guard` more bytes after the frame) against picture `p`
 * (W x H) placed at the region; outside the picture: black when `black`, else untouched. */
static int check_frame( const char *what, const struct geom *g, const uint8_t *buf, size_t guard,
                        const struct picture *p, int black )
{
    uint8_t *mask = calloc( 1, g->size );
    UINT32 x, y, cw = g->rw < W ? g->rw : W, chh = g->rh < H ? g->rh : H;
    size_t i, l, cb, cr;
    int bad = 0;

    for (y = 0; y < g->rh && !bad; y++)
        for (x = 0; x < g->rw && !bad; x++)
        {
            UINT32 X = g->rx + x, Y = g->ry + y;
            int in = x < cw && y < chh;
            int Yv = in ? p->y[y * W + x] : 16, U = in ? p->u[(y / 2) * (W / 2) + x / 2] : 128;
            int V = in ? p->v[(y / 2) * (W / 2) + x / 2] : 128;
            locate( g, X, Y, &l, &cb, &cr );
            if (!in && !black) continue;
            if (planar( g->f ))
            {
                if (buf[l] != Yv) bad = 1;
                mask[l] = 1;
                if (!(x & 1) && !(y & 1))
                {
                    if (buf[cb] != U || buf[cr] != V) bad = 2;
                    mask[cb] = mask[cr] = 1;
                }
            }
            else if (packed_yuv( g->f ))
            {
                static const int yo[3][2] = { { 0, 2 }, { 1, 3 }, { 0, 2 } }, uo[3] = { 1, 0, 3 }, vo[3] = { 3, 2, 1 };
                int k = g->f - F_YUY2;
                if (!in) { Yv = 16; U = V = 128; }
                if (buf[l + yo[k][x & 1]] != Yv || buf[l + uo[k]] != U || buf[l + vo[k]] != V) bad = 3;
                mask[l + yo[k][x & 1]] = mask[l + uo[k]] = mask[l + vo[k]] = 1;
            }
            else
            {
                int r, gg, b, er, eg, eb;
                if (in) rgb_of( Yv, U, V, &er, &eg, &eb ); else er = eg = eb = 0;
                if (g->f == F_565 || g->f == F_555)
                {
                    unsigned px = buf[l] | (buf[l + 1] << 8);
                    int gbits = g->f == F_565 ? 6 : 5;
                    r = (px >> (gbits + 5)) & 31; gg = (px >> 5) & ((1 << gbits) - 1); b = px & 31;
                    if (abs( r - (er >> 3) ) > 1 || abs( gg - (eg >> (8 - gbits)) ) > 1 || abs( b - (eb >> 3) ) > 1) bad = 4;
                    if (g->f == F_555 && (px & 0x8000)) bad = 5;
                    mask[l] = mask[l + 1] = 1;
                }
                else
                {
                    int ri = g->f == F_RGBA ? 0 : 2, bi = 2 - ri;
                    r = buf[l + ri]; gg = buf[l + 1]; b = buf[l + bi];
                    if (abs( r - er ) > 2 || abs( gg - eg ) > 2 || abs( b - eb ) > 2) bad = 6;
                    if (formats[g->f].bpp == 4 && buf[l + 3] != 0xff) bad = 7;
                    for (i = 0; i < (size_t)formats[g->f].bpp; i++) mask[l + i] = 1;
                }
            }
            if (bad) printf( "  %s: pixel (%u,%u) wrong (kind %d)\n", what, X, Y, bad );
        }
    if (!bad && !black)
        for (i = 0; i < g->size; i++)
            if (!mask[i] && buf[i] != 0xcd) { printf( "  %s: byte %zu outside the picture was written\n", what, i ); bad = 8; break; }
    for (i = 0; !bad && i < guard; i++)
        if (buf[g->size + i] != 0xcd) { printf( "  %s: wrote past the frame\n", what ); bad = 9; }
    free( mask );
    return bad;
}

/* ---- driving a transform ---- */
struct tx { wg_transform_t h; int use32; };

static NTSTATUS create( wg_transform_t *h, const struct wg_media_type *in, const struct wg_media_type *out,
                        const struct wg_transform_attrs *attrs )
{
    struct wg_transform_create_params p = { 0 };
    NTSTATUS status;
    p.input_type = *in; p.output_type = *out;
    if (attrs) p.attrs = *attrs;
    status = call64( unix_wg_transform_create, &p );
    *h = p.transform;
    return status;
}

static HRESULT push( wg_transform_t h, const struct packet *pk, INT64 pts, INT64 duration, UINT32 flags )
{
    struct wg_transform_push_data_params p = { 0 };
    struct wg_sample s = { 0 };
    s.size = s.max_size = pk ? pk->size : 0;
    s.data = (UINT64)(UINT_PTR)(pk ? pk->data : NULL);
    s.flags = flags | (pk && pk->key ? WG_SAMPLE_FLAG_SYNC_POINT : 0);
    if (pts != INT64_MIN) { s.flags |= WG_SAMPLE_FLAG_HAS_PTS; s.pts = pts; }
    if (duration != INT64_MIN) { s.flags |= WG_SAMPLE_FLAG_HAS_DURATION; s.duration = duration; }
    p.transform = h; p.sample = &s;
    if (call64( unix_wg_transform_push_data, &p )) return E_FAIL;
    return p.result;
}

static NTSTATUS readx( wg_transform_t h, struct wg_sample *s, uint8_t *buf, UINT32 max, UINT32 stride, HRESULT *hr )
{
    struct wg_transform_read_data_params p = { 0 };
    NTSTATUS status;
    memset( s, 0, sizeof(*s) );
    s->max_size = max; s->stride = stride; s->data = (UINT64)(UINT_PTR)buf;
    p.transform = h; p.sample = s;
    status = call64( unix_wg_transform_read_data, &p );
    *hr = p.result;
    return status;
}

static void destroy( wg_transform_t h ) { call64( unix_wg_transform_destroy, &h ); }

static const struct wg_transform_attrs decoder_attrs = { .input_queue_length = 15, .preserve_timestamps = TRUE };

/* ---------------------------------------------------------------- tests */

/* video_decoder.c's MFT loop: push, then read until NEED_MORE_INPUT; drain at the end. */
static int test_decode( struct stream *s, const char *name )
{
    struct vfmt vi, vo;
    struct wg_media_type in = make_video( &vi, s->fourcc, W, H, FPS, 1, s->extradata, s->extradata_size, FALSE );
    struct wg_media_type out = make_video( &vo, FCC('N','V','1','2'), W, H, FPS, 1, NULL, 0, FALSE );
    struct geom g;
    uint8_t *buf;
    struct wg_sample smp;
    wg_transform_t h;
    HRESULT hr;
    int i, n = 0;

    geom_init( &g, F_NV12, W, H, 0, 0 );
    buf = malloc( g.size + 64 );
    CHECK( !create( &h, &in, &out, &decoder_attrs ) && h, "%s: create", name );
    for (i = 0; i <= FRAMES; i++)
    {
        if (i < FRAMES) CHECK( push( h, &s->packets[i], (INT64)i * TICK, TICK, 0 ) == S_OK, "%s: push %d", name, i );
        else { wg_transform_t hh = h; CHECK( !call64( unix_wg_transform_drain, &hh ), "%s: drain", name ); }
        for (;;)
        {
            memset( buf, 0xcd, g.size + 64 );
            CHECK( !readx( h, &smp, buf, g.size, 0, &hr ), "%s: read status", name );
            if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) { CHECK( !smp.size, "%s: size with no output", name ); break; }
            CHECK( hr == S_OK, "%s: read hr %#x", name, (unsigned)hr );
            CHECK( n < FRAMES, "%s: more pictures than frames", name );
            CHECK( smp.size == g.size, "%s: picture %d is %u bytes, expected %zu", name, n, smp.size, g.size );
            CHECK( !check_frame( name, &g, buf, 64, &s->ref[n], 0 ), "%s: picture %d differs from libavcodec's", name, n );
            CHECK( smp.flags == (WG_SAMPLE_FLAG_SYNC_POINT | WG_SAMPLE_FLAG_HAS_PTS | WG_SAMPLE_FLAG_HAS_DURATION
                                 | WG_SAMPLE_FLAG_PRESERVE_TIMESTAMPS), "%s: flags %#x", name, smp.flags );
            CHECK( smp.pts == (INT64)n * TICK && smp.duration == TICK, "%s: picture %d at %lld for %llu",
                   name, n, (long long)smp.pts, (unsigned long long)smp.duration );
            n++;
        }
    }
    CHECK( n == FRAMES, "%s: %d pictures for %d frames", name, n, FRAMES );
    {
        struct mav_lavc_vdec *d = get_wmv_transform( h )->dec;
        CHECK( d && d->ctx->codec_id == (s->fourcc == FCC('W','M','V','1') ? AV_CODEC_ID_WMV1 : AV_CODEC_ID_WMV2),
               "%s: the wrong libavcodec decoder", name );
    }
    destroy( h );
    free( buf );
    PASS( "%s: %d frames -> %d NV12 pictures, bit-exact with libavcodec, pts/duration preserved, drained", name, FRAMES, n );
    return 0;
}

/* One stream into one output format; every picture checked. */
static int run_format( struct stream *s, int f, int flip, UINT32 fw, UINT32 fh, UINT32 stride,
                       const MFVideoArea *aperture, int expect_black, const char *what )
{
    struct vfmt vi, vo;
    struct wg_media_type in = make_video( &vi, s->fourcc, W, H, FPS, 1, s->extradata, s->extradata_size, FALSE );
    struct wg_media_type out = make_video( &vo, formats[f].tag, fw, fh, FPS, 1, NULL, 0, flip );
    struct wg_sample smp;
    struct geom g;
    wg_transform_t h;
    uint8_t *buf;
    HRESULT hr;
    int i, n = 0;
    char name[160];

    snprintf( name, sizeof(name), "%s %s%s %ux%u stride %u%s", formats[f].name, flip ? "bottom-up" : "top-down",
              what, fw, fh, stride, aperture ? " aperture" : "" );
    if (aperture) vo.f.videoInfo.MinimumDisplayAperture = *aperture;
    geom_init( &g, f, fw, fh, flip, stride );
    if (aperture) { g.rx = aperture->OffsetX.value; g.ry = aperture->OffsetY.value; g.rw = aperture->Area.cx; g.rh = aperture->Area.cy; }
    buf = malloc( g.size + 64 );
    CHECK( !create( &h, &in, &out, &decoder_attrs ) && h, "%s: create", name );
    for (i = 0; i < FRAMES; i++)
    {
        CHECK( push( h, &s->packets[i], (INT64)i * TICK, TICK, 0 ) == S_OK, "%s: push", name );
        memset( buf, 0xcd, g.size + 64 );
        CHECK( !readx( h, &smp, buf, g.size, stride, &hr ) && hr == S_OK, "%s: read %d hr %#x", name, i, (unsigned)hr );
        CHECK( smp.size == g.size, "%s: %u bytes, expected %zu", name, smp.size, g.size );
        CHECK( !check_frame( name, &g, buf, 64, &s->ref[n], expect_black ), "%s: picture %d", name, n );
        n++;
    }
    destroy( h );
    free( buf );
    return 0;
}

static int test_formats(void)
{
    MFVideoArea ap = { 0 };
    int f, flip, k = 0;

    for (f = 0; f < F_COUNT; f++)
        for (flip = 0; flip <= 1; flip++)
        {
            UINT32 stride = planar( f ) ? 256 : W * formats[f].bpp + 64;
            if (run_format( &wmv2, f, flip, W, H, 0, NULL, 0, "" )) return 1;
            if (run_format( &wmv2, f, flip, W, H, stride, NULL, 0, " (2D buffer)" )) return 1;
            k += 2;
        }
    PASS( "every output format, top-down and bottom-up, default layout and 2D-buffer stride: %d runs of %d pictures, "
          "sizes, pixels and the bytes around them", k, FRAMES );

    /* A frame wider and taller than the picture with the picture's aperture: rows at the frame's
     * stride, the rest of the frame untouched (the DirectShow way of asking for a stride). */
    ap.Area.cx = W; ap.Area.cy = H;
    for (f = 0; f < F_COUNT; f++)
        for (flip = 0; flip <= 1; flip++)
            if (run_format( &wmv2, f, flip, W + 32, H + 16, 0, &ap, 0, "" )) return 1;
    ap.OffsetX.value = 8; ap.OffsetY.value = 4;
    if (run_format( &wmv2, F_NV12, 0, W + 32, H + 16, 0, &ap, 0, " offset" )) return 1;
    if (run_format( &wmv2, F_I420, 1, W + 32, H + 16, 0, &ap, 0, " offset" )) return 1;
    if (run_format( &wmv2, F_YUY2, 1, W + 32, H + 16, 0, &ap, 0, " offset" )) return 1;
    if (run_format( &wmv2, F_BGRX, 1, W + 32, H + 16, 0, &ap, 0, " offset" )) return 1;
    PASS( "an aperture inside a larger frame, every format, both orientations; at an offset too" );

    /* No format change allowed: a smaller frame crops, a larger one is padded with black. */
    for (f = 0; f < F_COUNT; f++)
    {
        if (run_format( &wmv2, f, f & 1, 160, 120, 0, NULL, 0, " (cropped)" )) return 1;
        if (run_format( &wmv2, f, f & 1, 200, 160, 0, NULL, 1, " (padded)" )) return 1;
    }
    /* Width 170 = 2 mod 4: NV12 rows stay 2-aligned (wg_transform.c), I420 rows 4-aligned. */
    if (run_format( &wmv2, F_NV12, 0, 170, H, 0, NULL, 0, " (2-aligned)" )) return 1;
    if (run_format( &wmv2, F_I420, 0, 170, H, 0, NULL, 0, " (4-aligned)" )) return 1;
    if (run_format( &wmv2, F_BGR, 1, 170, H, 0, NULL, 0, " (4-aligned)" )) return 1;
    PASS( "a smaller frame crops, a larger one is padded with black; NV12 at width 170 has 170-byte rows" );
    return 0;
}

static int test_timestamps(void)
{
    static const INT64 irregular[][2] =
    {
        { 666666, 166667 }, { 833333, 166666 }, { 999999, 166666 }, { 1166665, 166667 }, { 1333332, 166667 },
    };
    struct vfmt vi, vo;
    struct wg_media_type in, out;
    struct wg_transform_attrs attrs;
    struct wg_sample smp;
    wg_transform_t h;
    uint8_t *buf = malloc( W * H * 4 );
    HRESULT hr;
    int i, pass;

    for (pass = 0; pass < 4; pass++)
    {
        /* 0: irregular times, preserved; 1: times, not preserved; 2: no times at 25 fps; 3: no times, no rate */
        in = make_video( &vi, wmv1.fourcc, W, H, pass == 3 ? 0 : FPS, pass == 3 ? 0 : 1, NULL, 0, FALSE );
        out = make_video( &vo, FCC('Y','U','Y','2'), W, H, 0, 0, NULL, 0, FALSE );
        attrs = decoder_attrs;
        attrs.preserve_timestamps = pass != 1;
        CHECK( !create( &h, &in, &out, &attrs ), "timestamps %d: create", pass );
        for (i = 0; i < 5; i++)
        {
            UINT32 want = WG_SAMPLE_FLAG_SYNC_POINT | WG_SAMPLE_FLAG_HAS_PTS | WG_SAMPLE_FLAG_HAS_DURATION;
            INT64 pts = pass < 2 ? irregular[i][0] : INT64_MIN, dur = pass < 2 ? irregular[i][1] : INT64_MIN;
            INT64 want_pts = pass < 2 ? irregular[i][0] : pass == 2 ? (INT64)i * TICK : 0;
            INT64 want_dur = pass < 2 ? irregular[i][1] : pass == 2 ? TICK : 0;
            CHECK( push( h, &wmv1.packets[i], pts, dur, i == 3 ? WG_SAMPLE_FLAG_DISCONTINUITY : 0 ) == S_OK, "push" );
            CHECK( !readx( h, &smp, buf, W * H * 4, 0, &hr ) && hr == S_OK, "timestamps %d: read %d", pass, i );
            if (pass == 0) want |= WG_SAMPLE_FLAG_PRESERVE_TIMESTAMPS;
            if (i == 3) want |= WG_SAMPLE_FLAG_DISCONTINUITY;
            CHECK( smp.flags == want, "timestamps %d: picture %d flags %#x, expected %#x", pass, i, smp.flags, want );
            CHECK( smp.pts == want_pts && (INT64)smp.duration == want_dur, "timestamps %d: picture %d at %lld for %lld, "
                   "expected %lld for %lld", pass, i, (long long)smp.pts, (long long)smp.duration, (long long)want_pts,
                   (long long)want_dur );
        }
        destroy( h );
    }
    free( buf );
    PASS( "timestamps: irregular ones preserved (with and without PRESERVE_TIMESTAMPS), none -> 0, 400000, ... at 25 fps "
          "and 0/0 without a rate; every picture a sync point; a discontinuity reaches the next picture" );
    return 0;
}

static int test_queue_drain_flush(void)
{
    struct vfmt vi, vo;
    struct wg_media_type in = make_video( &vi, wmv2.fourcc, W, H, FPS, 1, wmv2.extradata, wmv2.extradata_size, FALSE );
    struct wg_media_type out = make_video( &vo, FCC('N','V','1','2'), W, H, 0, 0, NULL, 0, FALSE );
    struct wg_transform_get_status_params st = { 0 };
    struct wg_transform_attrs attrs = { 0 };
    struct wg_sample smp;
    struct geom g;
    wg_transform_t h, hh;
    uint8_t *buf;
    HRESULT hr;
    int i, n;

    geom_init( &g, F_NV12, W, H, 0, 0 );
    buf = malloc( g.size + 64 );

    /* input_queue_length 15: sixteen frames queue, the seventeenth is refused */
    CHECK( !create( &h, &in, &out, &decoder_attrs ), "queue: create" );
    for (i = 0; i < 16; i++)
    {
        st.transform = h;
        CHECK( !call64( unix_wg_transform_get_status, &st ) && st.accepts_input, "queue: get_status before %d", i );
        CHECK( push( h, &wmv2.packets[i], (INT64)i * TICK, TICK, 0 ) == S_OK, "queue: push %d", i );
    }
    CHECK( !call64( unix_wg_transform_get_status, &st ) && !st.accepts_input, "queue: get_status when full" );
    CHECK( push( h, &wmv2.packets[16], 16 * TICK, TICK, 0 ) == MF_E_NOTACCEPTING, "queue: the 17th frame is refused" );
    for (n = 0; ; n++)
    {
        memset( buf, 0xcd, g.size + 64 );
        CHECK( !readx( h, &smp, buf, g.size, 0, &hr ), "queue: read" );
        if (hr != S_OK) break;
        CHECK( !check_frame( "queue", &g, buf, 64, &wmv2.ref[n], 0 ), "queue: picture %d", n );
    }
    CHECK( n == 16 && hr == MF_E_TRANSFORM_NEED_MORE_INPUT, "queue: %d pictures, then %#x", n, (unsigned)hr );
    CHECK( !call64( unix_wg_transform_get_status, &st ) && st.accepts_input, "queue: get_status when empty" );
    destroy( h );

    /* input_queue_length 0 (check_video_transform_support's attributes): one frame at a time */
    CHECK( !create( &h, &in, &out, &attrs ), "queue 0: create" );
    CHECK( push( h, &wmv2.packets[0], 0, TICK, 0 ) == S_OK && push( h, &wmv2.packets[1], TICK, TICK, 0 ) == MF_E_NOTACCEPTING,
           "queue 0: one frame, then MF_E_NOTACCEPTING" );
    destroy( h );

    /* drain with frames queued: input is refused until they have all been read */
    CHECK( !create( &h, &in, &out, &decoder_attrs ), "drain: create" );
    for (i = 0; i < 5; i++) CHECK( push( h, &wmv2.packets[i], (INT64)i * TICK, TICK, 0 ) == S_OK, "drain: push" );
    hh = h;
    CHECK( !call64( unix_wg_transform_drain, &hh ), "drain" );
    CHECK( push( h, &wmv2.packets[5], 5 * TICK, TICK, 0 ) == MF_E_NOTACCEPTING, "drain: input refused while draining" );
    for (n = 0; ; n++)
    {
        CHECK( !readx( h, &smp, buf, g.size, 0, &hr ), "drain: read" );
        if (hr != S_OK) break;
        CHECK( !check_frame( "drain", &g, buf, 64, &wmv2.ref[n], 0 ) && smp.pts == (INT64)n * TICK, "drain: picture %d", n );
    }
    CHECK( n == 5 && hr == MF_E_TRANSFORM_NEED_MORE_INPUT, "drain: %d pictures", n );
    CHECK( push( h, &wmv2.packets[0], 0, TICK, 0 ) == S_OK, "drain: input accepted once drained" );
    CHECK( !readx( h, &smp, buf, g.size, 0, &hr ) && hr == S_OK && !check_frame( "after drain", &g, buf, 64, &wmv2.ref[0], 0 ),
           "drain: the decoder decodes again after its end of stream" );
    CHECK( !call64( unix_wg_transform_drain, &hh ), "drain empty" );
    CHECK( !readx( h, &smp, buf, g.size, 0, &hr ) && hr == MF_E_TRANSFORM_NEED_MORE_INPUT && !smp.size, "drain: nothing left" );
    destroy( h );

    /* flush: queued frames and decoded pictures go; decoding resumes at the next keyframe */
    CHECK( !create( &h, &in, &out, &decoder_attrs ), "flush: create" );
    hh = h;
    CHECK( !call64( unix_wg_transform_flush, &hh ), "flush a fresh transform" );
    for (i = 0; i < 4; i++) CHECK( push( h, &wmv2.packets[i], (INT64)i * TICK, TICK, 0 ) == S_OK, "flush: push" );
    CHECK( !readx( h, &smp, buf, g.size, 0, &hr ) && hr == S_OK, "flush: read one" );
    CHECK( !call64( unix_wg_transform_flush, &hh ), "flush" );
    CHECK( !readx( h, &smp, buf, g.size, 0, &hr ) && hr == MF_E_TRANSFORM_NEED_MORE_INPUT && !smp.size, "flush: nothing left" );
    for (i = GOP; i < GOP + 6; i++)
    {
        CHECK( push( h, &wmv2.packets[i], (INT64)i * TICK, TICK, 0 ) == S_OK, "flush: push after" );
        CHECK( !readx( h, &smp, buf, g.size, 0, &hr ) && hr == S_OK, "flush: read after" );
        CHECK( !check_frame( "after flush", &g, buf, 64, &wmv2.ref[i], 0 ) && smp.pts == (INT64)i * TICK,
               "flush: picture %d after the flush", i );
    }
    destroy( h );
    free( buf );
    PASS( "queue limit (16 at input_queue_length 15, 1 at 0) and get_status; drain with frames queued refuses input until "
          "they are read, then decodes again; flush drops everything and decoding resumes at a keyframe" );
    return 0;
}

/* The MFT's SetOutputType on a live transform: the decoder state is kept, pending pictures come
 * out in the new format.  The switch is mid-GOP, so a decoder reset would show. */
static int test_set_output_type(void)
{
    struct vfmt vi, vo, vo2;
    struct wg_media_type in = make_video( &vi, wmv2.fourcc, W, H, FPS, 1, wmv2.extradata, wmv2.extradata_size, FALSE );
    struct wg_media_type out = make_video( &vo, FCC('N','V','1','2'), W, H, 0, 0, NULL, 0, FALSE );
    struct wg_media_type out2 = make_video( &vo2, 22, W, H, 0, 0, NULL, 0, TRUE );
    struct wg_transform_set_output_type_params so = { 0 };
    struct wg_transform_get_output_type_params go = { 0 };
    struct wg_sample smp;
    struct geom g, g2;
    wg_transform_t h;
    uint8_t *buf, fmt[512];
    HRESULT hr;
    int i;

    geom_init( &g, F_NV12, W, H, 0, 0 );
    geom_init( &g2, F_BGRX, W, H, 1, 0 );
    buf = malloc( g2.size + 64 );
    CHECK( !create( &h, &in, &out, &decoder_attrs ), "create" );
    for (i = 0; i < 5; i++)
    {
        CHECK( push( h, &wmv2.packets[i], (INT64)i * TICK, TICK, 0 ) == S_OK, "push" );
        memset( buf, 0xcd, g2.size + 64 );
        CHECK( !readx( h, &smp, buf, g.size, 0, &hr ) && hr == S_OK && !check_frame( "nv12", &g, buf, 64, &wmv2.ref[i], 0 ),
               "picture %d", i );
    }
    for (; i < 8; i++) CHECK( push( h, &wmv2.packets[i], (INT64)i * TICK, TICK, 0 ) == S_OK, "push pending" );
    so.transform = h; so.media_type = out2;
    CHECK( !call64( unix_wg_transform_set_output_type, &so ), "set_output_type" );
    /* get_output_type, two-phase: the size first, then the type exactly as set */
    go.transform = h;
    CHECK( call64( unix_wg_transform_get_output_type, &go ) == STATUS_BUFFER_TOO_SMALL && go.media_type.format_size == out2.format_size,
           "get_output_type: size first (%u)", go.media_type.format_size );
    go.media_type.u.format = fmt;
    CHECK( !call64( unix_wg_transform_get_output_type, &go ) && IsEqualGUID( &go.media_type.major, &madeira_MFMediaType_Video )
           && !memcmp( fmt, &vo2.f, out2.format_size ), "get_output_type: the type as set" );
    for (i = 5; i < FRAMES; i++)
    {
        if (i >= 8) CHECK( push( h, &wmv2.packets[i], (INT64)i * TICK, TICK, 0 ) == S_OK, "push" );
        memset( buf, 0xcd, g2.size + 64 );
        CHECK( !readx( h, &smp, buf, g2.size, 0, &hr ) && hr == S_OK, "read %d", i );
        CHECK( smp.size == g2.size && !check_frame( "rgb32", &g2, buf, 64, &wmv2.ref[i], 0 ), "picture %d after the switch", i );
    }
    /* an output the transform cannot write is refused, and the old one stays */
    so.media_type = make_video( &vo2, FCC('N','V','1','1'), W, H, 0, 0, NULL, 0, FALSE );
    CHECK( call64( unix_wg_transform_set_output_type, &so ) == STATUS_NOT_SUPPORTED, "set_output_type NV11 refused" );
    destroy( h );
    free( buf );
    PASS( "set_output_type mid-GOP with 3 pictures pending: they and the rest come out in RGB32 bottom-up, decoded "
          "on from the same state; get_output_type's two phases; NV11 refused and the old type kept" );
    return 0;
}

static int test_format_change_and_small_buffer(void)
{
    struct vfmt vi, vo;
    struct wg_media_type in = make_video( &vi, wmv2.fourcc, W, H, FPS, 1, wmv2.extradata, wmv2.extradata_size, FALSE );
    struct wg_media_type out = make_video( &vo, FCC('I','4','2','0'), 160, 120, 0, 0, NULL, 0, FALSE );
    struct wg_transform_attrs attrs = decoder_attrs;
    struct wg_transform_get_output_type_params go = { 0 };
    struct vfmt got;
    struct wg_sample smp;
    struct geom g;
    wg_transform_t h;
    uint8_t *buf;
    HRESULT hr;

    attrs.allow_format_change = TRUE;
    geom_init( &g, F_I420, W, H, 0, 0 );
    buf = malloc( g.size + 64 );
    CHECK( !create( &h, &in, &out, &attrs ), "create" );
    CHECK( push( h, &wmv2.packets[0], 0, TICK, 0 ) == S_OK, "push" );
    CHECK( !readx( h, &smp, buf, g.size, 0, &hr ) && hr == MF_E_TRANSFORM_STREAM_CHANGE && !smp.size,
           "a 176x144 picture into 160x120 with a format change allowed: %#x", (unsigned)hr );
    go.transform = h; go.media_type.u.format = &got; go.media_type.format_size = sizeof(got);
    CHECK( !call64( unix_wg_transform_get_output_type, &go ) && got.f.videoInfo.dwWidth == W && got.f.videoInfo.dwHeight == H
           && got.f.guidFormat.Data1 == FCC('I','4','2','0'), "get_output_type: the new size" );
    /* a buffer too small: an error, and the picture waits for a bigger one */
    CHECK( readx( h, &smp, buf, g.size - 1, 0, &hr ) == STATUS_BUFFER_TOO_SMALL && !smp.size, "a buffer one byte short" );
    memset( buf, 0xcd, g.size + 64 );
    CHECK( !readx( h, &smp, buf, g.size, 0, &hr ) && hr == S_OK && smp.size == g.size
           && !check_frame( "after change", &g, buf, 64, &wmv2.ref[0], 0 ), "the picture at the new size" );
    destroy( h );
    free( buf );
    PASS( "a format change when allowed: MF_E_TRANSFORM_STREAM_CHANGE once, get_output_type 176x144, then the picture; "
          "a buffer too small is STATUS_BUFFER_TOO_SMALL and keeps the picture" );
    return 0;
}

/* krmovie's path: Wine's DMO wrapper reads once per input (qasf dmowrapper.c), and video_decoder.c's
 * DMO gives the transform input_queue_length 15 and preserve_timestamps. */
static int test_dmo_loop(void)
{
    struct vfmt vi, vo;
    struct wg_media_type in = make_video( &vi, wmv2.fourcc, W, H, FPS, 1, wmv2.extradata, wmv2.extradata_size, FALSE );
    struct wg_media_type out = make_video( &vo, 22, W, H, FPS, 1, NULL, 0, TRUE );
    struct wg_sample smp;
    struct geom g;
    wg_transform_t h;
    uint8_t *buf;
    HRESULT hr;
    int i;

    geom_init( &g, F_BGRX, W, H, 1, 0 );
    buf = malloc( g.size + 64 );
    CHECK( !create( &h, &in, &out, &decoder_attrs ), "create" );
    for (i = 0; i < FRAMES; i++)
    {
        CHECK( push( h, &wmv2.packets[i], (INT64)i * TICK, TICK, 0 ) == S_OK, "ProcessInput %d", i );
        memset( buf, 0xcd, g.size + 64 );
        CHECK( !readx( h, &smp, buf, g.size, 0, &hr ) && hr == S_OK, "ProcessOutput %d: %#x", i, (unsigned)hr );
        CHECK( !(smp.flags & WG_SAMPLE_FLAG_INCOMPLETE) && smp.size == g.size, "ProcessOutput %d: flags %#x", i, smp.flags );
        CHECK( !check_frame( "dmo", &g, buf, 64, &wmv2.ref[i], 0 ) && smp.pts == (INT64)i * TICK, "picture %d", i );
    }
    CHECK( !readx( h, &smp, buf, g.size, 0, &hr ) && hr == MF_E_TRANSFORM_NEED_MORE_INPUT && !smp.size,
           "nothing more: NEED_MORE_INPUT with size 0 (the DMO's S_FALSE)" );
    destroy( h );
    free( buf );
    PASS( "the DMO wrapper's loop at video_decoder.c's attributes: one RGB32 bottom-up picture per input, never "
          "INCOMPLETE, then NEED_MORE_INPUT" );
    return 0;
}

struct thread_ctx { wg_transform_t h; int pushed; };

static void *pusher( void *arg )
{
    struct thread_ctx *t = arg;
    while (t->pushed < FRAMES)
    {
        HRESULT hr = push( t->h, &wmv2.packets[t->pushed], (INT64)t->pushed * TICK, TICK, 0 );
        if (hr == S_OK) t->pushed++;
        else if (hr == MF_E_NOTACCEPTING) usleep( 100 );
        else break;
    }
    return NULL;
}

static int test_threads(void)
{
    struct vfmt vi, vo;
    struct wg_media_type in = make_video( &vi, wmv2.fourcc, W, H, FPS, 1, wmv2.extradata, wmv2.extradata_size, FALSE );
    struct wg_media_type out = make_video( &vo, FCC('Y','V','1','2'), W, H, 0, 0, NULL, 0, FALSE );
    struct thread_ctx t = { 0 };
    struct wg_sample smp;
    struct geom g;
    pthread_t thread;
    uint8_t *buf;
    HRESULT hr;
    int n = 0, spins = 0;

    geom_init( &g, F_YV12, W, H, 0, 0 );
    buf = malloc( g.size + 64 );
    CHECK( !create( &t.h, &in, &out, &decoder_attrs ), "create" );
    pthread_create( &thread, NULL, pusher, &t );
    while (n < FRAMES && spins < 2000000)
    {
        CHECK( !readx( t.h, &smp, buf, g.size, 0, &hr ), "read" );
        if (hr == S_OK)
        {
            CHECK( !check_frame( "threads", &g, buf, 0, &wmv2.ref[n], 0 ) && smp.pts == (INT64)n * TICK, "picture %d", n );
            n++;
        }
        else spins++;
    }
    pthread_join( thread, NULL );
    CHECK( n == FRAMES, "%d pictures read while another thread pushed", n );
    destroy( t.h );
    free( buf );
    PASS( "push on one thread, read on another: all %d pictures, in order", n );
    return 0;
}

static int test_refusals(void)
{
    static const BYTE bad_header[4] = { 0, 0, 0, 0 };
    static const struct { UINT32 in, out; UINT32 w, h; const BYTE *extra; UINT32 extra_size; const char *what; } cases[] =
    {
        { FCC('H','2','6','4'), FCC('N','V','1','2'), W, H, NULL, 0, "H.264 in" },
        { FCC('W','M','V','P'), FCC('N','V','1','2'), W, H, NULL, 0, "WMVP in" },
        { FCC('V','C','1','S'), FCC('N','V','1','2'), W, H, NULL, 0, "VC1S in" },
        { FCC('N','V','1','2'), FCC('I','4','2','0'), W, H, NULL, 0, "raw NV12 in (a video processor)" },
        { FCC('W','M','V','2'), FCC('N','V','1','1'), W, H, NULL, 0, "NV11 out" },
        { FCC('W','M','V','2'), 41 /* D3DFMT_P8 */, W, H, NULL, 0, "RGB8 out" },
        { FCC('W','M','V','2'), FCC('A','Y','U','V'), W, H, NULL, 0, "AYUV out" },
        { FCC('W','M','V','2'), FCC('N','V','1','2'), 0, 0, NULL, 0, "no frame size" },
        { FCC('W','M','V','3'), FCC('N','V','1','2'), W, H, bad_header, 4, "a WMV3 sequence header libavcodec refuses" },
    };
    static const GUID wmv_unknown = { 0x7ce12ca9, 0xbfbf, 0x43d9, { 0x9d, 0x00, 0x82, 0xb8, 0xed, 0x54, 0x31, 0x6b } };
    struct vfmt vi, vo;
    struct wg_media_type in, out;
    struct { WAVEFORMATEX wfx; BYTE extra[16]; } pcm = { { WAVE_FORMAT_PCM, 2, 44100, 176400, 4, 16, 0 } };
    wg_transform_t h, bogus_handle;
    UINT32 bogus[16] = { 0x12345678 };
    unsigned int i;

    for (i = 0; i < ARRAY_SIZE(cases); i++)
    {
        in = make_video( &vi, cases[i].in, cases[i].w, cases[i].h, FPS, 1, cases[i].extra, cases[i].extra_size, FALSE );
        out = make_video( &vo, cases[i].out, W, H, 0, 0, NULL, 0, FALSE );
        h = 0xdeadbeef;
        CHECK( create( &h, &in, &out, &decoder_attrs ) == STATUS_NOT_SUPPORTED && !h, "%s: not refused", cases[i].what );
    }
    in = make_video( &vi, 0, W, H, FPS, 1, NULL, 0, FALSE );
    vi.f.guidFormat = wmv_unknown;
    CHECK( create( &h, &in, &out, &decoder_attrs ) == STATUS_NOT_SUPPORTED && !h, "MEDIASUBTYPE_WMV_Unknown in" );
    /* audio in, video out: the WMA kind's to refuse */
    in.major = madeira_MFMediaType_Audio; in.format_size = sizeof(pcm.wfx); in.u.audio = &pcm.wfx;
    CHECK( create( &h, &in, &out, &decoder_attrs ) == STATUS_NOT_SUPPORTED && !h, "PCM in, video out" );
    /* neither audio nor video */
    in.major = video_base; in.major.Data1 = 0x12345678;
    CHECK( create( &h, &in, &out, &decoder_attrs ) == STATUS_NOT_SUPPORTED && !h, "an unknown major type" );
    /* a handle no kind made */
    bogus_handle = (wg_transform_t)(UINT_PTR)bogus;
    CHECK( call64( unix_wg_transform_drain, &bogus_handle ) == STATUS_INVALID_HANDLE
           && call64( unix_wg_transform_destroy, &bogus_handle ) == STATUS_INVALID_HANDLE, "a foreign handle" );
    PASS( "refused: H.264, WMVP, VC1S, WMV_Unknown and raw video in; NV11, RGB8 and AYUV out; no frame size; a bad WMV3 "
          "sequence header; PCM in with video out; an unknown major type; a foreign handle is STATUS_INVALID_HANDLE" );
    return 0;
}

/* WMV3 / VC-1: FFmpeg has no encoder, so codec-id plumbing only. */
static int test_wmv9_plumbing(void)
{
    static const BYTE wmv3_main[4] = { 0x40, 0x09, 0x88, 0x01 };   /* STRUCT_C: main profile, loop filter, ... */
    static const BYTE vc1_adv[18] =  /* sequence header (0x0000010f) + entry point (0x0000010e), 320x240 */
        { 0x00, 0x00, 0x01, 0x0f, 0xca, 0x00, 0x09, 0xf0, 0x77, 0x08, 0x80, 0x00, 0x00, 0x01, 0x0e, 0x4c, 0x40, 0x80 };
    static const struct { UINT32 fourcc; UINT32 w, h; const BYTE *extra; UINT32 extra_size; enum AVCodecID id; const char *what; } cases[] =
    {
        { FCC('W','M','V','3'), 1920, 1080, NULL, 0, AV_CODEC_ID_NONE, "WMV3 1920x1080 without a sequence header (wmv_decoder_create's probe)" },
        { FCC('W','V','C','1'), 320, 240, NULL, 0, AV_CODEC_ID_NONE, "WVC1 without a sequence header" },
        { FCC('W','M','V','3'), 320, 240, wmv3_main, 4, AV_CODEC_ID_WMV3, "WMV3 main profile" },
        { FCC('W','V','C','1'), 320, 240, vc1_adv, sizeof(vc1_adv), AV_CODEC_ID_VC1, "WVC1 advanced profile" },
        { FCC('W','M','V','A'), 320, 240, vc1_adv, sizeof(vc1_adv), AV_CODEC_ID_VC1, "WMVA" },
    };
    struct vfmt vi, vo;
    struct wg_media_type in, out;
    struct wg_transform_attrs probe_attrs = { 0 };
    struct packet garbage;
    struct wg_sample smp;
    struct wmv_transform *t;
    uint8_t *buf = malloc( 1920 * 1088 * 2 ), junk[3000];
    unsigned int i, k, seed = 7;
    wg_transform_t h;
    HRESULT hr;

    for (k = 0; k < sizeof(junk); k++) junk[k] = (uint8_t)((seed = seed * 1103515245 + 12345) >> 16);
    garbage.data = junk; garbage.size = sizeof(junk); garbage.key = 1;
    for (i = 0; i < ARRAY_SIZE(cases); i++)
    {
        in = make_video( &vi, cases[i].fourcc, cases[i].w, cases[i].h, 30000, 1001, cases[i].extra, cases[i].extra_size, FALSE );
        out = make_video( &vo, FCC('I','4','2','0'), cases[i].w, cases[i].h, 0, 0, NULL, 0, FALSE );
        CHECK( !create( &h, &in, &out, i ? &decoder_attrs : &probe_attrs ) && h, "%s: create", cases[i].what );
        t = get_wmv_transform( h );
        CHECK( t, "%s: not a WMV transform", cases[i].what );
        CHECK( t->codec == (cases[i].fourcc == FCC('W','M','V','3') ? MAV_LAVC_WMV3 : MAV_LAVC_VC1), "%s: codec %d", cases[i].what, t->codec );
        if (cases[i].id == AV_CODEC_ID_NONE) CHECK( !t->dec, "%s: a decoder without a sequence header?", cases[i].what );
        else CHECK( t->dec && ((struct mav_lavc_vdec *)t->dec)->ctx->codec_id == cases[i].id, "%s: decoder not open", cases[i].what );
        for (k = 0; k < 3; k++)
        {
            CHECK( push( h, &garbage, k * 333667, 333667, 0 ) == S_OK, "%s: push", cases[i].what );
            CHECK( !readx( h, &smp, buf, 1920 * 1088 * 2, 0, &hr ) && (hr == MF_E_TRANSFORM_NEED_MORE_INPUT || hr == S_OK),
                   "%s: read %#x", cases[i].what, (unsigned)hr );
        }
        { wg_transform_t hh = h; CHECK( !call64( unix_wg_transform_drain, &hh ), "drain" ); }
        while (!readx( h, &smp, buf, 1920 * 1088 * 2, 0, &hr ) && hr == S_OK) {}
        destroy( h );
    }
    free( buf );
    PASS( "WMV3/WVC1/WMVA plumbing (no real stream: FFmpeg cannot encode them): the probe and WVC1 without a sequence "
          "header are accepted with the decoder closed and swallow input; with one, libavcodec's wmv3 / vc1 decoder "
          "opens; garbage frames neither crash nor hang" );
    return 0;
}

/* The same decode through the wow64 table, with 32-bit argument blocks below 4 GB. */
static int test_wow64(void)
{
#ifdef MAP_32BIT
    const size_t arena_size = 32 << 20;
    uint8_t *arena = mmap( NULL, arena_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_32BIT, -1, 0 );
    size_t used = 0;
#define LOW(n) (used += ((n) + 15) & ~(size_t)15, (void *)(arena + used - (((n) + 15) & ~(size_t)15)))
#define G(p) ((ULONG)(UINT_PTR)(p))
    struct wg_transform_create_params32 *c32;
    struct wg_transform_sample_params32 *s32;
    struct wg_transform_output_type_params32 *o32;
    struct wg_transform_get_status_params *st;
    struct wg_sample *smp;
    struct vfmt *vi, *vo, *got;
    wg_transform_t *h;
    uint8_t *buf, *data;
    struct geom g;
    int i, n = 0;

    CHECK( arena != MAP_FAILED && (UINT_PTR)arena + arena_size < ((UINT64)1 << 32), "MAP_32BIT arena" );
    vi = LOW( sizeof(*vi) ); vo = LOW( sizeof(*vo) ); got = LOW( sizeof(*got) );
    c32 = LOW( sizeof(*c32) ); s32 = LOW( sizeof(*s32) ); o32 = LOW( sizeof(*o32) ); st = LOW( sizeof(*st) );
    smp = LOW( sizeof(*smp) ); h = LOW( sizeof(*h) );
    geom_init( &g, F_BGRX, W, H, 1, 0 );
    buf = LOW( g.size + 64 ); data = LOW( 65536 );
    make_video( vi, wmv2.fourcc, W, H, FPS, 1, wmv2.extradata, wmv2.extradata_size, FALSE );
    make_video( vo, 22, W, H, FPS, 1, NULL, 0, TRUE );

    memset( c32, 0, sizeof(*c32) );
    c32->input_type.major = madeira_MFMediaType_Video; c32->input_type.format_size = vi->f.dwSize; c32->input_type.format = G( &vi->f );
    c32->output_type.major = madeira_MFMediaType_Video; c32->output_type.format_size = vo->f.dwSize; c32->output_type.format = G( &vo->f );
    c32->attrs = decoder_attrs;
    CHECK( !call32( unix_wg_transform_create, c32 ) && c32->transform, "wow64 create" );
    *h = c32->transform;
    for (i = 0; i < FRAMES; i++)
    {
        memset( smp, 0, sizeof(*smp) );
        memcpy( data, wmv2.packets[i].data, wmv2.packets[i].size );
        smp->size = smp->max_size = wmv2.packets[i].size;
        smp->data = G( data );
        smp->flags = WG_SAMPLE_FLAG_HAS_PTS | WG_SAMPLE_FLAG_HAS_DURATION;
        smp->pts = (INT64)i * TICK; smp->duration = TICK;
        memset( s32, 0, sizeof(*s32) );
        s32->transform = *h; s32->sample = G( smp );
        CHECK( !call32( unix_wg_transform_push_data, s32 ) && s32->result == S_OK, "wow64 push %d", i );
        memset( smp, 0, sizeof(*smp) );
        smp->max_size = g.size; smp->data = G( buf );
        memset( buf, 0xcd, g.size + 64 );
        s32->result = E_FAIL;
        CHECK( !call32( unix_wg_transform_read_data, s32 ) && s32->result == S_OK && smp->size == g.size, "wow64 read %d", i );
        CHECK( !check_frame( "wow64", &g, buf, 64, &wmv2.ref[n], 0 ) && smp->pts == (INT64)i * TICK
               && smp->flags == (WG_SAMPLE_FLAG_SYNC_POINT | WG_SAMPLE_FLAG_HAS_PTS | WG_SAMPLE_FLAG_HAS_DURATION
                                 | WG_SAMPLE_FLAG_PRESERVE_TIMESTAMPS), "wow64 picture %d", i );
        n++;
    }
    memset( o32, 0, sizeof(*o32) );
    o32->transform = *h;
    CHECK( call32( unix_wg_transform_get_output_type, o32 ) == STATUS_BUFFER_TOO_SMALL && o32->media_type.format_size == vo->f.dwSize,
           "wow64 get_output_type: size" );
    o32->media_type.format = G( got );
    CHECK( !call32( unix_wg_transform_get_output_type, o32 ) && !memcmp( &got->f, &vo->f, vo->f.dwSize ), "wow64 get_output_type" );
    make_video( vo, FCC('N','V','1','2'), W, H, 0, 0, NULL, 0, FALSE );
    o32->media_type.format_size = vo->f.dwSize; o32->media_type.format = G( &vo->f );
    CHECK( !call32( unix_wg_transform_set_output_type, o32 ), "wow64 set_output_type" );
    st->transform = *h;
    CHECK( !call32( unix_wg_transform_get_status, st ) && st->accepts_input, "wow64 get_status" );
    CHECK( !call32( unix_wg_transform_drain, h ) && !call32( unix_wg_transform_flush, h ), "wow64 drain, flush" );
    CHECK( !call32( unix_wg_transform_destroy, h ), "wow64 destroy" );
    munmap( arena, arena_size );
    PASS( "wow64 thunks (32-bit argument blocks below 4 GB): create, %d pushes and reads of RGB32 bottom-up pictures "
          "identical to the 64-bit path, get/set_output_type, get_status, drain, flush, destroy", n );
#undef LOW
#undef G
#else
    printf( "SKIP wow64 thunks: no MAP_32BIT on this host\n" );
#endif
    return 0;
}

/* WMA through the same dispatcher (check-wma-decoder.py is the full WMA check). */
static int test_wma( const char *label )
{
    const AVCodec *codec = avcodec_find_encoder( AV_CODEC_ID_WMAV2 );
    AVCodecContext *c = avcodec_alloc_context3( codec );
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    struct { WAVEFORMATEX wfx; BYTE extra[64]; } in = { { 0 } }, out = { { 0 } };
    struct wg_transform_create_params cp = { 0 };
    struct wg_transform_attrs attrs = { 0 };
    struct wg_sample smp;
    wg_transform_t h;
    int16_t pcm[16384];
    double energy = 0;
    size_t frames = 0;
    HRESULT hr;
    int i, k, n = 0;

    c->sample_rate = 44100; c->bit_rate = 128000; c->sample_fmt = AV_SAMPLE_FMT_FLTP;
    av_channel_layout_default( &c->ch_layout, 2 );
    CHECK( avcodec_open2( c, codec, NULL ) >= 0, "wmav2 encoder" );
    in.wfx.wFormatTag = WAVE_FORMAT_WMAUDIO2; in.wfx.nChannels = 2; in.wfx.nSamplesPerSec = 44100;
    in.wfx.nAvgBytesPerSec = 16000; in.wfx.nBlockAlign = c->block_align; in.wfx.wBitsPerSample = 16;
    in.wfx.cbSize = c->extradata_size; memcpy( in.extra, c->extradata, c->extradata_size );
    out.wfx.wFormatTag = WAVE_FORMAT_PCM; out.wfx.nChannels = 2; out.wfx.nSamplesPerSec = 44100;
    out.wfx.wBitsPerSample = 16; out.wfx.nBlockAlign = 4; out.wfx.nAvgBytesPerSec = 176400;
    cp.input_type.major = madeira_MFMediaType_Audio; cp.input_type.format_size = sizeof(WAVEFORMATEX) + c->extradata_size;
    cp.input_type.u.audio = &in.wfx;
    cp.output_type.major = madeira_MFMediaType_Audio; cp.output_type.format_size = sizeof(WAVEFORMATEX);
    cp.output_type.u.audio = &out.wfx;
    cp.attrs = attrs;
    CHECK( !call64( unix_wg_transform_create, &cp ) && cp.transform, "%s: WMA create", label );
    h = cp.transform;
    CHECK( !get_wmv_transform( h ) && get_wma_transform( h ), "%s: a WMA transform", label );
    frame->nb_samples = c->frame_size; frame->format = c->sample_fmt;
    av_channel_layout_copy( &frame->ch_layout, &c->ch_layout );
    av_frame_get_buffer( frame, 0 );
    for (i = 0; i < 40; i++)
    {
        for (k = 0; k < frame->nb_samples; k++)
            ((float *)frame->data[0])[k] = ((float *)frame->data[1])[k] = 0.5f * (float)sin( 2 * M_PI * 440.0 * (n++) / 44100 );
        avcodec_send_frame( c, frame );
        while (avcodec_receive_packet( c, pkt ) >= 0)
        {
            struct packet p = { pkt->data, pkt->size, 1 };
            CHECK( push( h, &p, INT64_MIN, INT64_MIN, 0 ) == S_OK, "%s: WMA push", label );
            for (;;)
            {
                CHECK( !readx( h, &smp, (uint8_t *)pcm, sizeof(pcm), 0, &hr ), "%s: WMA read", label );
                if (hr != S_OK) break;
                for (k = 0; k < (int)(smp.size / 2); k++) energy += (double)pcm[k] * pcm[k];
                frames += smp.size / 4;
            }
            av_packet_unref( pkt );
        }
    }
    destroy( h );
    avcodec_free_context( &c ); av_frame_free( &frame ); av_packet_free( &pkt );
    energy = sqrt( energy / (frames * 2 + 1) ) / 32768;
    CHECK( frames > 44100 / 2 && energy > 0.2, "%s: WMA gave %zu frames at rms %.3f", label, frames, energy );
    PASS( "%s: a WMA v2 stream through the same dispatcher: %zu frames of PCM, rms %.3f", label, frames, energy );
    return 0;
}

/* MADEIRA_WG_WMV_TRANSFORM=0: every video transform is refused again; WMA is not affected. */
static int test_switched_off(void)
{
    static const BYTE wmv3_main[4] = { 0x40, 0x09, 0x88, 0x01 };
    struct vfmt vi, vo;
    struct wg_media_type in, out;
    wg_transform_t h = 1;

    out = make_video( &vo, FCC('N','V','1','2'), W, H, 0, 0, NULL, 0, FALSE );
    in = make_video( &vi, wmv1.fourcc, W, H, FPS, 1, NULL, 0, FALSE );
    CHECK( create( &h, &in, &out, &decoder_attrs ) == STATUS_NOT_SUPPORTED && !h, "WMV1 refused" );
    in = make_video( &vi, wmv2.fourcc, W, H, FPS, 1, wmv2.extradata, wmv2.extradata_size, FALSE );
    CHECK( create( &h, &in, &out, &decoder_attrs ) == STATUS_NOT_SUPPORTED && !h, "WMV2 refused" );
    in = make_video( &vi, FCC('W','M','V','3'), 320, 240, FPS, 1, wmv3_main, 4, FALSE );
    CHECK( create( &h, &in, &out, &decoder_attrs ) == STATUS_NOT_SUPPORTED && !h, "WMV3 refused" );
    in = make_video( &vi, FCC('W','M','V','3'), 1920, 1080, 0, 0, NULL, 0, FALSE );
    out = make_video( &vo, FCC('I','4','2','0'), 1920, 1080, 0, 0, NULL, 0, FALSE );
    CHECK( create( &h, &in, &out, NULL ) == STATUS_NOT_SUPPORTED && !h, "the probe refused" );
    PASS( "MADEIRA_WG_WMV_TRANSFORM=0: WMV1, WMV2, WMV3 and wmv_decoder_create's probe are refused" );
    return 0;
}

int main( int argc, char **argv )
{
    int off = argc > 1 && !strcmp( argv[1], "off" ), err;

    wmv1.fourcc = FCC('W','M','V','1');
    wmv2.fourcc = FCC('W','M','V','2');
    if ((err = encode( AV_CODEC_ID_WMV1, &wmv1 )) || (err = encode( AV_CODEC_ID_WMV2, &wmv2 )))
    {
        printf( "FAIL: the test streams could not be made (%d)\n", err );
        return 1;
    }
    if (off)
    {
        test_switched_off();
        test_wma( "switched off" );
    }
    else
    {
        test_decode( &wmv1, "WMV1" );
        test_decode( &wmv2, "WMV2" );
        /* before the format sweep, whose hundred-odd transforms use up the [wmv] log cap */
        test_refusals();
        test_wmv9_plumbing();
        test_formats();
        test_timestamps();
        test_queue_drain_flush();
        test_set_output_type();
        test_format_change_and_small_buffer();
        test_dmo_loop();
        test_threads();
        test_wow64();
        test_wma( "default" );
    }
    for (err = 0; err < FRAMES; err++) { free( wmv1.packets[err].data ); free( wmv2.packets[err].data ); }
    printf( "%s: %d failure(s), %d checks\n", failures ? "FAIL" : "PASS", failures, checks );
    return failures ? 1 : 0;
}
"""

with tempfile.TemporaryDirectory() as tmp:
    h = Path(tmp) / "wmv_host.c"
    h.write_text(harness)
    exe = Path(tmp) / "wmv_host"
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
        print("FAIL: harness did not compile")
        sys.exit(1)
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=1")
    env.pop("MADEIRA_WG_WMV_TRANSFORM", None)
    for label, extra_env, args, needles in [
        ("default", {}, [], ["[wmv] decoder created fmt=WMV2 176x144 fps=25/1 codec_data=4 -> nv12 176x144",
                             "[decoder not open: no sequence header",
                             "is not a Windows Media video stream",
                             "[wmv] further lines suppressed after 100"]),
        ("MADEIRA_WG_WMV_TRANSFORM=0", {"MADEIRA_WG_WMV_TRANSFORM": "0"}, ["off"],
         ["[wmv] video transform refused: MADEIRA_WG_WMV_TRANSFORM=0"]),
    ]:
        print("--- %s ---" % label, flush=True)
        r = subprocess.run([str(exe)] + args, env=dict(env, **extra_env), capture_output=True, text=True)
        sys.stdout.write(r.stdout)
        check(r.returncode == 0, "harness (%s) exits 0" % label)
        if r.returncode:
            print("\n".join(r.stderr.splitlines()[-40:]))
        for needle in needles:
            check(needle in r.stderr, "log (%s): %s" % (label, needle))
        wmv_lines = [l for l in r.stderr.splitlines() if l.startswith("[wmv]")]
        print("first [wmv] lines (%d in all):\n  " % len(wmv_lines) + "\n  ".join(wmv_lines[:12]))

if failures:
    print("FAILED: %d" % len(failures))
    sys.exit(1)
print("PASS: the WMV video transform")
