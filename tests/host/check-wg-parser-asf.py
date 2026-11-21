#!/usr/bin/env python3
"""Windows Media files (ASF: WMV video, WMA audio) through the wg_parser core, and its back-pressure; no Wine runs.

A Steam visual novel's cutscenes play through the Windows Media Format reader (wmvcore, Wine's
wm_reader.c), a wg_parser user. This port's core knew only MP3, WAV and MP4, so the reader failed to
connect ("no enabled demuxer recognised the stream", 0x80040265) and the game showed a white screen
with no sound. The core now demuxes ASF and decodes Windows Media video in software through
libavcodec (mav_lavc_video in build/ntdll-unix/wg_parser_av_ios.c), and writes every picture format
wm_reader.c offers, its default first: bottom-up 24-bit BGR.

1. Source checks: build/ffmpeg/build.sh enables the asf demuxer and the wmv1/wmv2/wmv3/vc1/msmpeg4v1-3
   decoders (and still no H.264/HEVC/AAC decoder); the glue asserts the new pixel-format values and
   describes WMV / WMA streams by their wg_format codec formats.
2. Builds a host FFmpeg 7.1.5 from the tracked tarball with the port's demuxers and decoders, plus
   TEST-ONLY encoders (wmv1, wmv2, msmpeg4v3, wmav2) and the asf muxer to synthesise inputs. Cached.
3. Compiles the production core under ASan/UBSan with the PE read thread of media_source.c /
   wm_reader.c, and checks, against an independent libavcodec decode of the same file:
   - WMV8 (wmv2) + WMA2: two streams, every picture bit-exact in NV12, in order, at 40 ms steps;
     the WM reader's way (BGR bottom-up video, S16 audio, earliest-buffer reads) to the end;
     every format wm_reader.c offers (NV12 YV12 YUY2 UYVY YVYU BGRx BGR RGB16 RGB15) and I420,
     pixel-checked; keyframe seek with exact trim; the codec formats (WMV2, WMA v2);
   - WMV7 (wmv1) and MS-MPEG4 v3 video decode bit-exact;
   - a WMV3 stream of undecodable data ends the stream (no crash, no hang);
   - compressed output (the WM reader's compressed samples: KiriKiri's movie plugin feeds them to the
     WMV / WMA decoder DMOs): a compressed-output parser exposes the same streams, and every
     packet of WMV8, WMV9 (the undecodable WMV3 too: it is not decoded here) and WMA2 comes out with
     the file's bytes, keyframe flags and timestamps, in order, to the end; compressed video next
     to decoded S16 audio; a seek starts the video at a keyframe; back to decoded pictures, bit-exact;
     MS-MPEG4 (no wg_format) is refused compressed and still decodes; MADEIRA_WG_COMPRESSED=0's
     refusal;
   and, built with small queue limits (a stream that falls behind used to lose packets):
   - a slow video reader and a fast audio reader on two threads: no packet dropped, every picture
     delivered (the same file without back-pressure drops);
   - a video stream that is enabled and never read: the audio reader waits once, then goes on;
   - one thread reading both streams (earliest-buffer mode) never waits for itself;
   - disconnect while a reader waits: it is woken and nothing is freed under it.
Needs python3, a C compiler and the FFmpeg tarball (build/ffmpeg/src).
"""
from pathlib import Path
import os, re, subprocess, sys, tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from host_ffmpeg import host_ffmpeg   # the shared host build, made under a lock

root = Path(__file__).resolve().parents[2]
core = root / "build/ntdll-unix/wg_parser_av_ios.c"
glue = (root / "build/ntdll-unix/winegstreamer_unixlib_ios.c").read_text()

# ------------------------------------------------------------------ 1. source checks
ff = (root / "build/ffmpeg/build.sh").read_text().replace("\r\n", "\n")
args = ff[ff.index("CONFIG_ARGS=("):]
args = args[:args.index("\n)\n")]
assert "--enable-demuxer=mp3,wav,mov,asf" in args, "asf demuxer"
assert "--enable-decoder=wmv1,wmv2,wmv3,vc1,msmpeg4v1,msmpeg4v2,msmpeg4v3" in args, "Windows Media video decoders"
assert "--enable-decoder=wmav1,wmav2,wmapro,wmalossless" in args, "WMA decoders"
for bad in ["h264", "hevc", "aac"]:
    assert not re.search(r"--enable-(decoder|parser)=[^\n]*\b%s\b" % bad, args), ("platform-decoded codec enabled", bad)
for flag in ["--disable-gpl", "--disable-nonfree", "--disable-version3", "--disable-everything"]:
    assert flag in args, ("LGPL-only configuration", flag)
assert "(int)MAV_PIX_BGR == (int)WG_VIDEO_FORMAT_BGR" in glue and "(int)MAV_PIX_YVYU == (int)WG_VIDEO_FORMAT_YVYU" in glue
codec_fmt = glue[glue.rindex("static NTSTATUS wgp_get_codec_format("):]   # the definition, after a declaration
codec_fmt = codec_fmt[:codec_fmt.index("\n}\n")]
assert "case MAV_CODEC_WMA:" in codec_fmt and "WG_MAJOR_TYPE_AUDIO_WMA" in codec_fmt
assert "case MAV_CODEC_WMV:" in codec_fmt and "WG_MAJOR_TYPE_VIDEO_WMV" in codec_fmt
enable = glue[glue.index("static NTSTATUS wgp_enable("):]
enable = enable[:enable.index("\n}\n")]
assert "WG_MAJOR_TYPE_VIDEO_WMV" in enable and "WG_MAJOR_TYPE_AUDIO_WMA" in enable and "mav_enable_compressed(" in enable, \
    "stream_enable takes the compressed formats"
current = glue[glue.index("static NTSTATUS wgp_get_current_format("):]
current = current[:current.index("\n}\n")]
assert "mav_can_pass_compressed(" in current and "wgp_get_codec_format(" in current, \
    "a compressed-output parser's current format is the codec format"
assert 'getenv( "MADEIRA_WG_COMPRESSED" )' in glue and "mav_allow_compressed_asf(" in glue
# Wine's WM reader (the submodule): compressed reading per stream, and a failed reinit keeps the streams
wm = root / "wine/dlls/winegstreamer/wm_reader.c"
if wm.exists():
    w = wm.read_text()
    reinit = w[w.index("static HRESULT reinit_stream("):]
    reinit = reinit[:reinit.index("\n}\n")]
    assert "free_streams(" not in reinit, "a failed reinit must not free the reader's streams"
    assert "stream->read_compressed ? &format : &stream->format" in reinit, "compressed reading is per stream"
    assert "assert(reader->stream_count == wg_parser_get_stream_count" not in reinit, "a stream count mismatch fails, not aborts"
    sss = w[w.index("static HRESULT WINAPI reader_SetReadStreamSamples("):]
    sss = sss[:sss.index("\n}\n")]
    assert "old_compressed" in sss, "SetReadStreamSamples goes back to the previous parser on failure"
    print("PASS: Wine's WM reader reads compressed per stream and keeps its streams when a reinit fails")
print("PASS: FFmpeg has the asf demuxer and the Windows Media decoders (still no H.264/HEVC/AAC); "
      "the glue maps the new pixel formats, the WMV / WMA codec formats and compressed output")

# ------------------------------------------------------------------ 2. host FFmpeg
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
prefix = host_ffmpeg(FLAGS, tarball, tag="asf-", override=os.environ.get("MADEIRA_HOST_FFMPEG_ASF"))
inc, lib = prefix / "include", prefix / "lib"

# ------------------------------------------------------------------ 3. the core under ASan
harness = r"""
#include "wg_parser_av_ios.c"
#include <math.h>
#include <signal.h>

static int failures;
#define CHECK(c, ...) do { if (!(c)) { printf( "FAIL %s:%d: ", __func__, __LINE__ ); printf( __VA_ARGS__ ); printf( "\n" ); fflush( stdout ); failures++; return 1; } } while (0)

#define W 320
#define H 240
#define FPS 25
#define GOP 10
#define FRAMES 100              /* 4 s */
#define RATE 44100

/* ---- the PE side: media_source.c / wm_reader.c read_thread() ---- */
struct source { const uint8_t *data; size_t size; volatile int running; struct mav_parser *p; pthread_t thread; };

static void *read_thread( void *arg )
{
    struct source *s = arg;
    while (__atomic_load_n( &s->running, __ATOMIC_ACQUIRE ))
    {
        uint64_t offset; uint32_t size;
        if (mav_get_next_read_offset( s->p, &offset, &size )) { usleep( 200 ); continue; }
        if (offset >= s->size) size = 0;
        else if (offset + size >= s->size) size = s->size - offset;
        mav_push_data( s->p, size ? s->data + offset : s->data, size );
    }
    return NULL;
}
static void src_start( struct source *s, struct mav_parser *p, const uint8_t *data, size_t size )
{
    memset( s, 0, sizeof(*s) ); s->data = data; s->size = size; s->p = p; s->running = 1;
    pthread_create( &s->thread, NULL, read_thread, s );
}
static void src_stop( struct source *s ) { mav_disconnect( s->p ); __atomic_store_n( &s->running, 0, __ATOMIC_RELEASE ); pthread_join( s->thread, NULL ); }

/* ---- inputs: an ASF made by libavformat's asf muxer in memory ---- */
struct membuf { uint8_t *data; size_t size, cap, pos; };
static int mem_write( void *o, const uint8_t *buf, int n )
{
    struct membuf *m = o;
    if (m->pos + n > m->cap) { m->cap = (m->pos + n) * 2; m->data = realloc( m->data, m->cap ); }
    memcpy( m->data + m->pos, buf, n ); m->pos += n; if (m->pos > m->size) m->size = m->pos;
    return n;
}
static int mem_read( void *o, uint8_t *buf, int n )
{
    struct membuf *m = o;
    if (m->pos >= m->size) return AVERROR_EOF;
    if ((size_t)n > m->size - m->pos) n = (int)(m->size - m->pos);
    memcpy( buf, m->data + m->pos, n ); m->pos += n;
    return n;
}
static int64_t mem_seek( void *o, int64_t off, int whence )
{
    struct membuf *m = o;
    if (whence & AVSEEK_SIZE) return m->size;
    whence &= ~AVSEEK_FORCE;
    if (whence == SEEK_CUR) off += m->pos; else if (whence == SEEK_END) off += m->size;
    if (off < 0) return -1;
    m->pos = off;
    return off;
}

static void put( AVFormatContext *oc, AVCodecContext *e, AVStream *st, AVFrame *f )
{
    AVPacket *pkt = av_packet_alloc();
    avcodec_send_frame( e, f );
    while (avcodec_receive_packet( e, pkt ) >= 0)
    {
        av_packet_rescale_ts( pkt, e->time_base, st->time_base );
        pkt->stream_index = st->index;
        av_interleaved_write_frame( oc, pkt );
    }
    av_packet_free( &pkt );
}

/* `frames` pictures with a moving pattern (and, with audio, a 440 Hz WMA2 tone).
 * vcodec 0: a WMV3 stream of raw garbage packets (no WMV9 encoder exists). */
static uint8_t *make_asf( enum AVCodecID vcodec, int audio, size_t *size )
{
    struct membuf m = {0};
    AVFormatContext *oc; AVCodecContext *ve = NULL, *ae = NULL; AVStream *vs, *as = NULL;
    AVFrame *vf = av_frame_alloc(), *af = av_frame_alloc(); int64_t apts = 0; int i, x, y;

    avformat_alloc_output_context2( &oc, NULL, "asf", NULL );
    oc->pb = avio_alloc_context( av_malloc( 4096 ), 4096, 1, &m, NULL, mem_write, mem_seek );
    vs = avformat_new_stream( oc, NULL );
    if (vcodec)
    {
        ve = avcodec_alloc_context3( avcodec_find_encoder( vcodec ) );
        ve->width = W; ve->height = H; ve->time_base = (AVRational){ 1, FPS }; ve->framerate = (AVRational){ FPS, 1 };
        ve->pix_fmt = AV_PIX_FMT_YUV420P; ve->gop_size = GOP; ve->bit_rate = 800000; ve->max_b_frames = 0;
        if (oc->oformat->flags & AVFMT_GLOBALHEADER) ve->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if (avcodec_open2( ve, ve->codec, NULL ) < 0) return NULL;
        avcodec_parameters_from_context( vs->codecpar, ve );
        vs->time_base = ve->time_base;
    }
    else
    {
        static const uint8_t seq[4] = { 0x4e, 0x29, 0x1a, 0x01 };   /* a WMV3 main-profile sequence header */
        vs->codecpar->codec_type = AVMEDIA_TYPE_VIDEO; vs->codecpar->codec_id = AV_CODEC_ID_WMV3;
        vs->codecpar->codec_tag = MKTAG('W','M','V','3'); vs->codecpar->width = W; vs->codecpar->height = H;
        vs->codecpar->extradata = av_mallocz( 4 + AV_INPUT_BUFFER_PADDING_SIZE ); vs->codecpar->extradata_size = 4;
        memcpy( vs->codecpar->extradata, seq, 4 );
        vs->time_base = (AVRational){ 1, FPS };
    }
    if (audio)
    {
        as = avformat_new_stream( oc, NULL );
        ae = avcodec_alloc_context3( avcodec_find_encoder( AV_CODEC_ID_WMAV2 ) );
        ae->sample_rate = RATE; ae->sample_fmt = AV_SAMPLE_FMT_FLTP; ae->bit_rate = 128000;
        av_channel_layout_default( &ae->ch_layout, 2 ); ae->time_base = (AVRational){ 1, RATE };
        if (avcodec_open2( ae, ae->codec, NULL ) < 0) return NULL;
        avcodec_parameters_from_context( as->codecpar, ae );
        as->time_base = ae->time_base;
    }
    if (avformat_write_header( oc, NULL ) < 0) return NULL;
    vf->format = AV_PIX_FMT_YUV420P; vf->width = W; vf->height = H; av_frame_get_buffer( vf, 0 );
    if (ae)
    {
        af->format = ae->sample_fmt; af->nb_samples = ae->frame_size; af->sample_rate = RATE;
        av_channel_layout_copy( &af->ch_layout, &ae->ch_layout ); av_frame_get_buffer( af, 0 );
    }
    for (i = 0; i < FRAMES; i++)
    {
        av_frame_make_writable( vf );
        for (y = 0; y < H; y++) for (x = 0; x < W; x++)
            vf->data[0][y * vf->linesize[0] + x] = (uint8_t)(32 + ((x + 3 * i) / 16 % 2) * 120 + y / 4);
        for (y = 0; y < H / 2; y++) for (x = 0; x < W / 2; x++)
        {
            vf->data[1][y * vf->linesize[1] + x] = (uint8_t)(90 + x / 2 + i);
            vf->data[2][y * vf->linesize[2] + x] = (uint8_t)(170 - y / 2);
        }
        vf->pts = i;
        if (ve) put( oc, ve, vs, vf );
        else
        {
            /* garbage: a WMV3 decoder rejects it, packet by packet */
            AVPacket *pkt = av_packet_alloc(); int k;
            av_new_packet( pkt, 600 );
            for (k = 0; k < 600; k++) pkt->data[k] = (uint8_t)(k * 131 + i * 17);
            pkt->pts = pkt->dts = i; pkt->stream_index = vs->index; pkt->flags = i % GOP ? 0 : AV_PKT_FLAG_KEY;
            av_packet_rescale_ts( pkt, (AVRational){ 1, FPS }, vs->time_base );
            av_interleaved_write_frame( oc, pkt );
            av_packet_free( &pkt );
        }
        while (ae && apts * FPS < (int64_t)(i + 1) * RATE)
        {
            int c, n;
            av_frame_make_writable( af );
            for (c = 0; c < 2; c++) for (n = 0; n < af->nb_samples; n++)
                ((float *)af->data[c])[n] = 0.4f * sinf( 2 * (float)M_PI * 440 * (apts + n) / RATE );
            af->pts = apts; apts += af->nb_samples;
            put( oc, ae, as, af );
        }
    }
    if (ve) put( oc, ve, vs, NULL );
    if (ae) put( oc, ae, as, NULL );
    av_write_trailer( oc );
    av_freep( &oc->pb->buffer );   /* the AVIO buffer; the file's bytes stay in `m` */
    avio_context_free( &oc->pb );
    avformat_free_context( oc );
    avcodec_free_context( &ve ); avcodec_free_context( &ae ); av_frame_free( &vf ); av_frame_free( &af );
    *size = m.size;
    return m.data;
}

/* ---- the reference: the same file decoded by libavformat + libavcodec directly ---- */
static uint8_t *ref_frames;     /* FRAMES x (Y, U, V) planes, W x H 4:2:0 */
static int ref_count;
#define REF_SIZE (W * H * 3 / 2)

static int make_reference( const uint8_t *data, size_t size )
{
    struct membuf m = { (uint8_t *)data, size, size, 0 };
    AVFormatContext *fc = avformat_alloc_context(); AVCodecContext *d; AVPacket *pkt = av_packet_alloc();
    AVFrame *f = av_frame_alloc(); int vi = -1, y; unsigned int i;

    fc->pb = avio_alloc_context( av_malloc( 4096 ), 4096, 0, &m, mem_read, NULL, mem_seek );
    CHECK( avformat_open_input( &fc, NULL, NULL, NULL ) == 0 && avformat_find_stream_info( fc, NULL ) >= 0, "reference open" );
    for (i = 0; i < fc->nb_streams; i++) if (fc->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) vi = i;
    d = avcodec_alloc_context3( avcodec_find_decoder( fc->streams[vi]->codecpar->codec_id ) );
    avcodec_parameters_to_context( d, fc->streams[vi]->codecpar ); d->thread_count = 1;
    CHECK( avcodec_open2( d, d->codec, NULL ) == 0, "reference decoder" );
    free( ref_frames ); ref_frames = calloc( FRAMES + 8, REF_SIZE ); ref_count = 0;
    for (;;)
    {
        int eof = av_read_frame( fc, pkt ) < 0;
        if (!eof && pkt->stream_index != vi) { av_packet_unref( pkt ); continue; }
        avcodec_send_packet( d, eof ? NULL : pkt );
        av_packet_unref( pkt );
        while (avcodec_receive_frame( d, f ) >= 0)
        {
            uint8_t *o = ref_frames + (size_t)ref_count * REF_SIZE;
            CHECK( f->format == AV_PIX_FMT_YUV420P && f->width == W && f->height == H && ref_count < FRAMES + 8, "reference frame" );
            for (y = 0; y < H; y++) memcpy( o + y * W, f->data[0] + y * f->linesize[0], W );
            for (y = 0; y < H / 2; y++)
            {
                memcpy( o + W * H + y * (W / 2), f->data[1] + y * f->linesize[1], W / 2 );
                memcpy( o + W * H * 5 / 4 + y * (W / 2), f->data[2] + y * f->linesize[2], W / 2 );
            }
            ref_count++;
            av_frame_unref( f );
        }
        if (eof) break;
    }
    avcodec_free_context( &d ); av_frame_free( &f ); av_packet_free( &pkt );
    av_freep( &fc->pb->buffer ); avio_context_free( &fc->pb ); avformat_close_input( &fc );
    return 0;
}

/* The first picture's pts: the asf muxer moves every timestamp up by the WMA
 * encoder's delay (46 ms), so none is negative. */
static int64_t pts0 = -1;

static int RY( int i, int x, int y ) { return ref_frames[(size_t)i * REF_SIZE + y * W + x]; }
static int RU( int i, int x, int y ) { return ref_frames[(size_t)i * REF_SIZE + W * H + (y / 2) * (W / 2) + x / 2]; }
static int RV( int i, int x, int y ) { return ref_frames[(size_t)i * REF_SIZE + W * H * 5 / 4 + (y / 2) * (W / 2) + x / 2]; }

/* One picture of `fmt` against reference picture `idx`: YUV formats exact, RGB within 1 (BT.601, limited). */
static int check_picture( const uint8_t *buf, uint32_t size, enum mav_pixel_format fmt, int flip, int idx, const char *what )
{
    struct mav_layout l; int x, y, maxerr = 0;
    CHECK( size == mav_video_layout( fmt, W, H, &l ), "%s: size %u", what, size );
    for (y = 0; y < H; y++)
    {
        int ry = flip ? H - 1 - y : y;
        const uint8_t *row = buf + (size_t)ry * l.stride[0];
        for (x = 0; x < W; x++)
        {
            int Y = RY( idx, x, y ), U = RU( idx, x, y ), V = RV( idx, x, y ), pair = 4 * (x / 2);
            switch (fmt)
            {
            case MAV_PIX_NV12:
                CHECK( row[x] == Y, "%s Y(%d,%d) %d != %d", what, x, y, row[x], Y );
                if (!(y & 1)) CHECK( buf[l.offset[1] + (ry / 2) * l.stride[1] + (x & ~1)] == U
                                     && buf[l.offset[1] + (ry / 2) * l.stride[1] + (x & ~1) + 1] == V, "%s UV(%d,%d)", what, x, y );
                break;
            case MAV_PIX_I420: case MAV_PIX_YV12:
            {
                int up = fmt == MAV_PIX_I420 ? 1 : 2, vp = 3 - up;
                CHECK( row[x] == Y, "%s Y(%d,%d)", what, x, y );
                if (!(y & 1)) CHECK( buf[l.offset[up] + (ry / 2) * l.stride[up] + x / 2] == U
                                     && buf[l.offset[vp] + (ry / 2) * l.stride[vp] + x / 2] == V, "%s U/V(%d,%d)", what, x, y );
                break;
            }
            case MAV_PIX_YUY2: CHECK( row[2 * x] == Y && row[pair + 1] == U && row[pair + 3] == V, "%s (%d,%d)", what, x, y ); break;
            case MAV_PIX_UYVY: CHECK( row[pair + 1 + 2 * (x & 1)] == Y && row[pair] == U && row[pair + 2] == V, "%s (%d,%d)", what, x, y ); break;
            case MAV_PIX_YVYU: CHECK( row[2 * x] == Y && row[pair + 3] == U && row[pair + 1] == V, "%s (%d,%d)", what, x, y ); break;
            default:
            {
                double yy = 1.164383 * (Y - 16), r = yy + 1.596027 * (V - 128),
                       g = yy - 0.391762 * (U - 128) - 0.812968 * (V - 128), b = yy + 2.017232 * (U - 128);
                int rr = (int)lround( fmin( 255, fmax( 0, r ) ) ), rg = (int)lround( fmin( 255, fmax( 0, g ) ) ),
                    rb = (int)lround( fmin( 255, fmax( 0, b ) ) ), R, G, B, e;
                if (fmt == MAV_PIX_RGB16 || fmt == MAV_PIX_RGB15)
                {
                    unsigned px = row[2 * x] | row[2 * x + 1] << 8; int six = fmt == MAV_PIX_RGB16;
                    R = six ? px >> 11 : (px >> 10) & 31; G = (px >> 5) & (six ? 63 : 31); B = px & 31;
                    CHECK( abs( R - (rr >> 3) ) <= 1 && abs( G - (six ? rg >> 2 : rg >> 3) ) <= 1 && abs( B - (rb >> 3) ) <= 1,
                           "%s (%d,%d)", what, x, y );
                    break;
                }
                if (fmt == MAV_PIX_BGR) { B = row[3 * x]; G = row[3 * x + 1]; R = row[3 * x + 2]; }
                else
                {
                    const uint8_t *px = row + 4 * x;
                    R = fmt == MAV_PIX_RGBA ? px[0] : px[2]; G = px[1]; B = fmt == MAV_PIX_RGBA ? px[2] : px[0];
                    CHECK( px[3] == 0xff, "%s alpha", what );
                }
                e = abs( R - rr ); if (e > maxerr) maxerr = e;
                e = abs( G - rg ); if (e > maxerr) maxerr = e;
                e = abs( B - rb ); if (e > maxerr) maxerr = e;
            }
            }
        }
    }
    CHECK( maxerr <= 1, "%s: RGB error %d", what, maxerr );
    return 0;
}

/* ================= WMV + WMA ================= */
static int test_wmv( const uint8_t *asf, size_t size, const char *codec )
{
    struct mav_parser *p = mav_create( 0 ); struct source s; struct mav_stream_info vi, ai; struct mav_buffer b;
    struct mav_output ao; uint8_t *pic = malloc( W * H * 4 ); int n = 0;

    CHECK( !make_reference( asf, size ) && ref_count == FRAMES, "reference: %d pictures", ref_count );
    src_start( &s, p, asf, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "%s: connect", codec );
    CHECK( mav_stream_count( p ) == 2 && mav_stream_info( p, 0, &vi ) == MAV_OK && mav_stream_info( p, 1, &ai ) == MAV_OK, "two streams" );
    CHECK( vi.type == MAV_STREAM_VIDEO && vi.kind == MAV_CODEC_WMV && !strcmp( vi.container, "asf" )
           && !strcmp( vi.backend, "libavcodec" ) && !strcmp( vi.codec, codec ) && vi.vnative.fmt == MAV_PIX_NV12
           && vi.vnative.width == W && vi.vnative.height == H && vi.vnative.fps_n * 1 == FPS * vi.vnative.fps_d,
           "video info: %s %s %s %dx%d %u/%u", vi.codec, vi.container, vi.backend, vi.vnative.width, vi.vnative.height,
           vi.vnative.fps_n, vi.vnative.fps_d );
    CHECK( ai.type == MAV_STREAM_AUDIO && ai.kind == MAV_CODEC_WMA && ai.version == 2 && ai.native.rate == RATE
           && ai.native.channels == 2 && ai.native.fmt == MAV_FMT_S16 && ai.block_align > 0 && ai.codec_data_len > 0,
           "audio info: v%u %u Hz %u ch align %u", ai.version, ai.native.rate, ai.native.channels, ai.block_align );
    CHECK( llabs( (long long)vi.info_duration_check_dummy_never ) >= 0, "" );
    /* every picture, NV12, in order, bit-exact against the reference */
    while (mav_get_buffer( p, 0, &b ) == MAV_OK)
    {
        if (!n) pts0 = b.pts;
        CHECK( b.stream == 0 && pts0 < 1000000 && llabs( (long long)(b.pts - pts0) - (long long)n * 10000000 / FPS ) <= 10000,
               "picture %d pts %llu (first %lld)", n, (unsigned long long)b.pts, (long long)pts0 );
        CHECK( mav_copy_buffer( p, 0, pic, 0, b.size ) == MAV_OK, "copy" );
        if (check_picture( pic, b.size, MAV_PIX_NV12, 0, n, "nv12" )) return 1;
        mav_release_buffer( p, 0 ); n++;
    }
    CHECK( n == FRAMES, "%s: %d pictures, want %d", codec, n, FRAMES );
    src_stop( &s ); mav_destroy( p ); free( pic );
    printf( "PASS: %s in ASF: %d pictures, bit-exact NV12 against libavcodec, in order at 40 ms steps; WMA2 stream described\n", codec, n );
    (void)ao;
    return 0;
}
"""
# a placeholder check slipped into the template above is removed here (keeps the C valid)
harness = harness.replace('    CHECK( llabs( (long long)vi.info_duration_check_dummy_never ) >= 0, "" );\n', '')

harness += r"""
/* The WM reader's way: video BGR bottom-up, audio S16, both enabled, earliest-buffer reads to the end. */
static int test_wm_reader( const uint8_t *asf, size_t size )
{
    struct mav_parser *p = mav_create( 0 ); struct source s; struct mav_stream_info vi; struct mav_buffer b;
    uint8_t *buf = malloc( 1 << 20 ); int pictures = 0; int64_t samples = 0, last_a = -1, last_v = -1; double sq = 0;

    src_start( &s, p, asf, size );
    CHECK( mav_connect( p, size ) == MAV_OK && mav_stream_info( p, 0, &vi ) == MAV_OK, "connect" );
    {
        struct mav_video_output o = vi.vnative; o.fmt = MAV_PIX_BGR; o.height = -H;
        CHECK( mav_enable_video( p, 0, &o ) == MAV_OK, "BGR bottom-up (wm_reader.c's default)" );
        CHECK( mav_enable( p, 1, &(struct mav_output){ MAV_FMT_S16, RATE, 2, 3 } ) == MAV_OK, "S16 (wm_reader.c's default)" );
        CHECK( mav_seek( p, 0, 1, 0, 0, 0 ) == MAV_OK, "seek to 0 (wm_reader.c after enabling)" );
    }
    while (mav_get_buffer( p, -1, &b ) == MAV_OK)
    {
        CHECK( b.size <= (1 << 20) && mav_copy_buffer( p, b.stream, buf, 0, b.size ) == MAV_OK, "copy" );
        if (b.stream == 0)
        {
            CHECK( (int64_t)b.pts > last_v, "video pts goes forward" ); last_v = b.pts;
            if (pictures % 17 == 0 && check_picture( buf, b.size, MAV_PIX_BGR, 1, pictures, "bgr bottom-up" )) return 1;
            pictures++;
        }
        else
        {
            int k; const int16_t *pcm = (const int16_t *)buf;
            CHECK( (int64_t)b.pts >= last_a, "audio pts goes forward" ); last_a = b.pts;
            for (k = 0; k < (int)(b.size / 2); k++) sq += (double)pcm[k] * pcm[k];
            samples += b.size / 4;
        }
        mav_release_buffer( p, b.stream );
    }
    CHECK( pictures == FRAMES, "%d pictures", pictures );
    CHECK( llabs( samples - (int64_t)RATE * FRAMES / FPS ) < 4096, "%lld audio frames", (long long)samples );
    CHECK( sqrt( sq / (samples * 2) ) > 4000, "the tone is there" );
    src_stop( &s ); mav_destroy( p ); free( buf );
    printf( "PASS: the WM reader's way: BGR bottom-up + S16, earliest-buffer reads: %d pictures (checked within 1), "
            "%.2f s of WMA2 audio (rms %.0f)\n", pictures, (double)samples / RATE, sqrt( sq / (samples * 2) ) );
    return 0;
}

static int test_formats( const uint8_t *asf, size_t size )
{
    static const struct { enum mav_pixel_format fmt; int flip; const char *name; } fmts[] =
    {
        /* wm_reader.c's video_formats[], then I420 / RGBA / BGRA */
        { MAV_PIX_NV12, 0, "nv12" }, { MAV_PIX_YV12, 0, "yv12" }, { MAV_PIX_YUY2, 0, "yuy2" }, { MAV_PIX_UYVY, 0, "uyvy" },
        { MAV_PIX_YVYU, 0, "yvyu" }, { MAV_PIX_BGRx, 1, "bgrx bottom-up" }, { MAV_PIX_BGR, 1, "bgr bottom-up" },
        { MAV_PIX_RGB16, 1, "rgb16 bottom-up" }, { MAV_PIX_RGB15, 1, "rgb15 bottom-up" },
        { MAV_PIX_I420, 0, "i420" }, { MAV_PIX_RGBA, 0, "rgba" }, { MAV_PIX_BGRA, 0, "bgra" }, { MAV_PIX_BGR, 0, "bgr" },
    };
    struct mav_parser *p = mav_create( 0 ); struct source s; struct mav_stream_info vi; unsigned int i;
    uint8_t *pic = malloc( W * H * 4 );

    src_start( &s, p, asf, size );
    CHECK( mav_connect( p, size ) == MAV_OK && mav_stream_info( p, 0, &vi ) == MAV_OK, "connect" );
    mav_disable( p, 1 );
    for (i = 0; i < sizeof(fmts) / sizeof(fmts[0]); i++)
    {
        struct mav_video_output o = vi.vnative; struct mav_buffer b;
        int target = 23;   /* not a keyframe: decoded from 20, trimmed to 23 */
        o.fmt = fmts[i].fmt; o.height = fmts[i].flip ? -H : H;
        CHECK( mav_enable_video( p, 0, &o ) == MAV_OK, "enable %s", fmts[i].name );
        CHECK( mav_seek( p, 0, 1, (uint64_t)(pts0 + (int64_t)target * 10000000 / FPS), 0, 0 ) == MAV_OK, "seek" );
        CHECK( mav_get_buffer( p, 0, &b ) == MAV_OK, "get %s", fmts[i].name );
        CHECK( llabs( (long long)(b.pts - pts0) - (long long)target * 10000000 / FPS ) <= 10000, "%s: first pts after the seek %llu",
               fmts[i].name, (unsigned long long)b.pts );
        CHECK( mav_copy_buffer( p, 0, pic, 0, b.size ) == MAV_OK, "copy" );
        if (check_picture( pic, b.size, fmts[i].fmt, fmts[i].flip, target, fmts[i].name )) return 1;
        mav_release_buffer( p, 0 );
    }
    src_stop( &s ); mav_destroy( p ); free( pic );
    printf( "PASS: every format wm_reader.c offers (nv12 yv12 yuy2 uyvy yvyu bgrx bgr rgb16 rgb15) and i420 rgba bgra, "
            "checked against the reference after a keyframe seek with exact trim\n" );
    return 0;
}

static int test_garbage_wmv3( const uint8_t *asf, size_t size )
{
    struct mav_parser *p = mav_create( 0 ); struct source s; struct mav_buffer b; int got = 0;
    struct timespec t0, t1;

    src_start( &s, p, asf, size );
    clock_gettime( CLOCK_MONOTONIC, &t0 );
    if (mav_connect( p, size ) == MAV_OK)
        while (mav_get_buffer( p, 0, &b ) == MAV_OK) { got++; mav_release_buffer( p, 0 ); }
    clock_gettime( CLOCK_MONOTONIC, &t1 );
    CHECK( t1.tv_sec - t0.tv_sec < 10, "ends, does not hang" );
    src_stop( &s ); mav_destroy( p );
    printf( "PASS: a WMV3 stream of undecodable data ends without a crash (%d pictures out)\n", got );
    return 0;
}

/* ================= back-pressure, small limits ================= */
struct reader { struct mav_parser *p; int stream, delay_us, count; volatile int done; pthread_t thread; };
static void *reader_thread( void *arg )
{
    struct reader *r = arg; struct mav_buffer b;
    while (mav_get_buffer( r->p, r->stream, &b ) == MAV_OK)
    {
        mav_release_buffer( r->p, r->stream ); r->count++;
        if (r->delay_us) usleep( r->delay_us );
    }
    r->done = 1;
    return NULL;
}

static int test_backpressure( const uint8_t *asf, size_t size )
{
    struct mav_parser *p; struct source s; struct reader v, a; struct timespec t0, t1; int waited;

    /* 1. two threads, video slow: nothing dropped, every picture delivered */
    p = mav_create( 0 ); src_start( &s, p, asf, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "connect" );
    v = (struct reader){ p, 0, 3000 }; a = (struct reader){ p, 1, 0 };
    pthread_create( &v.thread, NULL, reader_thread, &v );
    pthread_create( &a.thread, NULL, reader_thread, &a );
    pthread_join( a.thread, NULL ); pthread_join( v.thread, NULL );
    CHECK( v.count == FRAMES, "slow video reader: %d pictures of %d", v.count, FRAMES );
    CHECK( a.count > 0, "audio" );
    src_stop( &s ); mav_destroy( p );
    printf( "BP1 %d %d\n", v.count, a.count );

    /* 2. video enabled and never read: the audio reader waits once, then reads to the end */
    p = mav_create( 0 ); src_start( &s, p, asf, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "connect" );
    a = (struct reader){ p, 1, 0 };
    clock_gettime( CLOCK_MONOTONIC, &t0 );
    reader_thread( &a );
    clock_gettime( CLOCK_MONOTONIC, &t1 );
    CHECK( a.count > 0 && (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000 < 3 * MAV_BACKPRESSURE_WAIT_MS,
           "audio alone finished in time" );
    src_stop( &s ); mav_destroy( p );

    /* 3. one thread, both streams (earliest-buffer mode): it never waits for itself */
    p = mav_create( 0 ); src_start( &s, p, asf, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "connect" );
    {
        struct mav_buffer b; int n = 0;
        clock_gettime( CLOCK_MONOTONIC, &t0 );
        while (mav_get_buffer( p, -1, &b ) == MAV_OK) { mav_release_buffer( p, b.stream ); n += b.stream == 0; }
        clock_gettime( CLOCK_MONOTONIC, &t1 );
        CHECK( n == FRAMES && (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000 < MAV_BACKPRESSURE_WAIT_MS,
               "earliest-buffer mode: %d pictures, no wait", n );
    }
    src_stop( &s ); mav_destroy( p );

    /* 5. one thread that read the audio once, then only the video (decoded ahead): the worker
     *    reads for that thread, so it never waits for the audio that thread would drain */
    p = mav_create( 0 ); src_start( &s, p, asf, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "connect" );
    {
        struct mav_buffer b; int n = 0;
        CHECK( mav_get_buffer( p, 1, &b ) == MAV_OK, "one audio buffer" );
        mav_release_buffer( p, 1 );
        clock_gettime( CLOCK_MONOTONIC, &t0 );
        while (mav_get_buffer( p, 0, &b ) == MAV_OK) { mav_release_buffer( p, 0 ); n++; }
        clock_gettime( CLOCK_MONOTONIC, &t1 );
        CHECK( n == FRAMES && (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000 < MAV_BACKPRESSURE_WAIT_MS,
               "video alone after an audio read: %d pictures, %ld ms", n,
               (long)((t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000) );
    }
    src_stop( &s ); mav_destroy( p );

    /* 4. disconnect while a reader waits: it is woken, nothing is freed under it */
    p = mav_create( 0 ); src_start( &s, p, asf, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "connect" );
    a = (struct reader){ p, 1, 0 };
    pthread_create( &a.thread, NULL, reader_thread, &a );
    for (waited = 0; waited < 200; waited++)
    {
        unsigned int w;
        pthread_mutex_lock( &p->lock ); w = p->bp_waiters; pthread_mutex_unlock( &p->lock );
        if (w) break;
        usleep( 1000 );
    }
    CHECK( waited < 200, "the audio reader waits for the unread video stream" );
    clock_gettime( CLOCK_MONOTONIC, &t0 );
    src_stop( &s );
    pthread_join( a.thread, NULL );
    clock_gettime( CLOCK_MONOTONIC, &t1 );
    CHECK( a.done && (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000 < MAV_BACKPRESSURE_WAIT_MS,
           "disconnect woke the waiting reader at once" );
    mav_destroy( p );
    printf( "PASS: back-pressure (soft %d packets, hard %d): a slow video reader on its own thread gets all %d pictures; "
            "an unread stream holds the other reader once (%d ms) and no longer; one thread reading both never waits, "
            "nor does the worker decoding ahead for it; disconnect wakes a waiting reader\n", MAV_QUEUE_SOFT_PACKETS, MAV_QUEUE_MAX_PACKETS, FRAMES,
            MAV_BACKPRESSURE_WAIT_MS );
    return 0;
}


/* ================= compressed output (the WM reader's compressed samples) ================= */
struct refpkt { int stream, key, size; int64_t pts; uint8_t *data; };
static struct refpkt *ref_pkts;
static int ref_pkt_count;

static void free_packet_reference( void )
{
    int i;
    for (i = 0; i < ref_pkt_count; i++) free( ref_pkts[i].data );
    free( ref_pkts ); ref_pkts = NULL; ref_pkt_count = 0;
}

/* every packet of the file, as libavformat demuxes it on its own */
static int make_packet_reference( const uint8_t *data, size_t size )
{
    struct membuf m = { (uint8_t *)data, size, size, 0 };
    AVFormatContext *fc = avformat_alloc_context(); AVPacket *pkt = av_packet_alloc();

    free_packet_reference();
    fc->pb = avio_alloc_context( av_malloc( 4096 ), 4096, 0, &m, mem_read, NULL, mem_seek );
    CHECK( avformat_open_input( &fc, NULL, NULL, NULL ) == 0 && avformat_find_stream_info( fc, NULL ) >= 0, "reference open" );
    while (av_read_frame( fc, pkt ) >= 0)
    {
        if (pkt->size)
        {
            struct refpkt *r;
            ref_pkts = realloc( ref_pkts, (ref_pkt_count + 1) * sizeof(*ref_pkts) );
            r = &ref_pkts[ref_pkt_count++];
            r->stream = pkt->stream_index; r->key = !!(pkt->flags & AV_PKT_FLAG_KEY); r->size = pkt->size;
            r->pts = av_rescale_q( pkt->pts, fc->streams[pkt->stream_index]->time_base, (AVRational){ 1, 10000000 } );
            r->data = malloc( pkt->size ); memcpy( r->data, pkt->data, pkt->size );
        }
        av_packet_unref( pkt );
    }
    av_packet_free( &pkt );
    av_freep( &fc->pb->buffer ); avio_context_free( &fc->pb ); avformat_close_input( &fc );
    return 0;
}

/* KiriKiri's way: both streams compressed, earliest-buffer reads to the end */
static int test_compressed( const uint8_t *asf, size_t size, const char *codec, int streams )
{
    struct mav_parser *p = mav_create( 1 ); struct source s; struct mav_stream_info vi; struct mav_buffer b;
    uint8_t *buf = malloc( 1 << 20 ); int next[2] = { 0, 0 }, count[2] = { 0, 0 }, want[2] = { 0, 0 }, i;
    int64_t last_v = -1;

    CHECK( !make_packet_reference( asf, size ), "packet reference" );
    for (i = 0; i < ref_pkt_count; i++) want[ref_pkts[i].stream]++;
    src_start( &s, p, asf, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "%s: a compressed-output parser connects", codec );
    CHECK( (int)mav_stream_count( p ) == streams, "%s: %u streams, as decoded", codec, mav_stream_count( p ) );
    CHECK( mav_stream_info( p, 0, &vi ) == MAV_OK && vi.kind == MAV_CODEC_WMV && !strcmp( vi.codec, codec )
           && vi.vnative.width == W && vi.vnative.height == H, "%s: video info", codec );
    for (i = 0; i < streams; i++)
    {
        CHECK( mav_can_pass_compressed( p, i ), "%s: stream %d passes compressed", codec, i );
        CHECK( mav_enable_compressed( p, i ) == MAV_OK, "%s: stream %d enabled compressed", codec, i );
    }
    CHECK( mav_seek( p, 0, 1, 0, 0, 0 ) == MAV_OK, "seek to 0 (wm_reader.c after enabling)" );
    while (mav_get_buffer( p, -1, &b ) == MAV_OK)
    {
        int st = b.stream; const struct refpkt *r;
        CHECK( st < streams, "stream %d", st );
        while (next[st] < ref_pkt_count && ref_pkts[next[st]].stream != st) next[st]++;
        CHECK( next[st] < ref_pkt_count, "%s: stream %d: more packets than the file has", codec, st );
        r = &ref_pkts[next[st]++];
        CHECK( b.size == (uint32_t)r->size && b.size <= (1 << 20) && mav_copy_buffer( p, st, buf, 0, b.size ) == MAV_OK
               && !memcmp( buf, r->data, b.size ), "%s: stream %d packet %d: the file's %d bytes (got %u)", codec, st,
               count[st], r->size, b.size );
        CHECK( b.delta == !r->key, "%s: stream %d packet %d: keyframe flag", codec, st, count[st] );
        CHECK( llabs( (long long)b.pts - (long long)(r->pts > 0 ? r->pts : 0) ) <= 1, "%s: stream %d packet %d: pts %llu, file %lld",
               codec, st, count[st], (unsigned long long)b.pts, (long long)r->pts );
        if (!count[st]) CHECK( b.discontinuity, "%s: stream %d starts with a discontinuity", codec, st );
        else CHECK( !b.discontinuity, "%s: stream %d packet %d: no discontinuity", codec, st, count[st] );
        if (st == 0)
        {
            if (!count[0]) CHECK( !b.delta, "%s: the first picture is a keyframe", codec );
            CHECK( (int64_t)b.pts > last_v && b.duration == 10000000 / FPS, "%s: picture %d pts %llu dur %llu", codec,
                   count[0], (unsigned long long)b.pts, (unsigned long long)b.duration );
            last_v = b.pts;
        }
        count[st]++;
        mav_release_buffer( p, st );
    }
    CHECK( count[0] == FRAMES && count[0] == want[0], "%s: %d pictures, the file has %d", codec, count[0], want[0] );
    if (streams > 1) CHECK( count[1] == want[1] && count[1] > 0, "%s: %d WMA packets, the file has %d", codec, count[1], want[1] );
    src_stop( &s ); mav_destroy( p ); free( buf );
    printf( "PASS: compressed %s%s in ASF: all %d pictures%s with the file's bytes, keyframe flags and timestamps, in order\n",
            codec, streams > 1 ? " + WMA2" : "", count[0], streams > 1 ? " and WMA packets" : "" );
    return 0;
}

/* compressed video next to decoded audio; a seek; back to decoded video */
static int test_compressed_mixed( const uint8_t *asf, size_t size )
{
    struct mav_parser *p = mav_create( 1 ); struct source s; struct mav_stream_info vi; struct mav_buffer b;
    uint8_t *buf = malloc( 1 << 20 ); int pictures = 0, n = 0; int64_t samples = 0, target = 2 * 10000000LL; double sq = 0;

    CHECK( !make_reference( asf, size ) && ref_count == FRAMES, "reference" );
    src_start( &s, p, asf, size );
    CHECK( mav_connect( p, size ) == MAV_OK && mav_stream_info( p, 0, &vi ) == MAV_OK, "connect" );
    CHECK( mav_enable_compressed( p, 0 ) == MAV_OK, "video compressed" );
    CHECK( mav_enable( p, 1, &(struct mav_output){ MAV_FMT_S16, RATE, 2, 3 } ) == MAV_OK, "audio decoded in the same parser" );
    CHECK( mav_seek( p, 0, 1, 0, 0, 0 ) == MAV_OK, "seek to 0" );
    while (mav_get_buffer( p, -1, &b ) == MAV_OK)
    {
        CHECK( b.size <= (1 << 20) && mav_copy_buffer( p, b.stream, buf, 0, b.size ) == MAV_OK, "copy" );
        if (b.stream == 0) pictures++;
        else
        {
            int k; const int16_t *pcm = (const int16_t *)buf;
            for (k = 0; k < (int)(b.size / 2); k++) sq += (double)pcm[k] * pcm[k];
            samples += b.size / 4;
        }
        mav_release_buffer( p, b.stream );
    }
    CHECK( pictures == FRAMES, "%d packets", pictures );
    CHECK( llabs( samples - (int64_t)RATE * FRAMES / FPS ) < 4096 && sqrt( sq / (samples * 2) ) > 4000,
           "%lld audio frames of the tone", (long long)samples );

    /* a seek: the video starts at a keyframe at or before the target */
    CHECK( mav_seek( p, 0, 1, (uint64_t)target, 0, 0 ) == MAV_OK, "seek to 2 s" );
    CHECK( mav_get_buffer( p, 0, &b ) == MAV_OK && !b.delta && b.discontinuity && (int64_t)b.pts <= target + 10000
           && (int64_t)b.pts > target - 2 * GOP * 10000000LL / FPS, "after the seek: delta %d disc %d pts %llu", b.delta,
           b.discontinuity, (unsigned long long)b.pts );
    mav_release_buffer( p, 0 );

    /* decoded pictures again: a seek to 0 and every picture bit-exact */
    {
        struct mav_video_output o = vi.vnative; o.fmt = MAV_PIX_NV12;
        CHECK( mav_enable_video( p, 0, &o ) == MAV_OK, "back to NV12" );
    }
    mav_disable( p, 1 );
    CHECK( mav_seek( p, 0, 1, 0, 0, 0 ) == MAV_OK, "seek to 0" );
    while (mav_get_buffer( p, 0, &b ) == MAV_OK)
    {
        CHECK( mav_copy_buffer( p, 0, buf, 0, b.size ) == MAV_OK, "copy" );
        if (check_picture( buf, b.size, MAV_PIX_NV12, 0, n, "nv12 after compressed" )) return 1;
        mav_release_buffer( p, 0 ); n++;
    }
    CHECK( n == FRAMES, "%d pictures after compressed reading", n );
    src_stop( &s ); mav_destroy( p ); free( buf );
    printf( "PASS: compressed WMV8 next to decoded S16 (%.2f s, rms %.0f) in one parser; a seek to 2 s starts the video "
            "at a keyframe; back to decoded, %d pictures bit-exact\n", (double)samples / RATE, sqrt( sq / (samples * 2) ), n );
    return 0;
}

/* MS-MPEG4 has no wg_format: refused compressed, decoded in the same parser; the kill switch */
static int test_compressed_refusals( const uint8_t *mp43, size_t n3, const uint8_t *wmv2, size_t n2 )
{
    struct mav_parser *p = mav_create( 1 ); struct source s; struct mav_stream_info vi; struct mav_buffer b; int n = 0;

    src_start( &s, p, mp43, n3 );
    CHECK( mav_connect( p, n3 ) == MAV_OK && mav_stream_count( p ) == 2 && mav_stream_info( p, 0, &vi ) == MAV_OK,
           "msmpeg4v3: a compressed-output parser connects, both streams" );
    CHECK( !mav_can_pass_compressed( p, 0 ) && mav_can_pass_compressed( p, 1 ), "msmpeg4v3 video is not passed compressed, WMA is" );
    CHECK( mav_enable_compressed( p, 0 ) == MAV_E_PARAM, "msmpeg4v3: compressed refused" );
    CHECK( mav_get_buffer( p, 0, &b ) == MAV_NO_BUFFER, "and the stream is disabled" );
    {
        struct mav_video_output o = vi.vnative; o.fmt = MAV_PIX_NV12;
        CHECK( mav_enable_video( p, 0, &o ) == MAV_OK, "msmpeg4v3 decoded" );
    }
    mav_disable( p, 1 );
    CHECK( mav_seek( p, 0, 1, 0, 0, 0 ) == MAV_OK, "seek" );
    while (mav_get_buffer( p, 0, &b ) == MAV_OK) { CHECK( b.size == W * H * 3 / 2, "nv12 size" ); mav_release_buffer( p, 0 ); n++; }
    CHECK( n == FRAMES, "%d msmpeg4v3 pictures", n );
    src_stop( &s ); mav_destroy( p );

    mav_allow_compressed_asf( 0 );
    p = mav_create( 1 ); src_start( &s, p, wmv2, n2 );
    CHECK( mav_connect( p, n2 ) == MAV_E_UNSUPPORTED, "MADEIRA_WG_COMPRESSED=0: a compressed-output parser refuses an ASF" );
    src_stop( &s ); mav_destroy( p );
    mav_allow_compressed_asf( 1 );
    p = mav_create( 0 ); src_start( &s, p, wmv2, n2 );
    CHECK( mav_connect( p, n2 ) == MAV_OK && !mav_can_pass_compressed( p, 0 ) && mav_enable_compressed( p, 0 ) == MAV_E_PARAM,
           "a decoding parser does not pass compressed" );
    src_stop( &s ); mav_destroy( p );
    printf( "PASS: MS-MPEG4 refused compressed and decoded in the same parser (%d pictures); MADEIRA_WG_COMPRESSED=0 "
            "refuses the ASF; a decoding parser never passes compressed\n", n );
    return 0;
}

int main( int argc, char **argv )
{
    size_t n2, n1, n3, ng;
    uint8_t *wmv2, *wmv1, *mp43, *garbage;

    alarm( 120 );
    setvbuf( stdout, NULL, _IONBF, 0 );
    av_log_set_level( AV_LOG_ERROR );   /* the test encoders' warnings */
    mav_configure( 1, NULL, NULL, MAV_PIX_NV12 );   /* no platform backend: Windows Media video needs none */
    wmv2 = make_asf( AV_CODEC_ID_WMV2, 1, &n2 );
    CHECK( wmv2, "make the wmv2 file" );
    if (argc > 1 && !strcmp( argv[1], "bp" ))
    {
        if (test_backpressure( wmv2, n2 )) return 1;
        free( wmv2 ); free( ref_frames );
        return failures != 0;
    }
    wmv1 = make_asf( AV_CODEC_ID_WMV1, 1, &n1 );
    mp43 = make_asf( AV_CODEC_ID_MSMPEG4V3, 1, &n3 );
    garbage = make_asf( AV_CODEC_ID_NONE, 0, &ng );
    CHECK( wmv1 && mp43 && garbage, "make the other files" );
    CHECK( mav_lavc_supports( MAV_LAVC_WMV3 ) && mav_lavc_supports( MAV_LAVC_VC1 ), "WMV9 / VC-1 decoders are built" );
    if (test_wmv( wmv2, n2, "wmv2" ) || test_wm_reader( wmv2, n2 ) || test_formats( wmv2, n2 )) return 1;
    if (test_wmv( wmv1, n1, "wmv1" ) || test_wmv( mp43, n3, "msmpeg4v3" ) || test_garbage_wmv3( garbage, ng )) return 1;
    if (test_compressed( wmv2, n2, "wmv2", 2 ) || test_compressed( wmv1, n1, "wmv1", 2 )
        || test_compressed( garbage, ng, "wmv3", 1 ) || test_compressed_mixed( wmv2, n2 )
        || test_compressed_refusals( mp43, n3, wmv2, n2 ))
        return 1;
    free_packet_reference();
    free( wmv2 ); free( wmv1 ); free( mp43 ); free( garbage ); free( ref_frames );
    return failures != 0;
}
"""

TAG = "[wg-parser] ml1990 "
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "asf.c"; c.write_text(harness)
    base = ["cc", "-std=gnu11", "-O1", "-g", "-Wall", "-Wno-unused-function", "-fsanitize=address,undefined",
            "-fno-sanitize-recover=undefined", "-I" + str(core.parent), "-I" + str(inc), str(c)]
    libs = [str(lib / "libavformat.a"), str(lib / "libavcodec.a"), str(lib / "libswresample.a"),
            str(lib / "libavutil.a"), "-lm", "-lpthread"]
    exe, bp = Path(t) / "asf", Path(t) / "asf-bp"
    subprocess.run(base + ["-o", str(exe)] + libs, check=True)
    small = ["-DMAV_QUEUE_SOFT_PACKETS=8", "-DMAV_QUEUE_SOFT_BYTES=65536", "-DMAV_QUEUE_MAX_PACKETS=16",
             "-DMAV_BACKPRESSURE_WAIT_MS=400"]
    subprocess.run(base + small + ["-o", str(bp)] + libs, check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
    env["ASAN_OPTIONS"] = "detect_leaks=1"

    out = subprocess.run([str(exe)], env=env, capture_output=True, text=True, timeout=300)
    print(out.stdout, end="")
    assert out.returncode == 0, out.stdout + out.stderr[-4000:]
    lines = [l for l in out.stderr.splitlines() if l.startswith(TAG)]
    assert any("connect container=asf stream=0 video codec=wmv2 backend=libavcodec 320x240 fps=25/1 out=nv12" in l for l in lines), lines
    assert any("connect container=asf codec=wmav2" in l and "rate=44100 channels=2" in l and "backend=libavcodec" in l for l in lines), lines
    assert any("video codec=wmv1 backend=libavcodec" in l for l in lines) and any("video codec=msmpeg4v3 backend=libavcodec" in l for l in lines), lines
    assert any("wmv3" in l and ("packet rejected" in l or "undecodable" in l or "connect refused" in l) for l in lines), lines
    assert not any("dropping further packets" in l for l in lines), lines
    assert any("connect container=asf stream=0 video codec=wmv2 backend=libavcodec 320x240 fps=25/1 out=compressed" in l
               for l in lines), lines
    assert any("first compressed packet delivered (wmv2" in l for l in lines) and \
        any("first compressed packet delivered (wmav2" in l for l in lines), lines
    assert any("connect refused (asf, compressed_out=1): compressed output requested" in l for l in lines), lines
    assert "ERROR: AddressSanitizer" not in out.stderr and "runtime error" not in out.stderr, out.stderr[-4000:]

    out = subprocess.run([str(bp), "bp"], env=env, capture_output=True, text=True, timeout=300)
    print(out.stdout.replace("BP1 ", "  (slow video, fast audio: pictures, audio buffers) "), end="")
    assert out.returncode == 0, out.stdout + out.stderr[-4000:]
    bp_lines = [l for l in out.stderr.splitlines() if l.startswith(TAG)]
    # case 1 (two readers) drops nothing; case 2 (video never read) marks it unread once, then drops past the hard limit
    first = out.stderr[:out.stderr.index("not read for")] if "not read for" in out.stderr else out.stderr
    assert "dropping further packets" not in first, "a packet was dropped while both streams were read:\n" + first[-3000:]
    assert sum("stream 0: not read for 400 ms while stream 1 reads ahead" in l for l in bp_lines) >= 1, bp_lines
    assert "ERROR: AddressSanitizer" not in out.stderr and "runtime error" not in out.stderr, out.stderr[-4000:]

    # the same two-reader case WITHOUT back-pressure (soft limit above the hard one) does drop:
    # the case the change is for
    nobp = Path(t) / "asf-nobp"
    subprocess.run(base + ["-DMAV_QUEUE_SOFT_PACKETS=100000", "-DMAV_QUEUE_SOFT_BYTES=((size_t)1<<40)",
                           "-DMAV_QUEUE_MAX_PACKETS=16", "-DMAV_BACKPRESSURE_WAIT_MS=400", "-o", str(nobp)] + libs, check=True)
    out = subprocess.run([str(nobp), "bp"], env=env, capture_output=True, text=True, timeout=300)
    assert "dropping further packets" in out.stderr and "FAIL test_backpressure" in out.stdout and "slow video reader" in out.stdout, \
        out.stdout + out.stderr[-2000:]
    print("PASS: without back-pressure the same slow-video case drops packets and loses pictures (%s)" %
          re.search(r"slow video reader: \d+ pictures of \d+", out.stdout).group(0))

    # ThreadSanitizer: the decode-ahead worker beside the WM reader's and the back-pressure readers
    tsan_flags = [f for f in base if not f.startswith("-fsanitize") and f != "-fno-sanitize-recover=undefined"]
    tsan = Path(t) / "asf-tsan"
    r = subprocess.run(tsan_flags + ["-fsanitize=thread", "-o", str(tsan)] + libs, capture_output=True, text=True)
    tsan_bp = Path(t) / "asf-tsan-bp"
    r2 = subprocess.run(tsan_flags + small + ["-fsanitize=thread", "-o", str(tsan_bp)] + libs, capture_output=True, text=True)
    if r.returncode or r2.returncode:
        print("NOTOOL: no ThreadSanitizer build here")
    else:
        tenv = {k: v for k, v in env.items() if k != "ASAN_OPTIONS"}
        tenv["TSAN_OPTIONS"] = "halt_on_error=1"
        for exe_, args_ in [(tsan, []), (tsan_bp, ["bp"])]:
            out = subprocess.run([str(exe_)] + args_, env=tenv, capture_output=True, text=True, timeout=900)
            assert out.returncode == 0 and "WARNING: ThreadSanitizer" not in out.stderr, out.stdout + out.stderr[-6000:]
        print("PASS: ThreadSanitizer clean: every ASF case above, the back-pressure ones included, with video decoded ahead")
    for l in lines + bp_lines:
        print("  " + l)
