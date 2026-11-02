#!/usr/bin/env python3
"""winegstreamer's wg_parser on libavformat (build/ntdll-unix/wg_parser_av_ios.c); no Wine runs.

1. Source checks on build/ntdll-unix/winegstreamer_unixlib_ios.c: both unix call tables follow
   dlls/winegstreamer/unixlib.h `enum unix_funcs` entry for entry, every wg_parser entry that
   upstream wg_parser.c thunks for wow64 (X64) has a wow64 thunk here, the kill switches
   (MADEIRA_WG_PARSER=0 -> STATUS_NOT_IMPLEMENTED in create; MADEIRA_WG_VIDEO=0 -> no MP4) are
   wired, the round tag is logged, the Apple backend TU is built and archived, and the iOS FFmpeg
   configuration (build/ffmpeg/build.sh) has the mov demuxer and NO H.264/HEVC/AAC decoder, and the
   app target links the FFmpeg archives and the Apple media frameworks.
2. Builds a host (Linux) FFmpeg 7.1.1 from the same pinned tarball with the same component set as
   build/ffmpeg/build.sh (mp3/wav/mov demuxers, mpegaudio parser, mp1/mp2/mp3 + PCM decoders), plus
   TEST-ONLY pieces used to synthesise inputs and to stand in for AudioToolbox: the mp2 and aac
   encoders, the mp4 muxer, and the aac decoder (inside the stub AAC backend only).  Cached.
3. Compiles the production core under ASan/UBSan with a synthetic PE read thread that follows
   media_source.c / quartz_parser.c read_thread() exactly, and stub decoder backends of the
   wg_parser_backend_ios.h shape (VideoToolbox is not available on Linux: the stub "decodes" a
   synthetic H.264 elementary stream whose packets carry their display index, into NV12 pictures
   with a known pattern; the AAC stub wraps libavcodec's aac decoder, optionally one packet late).
   MP3/WAV: bit-exact passthrough, seek + stop, conversions, MPEG layer II/III decode, refusals,
   read errors, disconnect.  MP4: two streams, B-frame reorder, every output pixel format checked
   pixel by pixel (NV12/I420/YV12/YUY2/BGRx/BGRA/RGBA, bottom-up), interleaved and one-sided
   consumption (packet queue), keyframe seek + exact trim, stop, earliest-buffer mode, the
   MADEIRA_WG_VIDEO=0 path, unsupported video / audio codecs, compressed-output refusal, a backend
   that refuses to open, and the deduplicated, bounded log.

Environment: MADEIRA_FFMPEG_TARBALL (default: build/ffmpeg/src/ffmpeg-7.1.1.tar.xz, the tracked
source tarball),
MADEIRA_HOST_FFMPEG (prefix of an existing host build), MADEIRA_TEST_MP3 (an .mp3 to decode;
default: a Windows system MP3 under /mnt/c when present, otherwise the real-MP3 case is skipped).
"""
from pathlib import Path
import hashlib, os, re, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
core = root / "build/ntdll-unix/wg_parser_av_ios.c"
glue = (root / "build/ntdll-unix/winegstreamer_unixlib_ios.c").read_text()
apple = (root / "build/ntdll-unix/wg_parser_apple_ios.c").read_text()
build_sh = (root / "build/ntdll-unix/build.sh").read_text()
unixlib_h = (root / "wine/dlls/winegstreamer/unixlib.h").read_text()
upstream = (root / "wine/dlls/winegstreamer/wg_parser.c").read_text()

# ------------------------------------------------------------------ 1. source checks
enum_body = unixlib_h[unixlib_h.index("enum unix_funcs"):]
enum_body = enum_body[enum_body.index("{") + 1:enum_body.index("unix_wg_funcs_count")]
enum_names = re.findall(r"\b(unix_wg_\w+)\s*,", enum_body)
assert len(enum_names) == 37, enum_names

def table(name):
    body = glue[glue.index("const unixlib_entry_t %s[] =" % name):]
    body = body[body.index("{") + 1:body.index("};")]
    rows = re.findall(r"^\s*(\w+),\s*/\*\s*(unix_wg_\w+)\s*\*/", body, re.M)
    assert [r[1] for r in rows] == enum_names, (name, [r[1] for r in rows])
    return dict((r[1], r[0]) for r in rows)

native = table("__wine_unix_call_funcs")
wow64 = table("__wine_unix_call_wow64_funcs")
for n in enum_names:
    if n.startswith("unix_wg_parser_"):
        assert native[n] != "wma_not_implemented" and wow64[n] != "wma_not_implemented", n
x64 = set(re.findall(r"X64\((wg_parser_\w+)\)", upstream))
assert x64 == {"wg_parser_connect", "wg_parser_push_data", "wg_parser_stream_get_current_format",
               "wg_parser_stream_get_codec_format", "wg_parser_stream_enable", "wg_parser_stream_get_buffer",
               "wg_parser_stream_copy_buffer", "wg_parser_stream_get_tag"}, x64
for n in enum_names:
    if not n.startswith("unix_wg_parser_"):
        continue
    if n[len("unix_"):] in x64:
        assert wow64[n].startswith("wow64_"), ("pointer-carrying entry needs a wow64 thunk", n, wow64[n])
    elif n == "unix_wg_parser_create":
        # The 64-bit table's create is wgp_create behind MADEIRA_WG_64BIT=1 (a 64-bit caller has
        # the table for the WMA decoder; its parser stays refused unless the switch is on).
        assert wow64[n] == "wgp_create" and native[n] == "wgp_create64", (n, native[n], wow64[n])
        create64 = glue[glue.index("static NTSTATUS wgp_create64( void *args )"):]
        create64 = create64[:create64.index("\n}\n")]
        assert ('getenv( "MADEIRA_WG_64BIT" )' in create64 and "return STATUS_NOT_IMPLEMENTED;" in create64
                and create64.index("return STATUS_NOT_IMPLEMENTED;") < create64.index("return wgp_create( args );")), create64
    else:
        assert wow64[n] == native[n], ("scalar-only entry should share the 64-bit entry", n)
create = glue[glue.index("static NTSTATUS wgp_create( void *args )"):]
create = create[:create.index("\n}\n")]
assert 'getenv( "MADEIRA_WG_PARSER" )' in glue and "wg_parser_switch_on()" in create
assert create.index("wg_parser_switch_on()") < create.index("return STATUS_NOT_IMPLEMENTED;") < create.index("calloc(")
assert "pthread_once( &wgp_config_once, wgp_configure )" in create
configure = glue[glue.index("static void wgp_configure(void)"):]
configure = configure[:configure.index("\n}\n")]
assert 'getenv( "MADEIRA_WG_VIDEO" )' in glue and "wg_video_switch_on()" in configure
assert "mav_configure( video, &mav_apple_video_backend, &mav_apple_audio_backend, native )" in configure
assert '#include "wg_parser_av_ios.c"' in glue
csrc = core.read_text()
assert '#define MAV_TAG "[wg-parser] ml1990 "' in csrc and "#define MAV_MAX_LOGS 64" in csrc
# the Apple backend: its own TU, no Wine header, built and archived
assert "#include \"windef.h\"" not in apple and "wine/" not in re.sub(r"/\*.*?\*/", "", apple, flags=re.S)
assert '"$BUILD_DIR/wg_parser_apple_ios.c"' in build_sh and '"$OBJ_DIR/wg_parser_apple_ios.o"' in build_sh
for sym in ["VTDecompressionSessionCreate", "CMVideoFormatDescriptionCreateFromH264ParameterSets",
            "CMVideoFormatDescriptionCreateFromHEVCParameterSets", "kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange",
            "AudioConverterFillComplexBuffer", "kAudioConverterDecompressionMagicCookie"]:
    assert sym in apple, sym
ff = (root / "build/ffmpeg/build.sh").read_text().replace("\r\n", "\n")
args = ff[ff.index("CONFIG_ARGS=("):]
args = args[:args.index("\n)\n")]
assert "--enable-demuxer=mp3,wav,mov" in args, "mov demuxer"
for flag in ["--disable-gpl", "--disable-nonfree", "--disable-version3", "--disable-everything"]:
    assert flag in args, ("LGPL-only configuration", flag)
for bad in ["h264", "hevc", "aac"]:
    assert not re.search(r"--enable-(decoder|parser)=[^\n]*\b%s\b" % bad, args), ("patent-encumbered decoder enabled", bad)
pbx = (root / "app/Madeira.xcodeproj/project.pbxproj").read_text()
phase = pbx[pbx.index("isa = PBXFrameworksBuildPhase;"):]
phase = phase[:phase.index(");")]
for fw in ["VideoToolbox", "CoreMedia", "CoreVideo", "AudioToolbox", "CoreFoundation"]:
    assert "/* %s.framework in Frameworks */" % fw in phase, ("framework not linked", fw)
for lib in ["libavformat", "libavcodec", "libswresample", "libavutil"]:
    assert "/* %s.a in Frameworks */" % lib in phase, ("FFmpeg archive not linked", lib)
print("PASS: call tables match enum unix_funcs; wow64 thunks; kill switches (MADEIRA_WG_PARSER, MADEIRA_WG_VIDEO); "
      "Apple backend built/archived/linked; FFmpeg has mov and no H.264/HEVC/AAC decoder")

# ------------------------------------------------------------------ 2. host FFmpeg
tarball = os.environ.get("MADEIRA_FFMPEG_TARBALL") or str(root / "build/ffmpeg/src/ffmpeg-7.1.1.tar.xz")
FLAGS = [
    "--disable-everything", "--disable-autodetect", "--disable-gpl", "--disable-nonfree", "--disable-version3",
    "--enable-decoder=mp1,mp2,mp3", "--enable-decoder=pcm_u8,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le",
    "--enable-demuxer=mp3,wav,mov", "--enable-parser=mpegaudio",
    # TEST ONLY: input synthesis, and the stand-in for AudioToolbox inside the stub AAC backend
    "--enable-encoder=mp2,aac", "--enable-muxer=mp4", "--enable-decoder=aac",
    "--disable-programs", "--disable-doc", "--disable-network", "--disable-avdevice", "--disable-swscale",
    "--disable-avfilter", "--disable-postproc", "--enable-avformat", "--enable-avcodec", "--enable-swresample",
    "--disable-asm", "--disable-shared", "--enable-static", "--enable-pic", "--disable-debug",
]
prefix = os.environ.get("MADEIRA_HOST_FFMPEG")
if not prefix:
    key = hashlib.sha256(" ".join(FLAGS).encode()).hexdigest()[:12]
    prefix = str(Path.home() / ".cache/madeira-host-ffmpeg" / ("7.1.1-" + key))
    if not (Path(prefix) / "lib/libavformat.a").exists():
        assert tarball and Path(tarball).exists(), "no FFmpeg tarball at build/ffmpeg/src (tracked) and no MADEIRA_FFMPEG_TARBALL"
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

# ------------------------------------------------------------------ 3. the core under ASan
harness = r"""
#include "wg_parser_av_ios.c"
#include <libavutil/intreadwrite.h>
#include <time.h>

static int failures;
#define CHECK(c, ...) do { if (!(c)) { printf( "FAIL %s:%d: ", __func__, __LINE__ ); printf( __VA_ARGS__ ); printf( "\n" ); failures++; return 1; } } while (0)

/* ================= stub backends (the wg_parser_backend_ios.h contract) ================= */
#define W 320
#define H 240
#define FPS 30
#define GOP 15

static uint8_t stub_avcc[] = { 0x01, 0x42, 0xc0, 0x1e, 0xff, 0xe1, 0x00, 0x04, 0x67, 0x42, 0xc0, 0x1e,
                               0x01, 0x00, 0x02, 0x68, 0xce };
static int stub_vdecodes, stub_vflushes, stub_verrors, stub_vlive, stub_vmapped;

static int ref_y( int idx, int x, int y ) { (void)x; return 16 + (idx + y) % 200; }
static int ref_u( int x, int y ) { (void)y; return 64 + (x / 2) % 128; }
static int ref_v( int x, int y ) { (void)x; return 192 - (y / 2) % 64; }

struct stub_vdec { int have_ref; };
struct stub_pic { uint8_t *y, *uv; int idx; };

static int stub_vsupports( int codec ) { return codec == MAV_BACKEND_H264; }

static void *stub_vopen( int codec, const uint8_t *ed, uint32_t n, uint32_t w, uint32_t h, char *why, size_t ws )
{
    if (codec != MAV_BACKEND_H264 || n != sizeof(stub_avcc) || memcmp( ed, stub_avcc, n ) || w != W || h != H)
    {
        snprintf( why, ws, "stub: unexpected codec data (%u bytes) or size %ux%u", n, w, h );
        return NULL;
    }
    return calloc( 1, sizeof(struct stub_vdec) );
}

#define PSTRIDE (W + 32)
static int stub_vdecode( void *handle, const uint8_t *data, uint32_t size, int64_t pts, int64_t dur, int key,
                         mav_vframe_emit emit, void *ctx )
{
    struct stub_vdec *d = handle;
    struct stub_pic *pic;
    int x, y;

    stub_vdecodes++;
    if (size != 9 || AV_RB32( data ) != 5 || (data[4] & 0x1f) != (key ? 5 : 1)) { stub_verrors++; return -5; }
    if (key) d->have_ref = 1;
    if (!d->have_ref) { stub_verrors++; return -6; }   /* a real decoder needs a keyframe after a flush */
    pic = calloc( 1, sizeof(*pic) );
    pic->idx = data[5] << 8 | data[6];
    pic->y = malloc( PSTRIDE * H );
    pic->uv = malloc( PSTRIDE * H / 2 );
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) pic->y[y * PSTRIDE + x] = ref_y( pic->idx, x, y );
    for (y = 0; y < H / 2; y++) for (x = 0; x < W; x += 2)
    {
        pic->uv[y * PSTRIDE + x] = ref_u( x, y * 2 );
        pic->uv[y * PSTRIDE + x + 1] = ref_v( x, y * 2 );
    }
    stub_vlive++;
    emit( ctx, pic, pts, dur );
    return 0;
}

static int stub_vmap( void *frame, struct mav_vplanes *p )
{
    struct stub_pic *pic = frame;
    p->y = pic->y; p->uv = pic->uv; p->y_stride = p->uv_stride = PSTRIDE; p->width = W; p->height = H;
    p->full_range = 0;
    stub_vmapped++;
    return 0;
}
static void stub_vunmap( void *frame ) { (void)frame; stub_vmapped--; }
static void stub_vrelease( void *frame ) { struct stub_pic *pic = frame; free( pic->y ); free( pic->uv ); free( pic ); stub_vlive--; }
static void stub_vflush( void *handle ) { ((struct stub_vdec *)handle)->have_ref = 0; stub_vflushes++; }
static void stub_vclose( void *handle ) { free( handle ); }

static const struct mav_video_backend stub_video =
{
    "stub-video", stub_vsupports, stub_vopen, stub_vdecode, stub_vmap, stub_vunmap, stub_vrelease, stub_vflush, stub_vclose,
};

/* AAC: libavcodec's decoder (TEST ONLY) standing in for AudioToolbox, optionally one packet late */
static int stub_adelay;
struct stub_adec { AVCodecContext *c; AVFrame *f; AVPacket *pkt; float held[8192 * 2]; int held_frames, primed; };

static int stub_asupports( int codec ) { return codec == MAV_BACKEND_AAC; }

static void *stub_aopen( int codec, const uint8_t *ed, uint32_t n, uint32_t *rate, uint32_t *channels, char *why, size_t ws )
{
    struct stub_adec *d = calloc( 1, sizeof(*d) );
    d->c = avcodec_alloc_context3( avcodec_find_decoder( AV_CODEC_ID_AAC ) );
    d->c->extradata = av_mallocz( n + AV_INPUT_BUFFER_PADDING_SIZE );
    memcpy( d->c->extradata, ed, n ); d->c->extradata_size = n;
    d->c->sample_rate = *rate;
    av_channel_layout_default( &d->c->ch_layout, *channels );
    if (codec != MAV_BACKEND_AAC || avcodec_open2( d->c, NULL, NULL ) < 0)
    {
        snprintf( why, ws, "stub: aac decoder did not open" );
        avcodec_free_context( &d->c ); free( d );
        return NULL;
    }
    d->f = av_frame_alloc(); d->pkt = av_packet_alloc();
    *rate = d->c->sample_rate; *channels = d->c->ch_layout.nb_channels;
    return d;
}

static int stub_adecode( void *handle, const uint8_t *data, uint32_t size, float *out, uint32_t max_frames )
{
    struct stub_adec *d = handle;
    int n = 0, ch, i, c;
    av_new_packet( d->pkt, size ); memcpy( d->pkt->data, data, size );
    if (avcodec_send_packet( d->c, d->pkt ) < 0) { av_packet_unref( d->pkt ); return -7; }
    av_packet_unref( d->pkt );
    while (!avcodec_receive_frame( d->c, d->f ))
    {
        ch = d->f->ch_layout.nb_channels;
        for (i = 0; i < d->f->nb_samples && n < (int)max_frames; i++, n++)
            for (c = 0; c < ch; c++) out[n * ch + c] = ((const float *)d->f->extended_data[c])[i];
        av_frame_unref( d->f );
    }
    if (stub_adelay)
    {
        float tmp[8192 * 2]; int t = d->held_frames;
        ch = d->c->ch_layout.nb_channels;
        memcpy( tmp, d->held, t * ch * sizeof(float) );
        memcpy( d->held, out, n * ch * sizeof(float) ); d->held_frames = n;
        memcpy( out, tmp, t * ch * sizeof(float) );
        return t;
    }
    return n;
}
static void stub_aflush( void *handle ) { struct stub_adec *d = handle; avcodec_flush_buffers( d->c ); d->held_frames = 0; }
static void stub_aclose( void *handle ) { struct stub_adec *d = handle; avcodec_free_context( &d->c ); av_frame_free( &d->f ); av_packet_free( &d->pkt ); free( d ); }

static const struct mav_audio_backend stub_audio =
{
    "stub-aac", stub_asupports, stub_aopen, stub_adecode, stub_aflush, stub_aclose,
};

/* ---- a synthetic PE side: media_source.c / quartz_parser.c read_thread(), verbatim in behaviour ---- */
struct source
{
    const uint8_t *data;
    size_t size;
    int fail_after;             /* push NULL (read error) once this many requests were served, -1 never */
    volatile int running;
    int requests, state_errors, out_of_range, oversize;
    struct mav_parser *p;
    pthread_t thread;
};

static void *read_thread( void *arg )
{
    struct source *s = arg;
    while (s->running)
    {
        uint64_t offset; uint32_t size;
        if (mav_get_next_read_offset( s->p, &offset, &size ))
        {
            __atomic_add_fetch( &s->state_errors, 1, __ATOMIC_RELAXED );
            usleep( 200 );      /* the PE side spins here until its own flag drops */
            continue;
        }
        s->requests++;
        if (size > MAV_MAX_REQUEST) s->oversize++;
        if (offset > s->size) s->out_of_range++;
        if (offset >= s->size) size = 0;
        else if (offset + size >= s->size) size = s->size - offset;
        if (s->fail_after >= 0 && s->requests > s->fail_after) { mav_push_data( s->p, NULL, size ); continue; }
        if (!size) { mav_push_data( s->p, s->data, 0 ); continue; }
        mav_push_data( s->p, s->data + offset, size );
    }
    return NULL;
}

static void src_start( struct source *s, struct mav_parser *p, const uint8_t *data, size_t size )
{
    memset( s, 0, sizeof(*s) );
    s->data = data; s->size = size; s->fail_after = -1; s->p = p; s->running = 1;
    pthread_create( &s->thread, NULL, read_thread, s );
}

/* disconnect first, then drop the flag, then join (quartz GST_RemoveOutputPins / media_source Shutdown) */
static void src_stop( struct source *s )
{
    mav_disconnect( s->p );
    s->running = 0;
    pthread_join( s->thread, NULL );
}

/* ---- inputs ---- */
static uint8_t *make_wav( size_t *size, int rate, int channels, int frames )
{
    size_t data = (size_t)frames * channels * 2, i;
    uint8_t *w = malloc( 44 + data );
    int16_t *pcm = (int16_t *)(w + 44);
    memcpy( w, "RIFF", 4 ); *(uint32_t *)(w + 4) = 36 + data; memcpy( w + 8, "WAVEfmt ", 8 );
    *(uint32_t *)(w + 16) = 16; *(uint16_t *)(w + 20) = 1; *(uint16_t *)(w + 22) = channels;
    *(uint32_t *)(w + 24) = rate; *(uint32_t *)(w + 28) = rate * channels * 2;
    *(uint16_t *)(w + 32) = channels * 2; *(uint16_t *)(w + 34) = 16;
    memcpy( w + 36, "data", 4 ); *(uint32_t *)(w + 40) = data;
    for (i = 0; i < (size_t)frames * channels; i++) pcm[i] = (int16_t)((i * 2654435761u) >> 16);
    *size = 44 + data;
    return w;
}

/* Encodes `seconds` of a 440 Hz stereo tone; each packet is handed to `put`. */
static int encode_tone( enum AVCodecID id, int rate, double seconds, AVCodecContext **out_ctx,
                        void (*put)( void *, AVPacket * ), void *opaque )
{
    const AVCodec *c = avcodec_find_encoder( id );
    AVCodecContext *e = avcodec_alloc_context3( c );
    AVFrame *f = av_frame_alloc(); AVPacket *pkt = av_packet_alloc();
    int64_t n = 0, total = (int64_t)(rate * seconds);
    e->sample_fmt = id == AV_CODEC_ID_AAC ? AV_SAMPLE_FMT_FLTP : AV_SAMPLE_FMT_S16;
    e->sample_rate = rate; e->bit_rate = 192000; e->time_base = (AVRational){ 1, rate };
    e->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    av_channel_layout_default( &e->ch_layout, 2 );
    if (avcodec_open2( e, c, NULL ) < 0) return -1;
    for (;;)
    {
        if (n < total)
        {
            int i;
            f->nb_samples = e->frame_size; f->format = e->sample_fmt; f->sample_rate = rate;
            av_channel_layout_copy( &f->ch_layout, &e->ch_layout );
            av_frame_get_buffer( f, 0 );
            for (i = 0; i < f->nb_samples; i++, n++)
            {
                double v = 0.35 * sin( 2 * M_PI * 440.0 * n / rate );
                if (e->sample_fmt == AV_SAMPLE_FMT_FLTP) ((float *)f->data[0])[i] = ((float *)f->data[1])[i] = v;
                else ((int16_t *)f->data[0])[2 * i] = ((int16_t *)f->data[0])[2 * i + 1] = (int16_t)(v * 32767);
            }
            f->pts = n - f->nb_samples;
            avcodec_send_frame( e, f ); av_frame_unref( f );
        }
        else avcodec_send_frame( e, NULL );
        while (!avcodec_receive_packet( e, pkt )) { put( opaque, pkt ); av_packet_unref( pkt ); }
        if (n >= total && avcodec_receive_packet( e, pkt ) == AVERROR_EOF) break;
    }
    av_frame_free( &f ); av_packet_free( &pkt );
    *out_ctx = e;
    return 0;
}

struct bytes { uint8_t *data; size_t len; };
static void put_bytes( void *opaque, AVPacket *pkt )
{
    struct bytes *b = opaque;
    b->data = realloc( b->data, b->len + pkt->size ); memcpy( b->data + b->len, pkt->data, pkt->size ); b->len += pkt->size;
}

static uint8_t *make_mp2( size_t *size, int rate, double seconds )
{
    struct bytes b = { 0 }; AVCodecContext *e;
    if (encode_tone( AV_CODEC_ID_MP2, rate, seconds, &e, put_bytes, &b )) return NULL;
    avcodec_free_context( &e );
    *size = b.len;
    return b.data;
}

/* ---- MP4 synthesis (TEST ONLY: libavformat's mp4 muxer) ---- */
struct pktlist { AVPacket **p; int n; };
static void put_list( void *opaque, AVPacket *pkt )
{
    struct pktlist *l = opaque;
    l->p = realloc( l->p, (l->n + 1) * sizeof(*l->p) ); l->p[l->n++] = av_packet_clone( pkt );
}

/* display index -> decode position in a closed GOP of 15: I0 P3 B1 B2 P6 B4 B5 P9 B7 B8 P12 B10 B11 P13 P14 */
static const int gop_order[GOP] = { 0, 3, 1, 2, 6, 4, 5, 9, 7, 8, 12, 10, 11, 13, 14 };

enum mp4_audio { A_NONE, A_AAC, A_PCM_BE };

static uint8_t *make_mp4( size_t *size, enum AVCodecID vcodec, enum mp4_audio audio, int frames, double audio_seconds )
{
    AVFormatContext *oc = NULL; AVStream *vs = NULL, *as = NULL; AVCodecContext *enc = NULL;
    struct pktlist apk = { 0 }; uint8_t *buf; int i, a = 0, v = 0, ret;
    AVRational vtb = { 1, FPS }, atb = { 1, 44100 };

    if (avformat_alloc_output_context2( &oc, NULL, "mp4", NULL ) < 0 || !oc) return NULL;
    if (avio_open_dyn_buf( &oc->pb ) < 0) return NULL;
    if (vcodec != AV_CODEC_ID_NONE)
    {
        vs = avformat_new_stream( oc, NULL );
        vs->codecpar->codec_type = AVMEDIA_TYPE_VIDEO; vs->codecpar->codec_id = vcodec;
        vs->codecpar->width = W; vs->codecpar->height = H;
        vs->codecpar->extradata = av_mallocz( sizeof(stub_avcc) + AV_INPUT_BUFFER_PADDING_SIZE );
        memcpy( vs->codecpar->extradata, stub_avcc, sizeof(stub_avcc) ); vs->codecpar->extradata_size = sizeof(stub_avcc);
        vs->time_base = vtb; vs->avg_frame_rate = (AVRational){ FPS, 1 };
    }
    if (audio == A_AAC)
    {
        if (encode_tone( AV_CODEC_ID_AAC, 44100, audio_seconds, &enc, put_list, &apk )) return NULL;
        as = avformat_new_stream( oc, NULL );
        avcodec_parameters_from_context( as->codecpar, enc );
        as->time_base = atb;
    }
    else if (audio == A_PCM_BE)
    {
        as = avformat_new_stream( oc, NULL );
        as->codecpar->codec_type = AVMEDIA_TYPE_AUDIO; as->codecpar->codec_id = AV_CODEC_ID_PCM_S16BE;
        as->codecpar->sample_rate = 44100; av_channel_layout_default( &as->codecpar->ch_layout, 2 );
        as->codecpar->bits_per_coded_sample = 16; as->codecpar->block_align = 4;
        as->time_base = atb;
        for (i = 0; i < (int)(audio_seconds * 44100 / 1024); i++)
        {
            AVPacket *pk = av_packet_alloc(); av_new_packet( pk, 4096 ); memset( pk->data, i, 4096 );
            pk->pts = pk->dts = (int64_t)i * 1024; pk->duration = 1024; pk->flags = AV_PKT_FLAG_KEY;
            apk.p = realloc( apk.p, (apk.n + 1) * sizeof(*apk.p) ); apk.p[apk.n++] = pk;
        }
    }
    if ((ret = avformat_write_header( oc, NULL )) < 0) { printf( "mp4 header %d\n", ret ); return NULL; }
    while (v < frames || a < apk.n)
    {
        int64_t vdts = v < frames ? av_rescale_q( v - 1, vtb, AV_TIME_BASE_Q ) : INT64_MAX;
        int64_t adts = a < apk.n ? av_rescale_q( apk.p[a]->dts, enc ? enc->time_base : atb, AV_TIME_BASE_Q ) : INT64_MAX;
        AVPacket *pk;
        if (vs && vdts <= adts)
        {
            int disp = (v / GOP) * GOP + gop_order[v % GOP];
            pk = av_packet_alloc(); av_new_packet( pk, 9 );
            AV_WB32( pk->data, 5 ); pk->data[4] = disp % GOP ? 0x41 : 0x65;
            pk->data[5] = disp >> 8; pk->data[6] = disp & 0xff; pk->data[7] = 0xaa; pk->data[8] = 0xbb;
            pk->pts = disp; pk->dts = v - 1; pk->duration = 1;
            if (!(disp % GOP)) pk->flags |= AV_PKT_FLAG_KEY;
            pk->stream_index = vs->index;
            av_packet_rescale_ts( pk, vtb, vs->time_base );
            v++;
        }
        else
        {
            pk = apk.p[a++];
            pk->stream_index = as->index;
            av_packet_rescale_ts( pk, enc ? enc->time_base : atb, as->time_base );
        }
        if ((ret = av_interleaved_write_frame( oc, pk )) < 0) { printf( "mp4 write %d\n", ret ); return NULL; }
        av_packet_free( &pk );
    }
    av_write_trailer( oc );
    *size = avio_close_dyn_buf( oc->pb, &buf ); oc->pb = NULL;
    avformat_free_context( oc );
    avcodec_free_context( &enc );
    free( apk.p );
    return buf;
}

/* ---- draining a stream the way media_source's wait_on_sample + send_sample do ---- */
struct drained { uint8_t *data; size_t size; uint64_t first_pts, end_pts; int buffers, gaps, discont; uint32_t first_size; };

static int drain_one( struct mav_parser *p, unsigned int st, struct drained *d, int *done )
{
    struct mav_buffer b, again; int r = mav_get_buffer( p, st, &b ); uint8_t tmp[8];
    if (r == MAV_NO_BUFFER) { *done = 1; return 0; }
    CHECK( r == MAV_OK, "get_buffer %d", r );
    CHECK( b.stream == st && b.size, "stream %u size %u", b.stream, b.size );
    CHECK( mav_get_buffer( p, st, &again ) == MAV_OK && again.pts == b.pts && again.size == b.size, "held buffer is returned again" );
    CHECK( mav_copy_buffer( p, st, tmp, b.size, 1 ) == MAV_E_PARAM, "copy past the end is refused" );
    d->data = realloc( d->data, d->size + b.size );
    /* in two parts, like quartz's send_buffer splitting a buffer over two samples */
    CHECK( mav_copy_buffer( p, st, d->data + d->size, 0, b.size / 2 ) == MAV_OK, "copy 1" );
    CHECK( mav_copy_buffer( p, st, d->data + d->size + b.size / 2, b.size / 2, b.size - b.size / 2 ) == MAV_OK, "copy 2" );
    if (!d->buffers) { d->first_pts = b.pts; d->first_size = b.size; }
    else if (llabs( (long long)b.pts - (long long)d->end_pts ) > 1000) d->gaps++;
    if (b.discontinuity) d->discont++;
    d->end_pts = b.pts + b.duration;
    d->size += b.size; d->buffers++;
    mav_release_buffer( p, st );
    CHECK( mav_copy_buffer( p, st, tmp, 0, 1 ) == MAV_E_STATE, "copy after release is refused" );
    *done = 0;
    return 0;
}

static int drain( struct mav_parser *p, unsigned int st, struct drained *d )
{
    int done = 0;
    memset( d, 0, sizeof(*d) );
    while (!done) if (drain_one( p, st, d, &done )) return 1;
    CHECK( mav_get_buffer( p, st, &(struct mav_buffer){0} ) == MAV_NO_BUFFER, "EOS is sticky" );
    return 0;
}

/* ================= MP3 / WAV (ml1980 behaviour, unchanged) ================= */
static int test_wav( void )
{
    size_t size; int rate = 22050, frames = 22050;
    uint8_t *wav = make_wav( &size, rate, 2, frames );
    struct mav_parser *p = mav_create( 0 ); struct source s; struct mav_stream_info info; struct drained d;
    struct mav_output o;

    src_start( &s, p, wav, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "connect wav" );
    CHECK( mav_connect( p, size ) == MAV_E_STATE, "second connect refused" );
    CHECK( mav_stream_count( p ) == 1 && mav_stream_info( p, 0, &info ) == MAV_OK, "one stream" );
    CHECK( mav_stream_info( p, 1, &info ) == MAV_E_STATE, "no second stream" );
    CHECK( mav_stream_info( p, 0, &info ) == MAV_OK && info.type == MAV_STREAM_AUDIO, "audio" );
    CHECK( !strcmp( info.container, "wav" ) && info.kind == MAV_CODEC_PCM && info.native.fmt == MAV_FMT_S16
           && info.native.rate == 22050 && info.native.channels == 2 && info.native.channel_mask == 3,
           "info %s %u %u %u %#x", info.container, info.native.fmt, info.native.rate, info.native.channels, info.native.channel_mask );
    CHECK( info.duration == 10000000, "duration %llu", (unsigned long long)info.duration );
    CHECK( mav_current_video( p, 0, &(struct mav_video_output){0} ) == MAV_E_STATE, "not a video stream" );
    /* parser_init_stream: enable the pin's format, seek to the start */
    CHECK( mav_enable( p, 0, &info.native ) == MAV_OK, "enable" );
    CHECK( mav_seek( p, 0, 1, 0, 1, info.duration ) == MAV_OK, "seek 0" );
    if (drain( p, 0, &d )) return 1;
    CHECK( d.size == (size_t)frames * 4 && !memcmp( d.data, wav + 44, d.size ), "bit-exact passthrough (%zu bytes)", d.size );
    CHECK( d.first_pts == 0 && d.gaps == 0 && d.end_pts == 10000000 && d.discont == 1, "timeline %llu..%llu gaps %d discont %d",
           (unsigned long long)d.first_pts, (unsigned long long)d.end_pts, d.gaps, d.discont );
    free( d.data );

    /* accurate seek + stop: 0.5 s .. 0.75 s */
    CHECK( mav_seek( p, 0, 1, 5000000, 1, 7500000 ) == MAV_OK, "seek 0.5" );
    if (drain( p, 0, &d )) return 1;
    CHECK( d.first_pts == 5000000, "first pts after seek %llu", (unsigned long long)d.first_pts );
    CHECK( !memcmp( d.data, wav + 44 + 11025 * 4, 16 ), "first sample is frame 11025" );
    CHECK( d.size / 4 >= 5512 && d.size / 4 <= 5513, "stop trimmed to %zu frames", d.size / 4 );
    free( d.data );

    /* rate-only change (GST_ChangeRate): no positioning, nothing moves */
    CHECK( mav_seek( p, 0, 0, 0, 0, 0 ) == MAV_OK, "no-positioning seek" );

    /* conversion: F32 mono 44100 (downmix + resample), from a seek to 0 without stop */
    o.fmt = MAV_FMT_F32; o.rate = 44100; o.channels = 1; o.channel_mask = 4;
    CHECK( mav_enable( p, 0, &o ) == MAV_OK, "enable f32" );
    CHECK( mav_seek( p, 0, 1, 0, 1, info.duration ) == MAV_OK, "seek 0 again" );
    if (drain( p, 0, &d )) return 1;
    CHECK( d.size % 4 == 0 && labs( (long)(d.size / 4) - 44100 ) <= 64, "resampled frames %zu", d.size / 4 );
    free( d.data );

    /* S24 packing */
    o.fmt = MAV_FMT_S24; o.rate = 22050; o.channels = 2; o.channel_mask = 3;
    CHECK( mav_enable( p, 0, &o ) == MAV_OK && mav_seek( p, 0, 1, 0, 1, info.duration ) == MAV_OK, "enable s24" );
    if (drain( p, 0, &d )) return 1;
    CHECK( d.size == (size_t)frames * 6, "s24 size %zu", d.size );
    { const int16_t *in = (const int16_t *)(wav + 44); size_t i; for (i = 0; i < 64; i++)
        CHECK( d.data[i * 3] == 0 && (int16_t)(d.data[i * 3 + 1] | d.data[i * 3 + 2] << 8) == in[i], "s24 sample %zu", i ); }
    free( d.data );

    /* a format nobody can produce: refused, and the stream is disabled rather than lying */
    o.fmt = MAV_FMT_UNKNOWN;
    CHECK( mav_enable( p, 0, &o ) == MAV_E_PARAM, "bad format refused" );
    CHECK( mav_get_buffer( p, 0, &(struct mav_buffer){0} ) == MAV_NO_BUFFER, "disabled stream gives no buffer" );
    CHECK( mav_enable_video( p, 0, &(struct mav_video_output){ MAV_PIX_NV12, 16, 16, 1, 1 } ) == MAV_E_STATE, "video enable on audio refused" );
    CHECK( s.oversize == 0 && s.out_of_range == 0, "requests within bounds" );
    CHECK( mav_push_data( p, wav, 4 ) == MAV_E_STATE, "push without a request is refused" );
    src_stop( &s );
    CHECK( mav_stream_count( p ) == 0 && mav_get_buffer( p, 0, &(struct mav_buffer){0} ) == MAV_E_STATE, "disconnected" );
    mav_destroy( p ); free( wav );
    printf( "PASS: wav: bit-exact passthrough, accurate seek + stop, f32/s24 conversion, refusals (%d requests)\n", s.requests );
    return 0;
}

static int test_wav_compressed_out_and_garbage( void )
{
    size_t wsize, gsize = 300000, i; uint8_t *wav = make_wav( &wsize, 8000, 1, 8000 ), *junk = malloc( gsize );
    struct mav_parser *p = mav_create( 1 ); struct source s; struct mav_stream_info info; struct drained d;
    uint32_t x = 12345;

    for (i = 0; i < gsize; i++) { x = x * 1103515245 + 12345; junk[i] = x >> 24; }
    src_start( &s, p, junk, gsize );
    CHECK( mav_connect( p, gsize ) == MAV_E_UNSUPPORTED, "garbage refused" );
    CHECK( mav_stream_count( p ) == 0, "no streams after refusal" );
    src_stop( &s );
    /* the same parser connects again (quartz reconnects a filter after a failed attempt) */
    src_start( &s, p, wav, wsize );
    CHECK( mav_connect( p, wsize ) == MAV_OK, "compressed-output parser takes PCM" );
    CHECK( mav_stream_info( p, 0, &info ) == MAV_OK && info.native.channels == 1 && info.native.channel_mask == 4, "mono" );
    if (drain( p, 0, &d )) return 1;
    CHECK( d.size == 16000 && !memcmp( d.data, wav + 44, 16000 ), "pcm unchanged" );
    free( d.data );
    src_stop( &s );
    mav_destroy( p ); free( wav ); free( junk );
    printf( "PASS: garbage refused, reconnect works, compressed-output parser passes PCM through\n" );
    return 0;
}

static int test_mpeg( const uint8_t *data, size_t size, const char *what, int expect_layer, double expect_seconds )
{
    struct mav_parser *p = mav_create( 0 ), *pc = mav_create( 1 );
    struct source s; struct mav_stream_info info; struct drained d; double rms = 0; size_t i, frames;
    uint64_t target;

    src_start( &s, pc, data, size );
    CHECK( mav_connect( pc, size ) == MAV_E_UNSUPPORTED, "%s: compressed-output parser refuses MPEG audio", what );
    src_stop( &s ); mav_destroy( pc );

    src_start( &s, p, data, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "%s: connect", what );
    CHECK( mav_stream_info( p, 0, &info ) == MAV_OK && info.kind == MAV_CODEC_MPEG_AUDIO && (int)info.layer == expect_layer
           && info.native.fmt == MAV_FMT_S16 && info.native.rate && info.native.channels, "%s: info layer %u", what, info.layer );
    CHECK( mav_enable( p, 0, &info.native ) == MAV_OK && mav_seek( p, 0, 1, 0, 1, info.duration ) == MAV_OK, "%s: start", what );
    if (drain( p, 0, &d )) return 1;
    frames = d.size / (2 * info.native.channels);
    for (i = 0; i < d.size / 2; i++) { double v = ((int16_t *)d.data)[i]; rms += v * v; }
    rms = sqrt( rms / (d.size / 2) );
    CHECK( fabs( frames / (double)info.native.rate - expect_seconds ) < 0.1 + expect_seconds * 0.03,
           "%s: decoded %.3f s, expected %.3f", what, frames / (double)info.native.rate, expect_seconds );
    CHECK( rms > 500, "%s: decoded audio is not silence (rms %.0f)", what, rms );
    CHECK( d.gaps == 0 && d.first_pts < 1000000, "%s: continuous timeline (gaps %d, first %llu)", what, d.gaps, (unsigned long long)d.first_pts );
    free( d.data );

    target = info.duration / 2 / 10000 * 10000;
    CHECK( mav_seek( p, 0, 1, target, 0, 0 ) == MAV_OK, "%s: seek to middle", what );
    if (drain( p, 0, &d )) return 1;
    CHECK( d.first_pts == target && d.discont == 1, "%s: first pts %llu after seek to %llu", what,
           (unsigned long long)d.first_pts, (unsigned long long)target );
    CHECK( fabs( d.size / (2.0 * info.native.channels) / info.native.rate - (expect_seconds - target / 1e7) ) < 0.15,
           "%s: tail length after seek", what );
    free( d.data );
    CHECK( s.oversize == 0 && s.out_of_range == 0, "%s: requests within bounds", what );
    src_stop( &s ); mav_destroy( p );
    printf( "PASS: %s: layer %u %u Hz %u ch, %.2f s decoded, rms %.0f, seek to %.2f s exact (%d requests)\n", what,
            info.layer, info.native.rate, info.native.channels, frames / (double)info.native.rate, rms, target / 1e7, s.requests );
    return 0;
}

static int test_read_error( const uint8_t *data, size_t size )
{
    struct mav_parser *p = mav_create( 0 ); struct source s; struct mav_stream_info info; struct drained d;
    src_start( &s, p, data, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "connect" );
    CHECK( mav_stream_info( p, 0, &info ) == MAV_OK && mav_seek( p, 0, 1, 0, 0, 0 ) == MAV_OK, "start" );
    s.fail_after = s.requests + 1;   /* one more good read, then errors */
    if (drain( p, 0, &d )) return 1;
    CHECK( d.size < 4 * 44100 * 2 * 2, "stream ended early on the read error" );
    free( d.data );
    /* the reader recovers; a seek starts over and the whole stream plays */
    s.fail_after = -1;
    CHECK( mav_seek( p, 0, 1, 0, 0, 0 ) == MAV_OK, "seek after the error" );
    if (drain( p, 0, &d )) return 1;
    CHECK( d.size == 4 * 44100 * 2 * 2 && !memcmp( d.data, data + 44, d.size ), "full stream after recovery (%zu)", d.size );
    free( d.data );
    src_stop( &s ); mav_destroy( p );
    printf( "PASS: a read error (NULL push) ends the stream instead of hanging; a seek recovers it\n" );
    return 0;
}

static int test_disconnect_wakes_reader( const uint8_t *data, size_t size )
{
    struct mav_parser *p = mav_create( 0 ); struct source s; int before; struct timespec t0, t1;
    src_start( &s, p, data, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "connect" );
    usleep( 50000 );
    before = __atomic_load_n( &s.state_errors, __ATOMIC_RELAXED );   /* reader now blocked, no request */
    clock_gettime( CLOCK_MONOTONIC, &t0 );
    mav_disconnect( p );
    while (__atomic_load_n( &s.state_errors, __ATOMIC_RELAXED ) == before)
    {
        clock_gettime( CLOCK_MONOTONIC, &t1 );
        CHECK( t1.tv_sec - t0.tv_sec < 2, "reader was not woken" );
        usleep( 1000 );
    }
    s.running = 0; pthread_join( s.thread, NULL );
    mav_disconnect( p );   /* idempotent, like quartz after a failed connect */
    mav_destroy( p );
    printf( "PASS: disconnect wakes a read thread blocked in get_next_read_offset\n" );
    return 0;
}

/* ================= MP4 (ml1990) ================= */

static int check_picture( const uint8_t *buf, uint32_t size, enum mav_pixel_format fmt, int flip, int idx, const char *what )
{
    struct mav_layout l; int x, y, maxerr = 0;
    size_t want = mav_video_layout( fmt, W, H, &l );
    CHECK( size == want, "%s: size %u, layout says %zu", what, size, want );
    /* the stride wg_format_get_stride() (dlls/winegstreamer/main.c) gives, and MF's plane size */
    switch (fmt)
    {
    case MAV_PIX_NV12: case MAV_PIX_I420: case MAV_PIX_YV12: CHECK( l.stride[0] == ((W + 3) & ~3) && size == W * H * 3 / 2, "%s stride", what ); break;
    case MAV_PIX_YUY2: CHECK( l.stride[0] == ((W * 2 + 3) & ~3), "%s stride", what ); break;
    default: CHECK( l.stride[0] == W * 4, "%s stride", what ); break;
    }
    for (y = 0; y < H; y++)
    {
        int ry = flip ? H - 1 - y : y;   /* the buffer row holding picture row y */
        for (x = 0; x < W; x++)
        {
            int Y = ref_y( idx, x, y ), U = ref_u( x, y ), V = ref_v( x, y );
            switch (fmt)
            {
            case MAV_PIX_NV12:
                CHECK( buf[ry * l.stride[0] + x] == Y, "%s Y(%d,%d)", what, x, y );
                if (!(y & 1)) CHECK( buf[l.offset[1] + (ry / 2) * l.stride[1] + (x & ~1)] == U
                                     && buf[l.offset[1] + (ry / 2) * l.stride[1] + (x & ~1) + 1] == V, "%s UV(%d,%d)", what, x, y );
                break;
            case MAV_PIX_I420: case MAV_PIX_YV12:
            {
                int up = fmt == MAV_PIX_I420 ? 1 : 2, vp = 3 - up;
                CHECK( buf[ry * l.stride[0] + x] == Y, "%s Y(%d,%d)", what, x, y );
                if (!(y & 1)) CHECK( buf[l.offset[up] + (ry / 2) * l.stride[up] + x / 2] == U
                                     && buf[l.offset[vp] + (ry / 2) * l.stride[vp] + x / 2] == V, "%s U/V(%d,%d)", what, x, y );
                break;
            }
            case MAV_PIX_YUY2:
                CHECK( buf[ry * l.stride[0] + 2 * x] == Y && buf[ry * l.stride[0] + 4 * (x / 2) + 1] == U
                       && buf[ry * l.stride[0] + 4 * (x / 2) + 3] == V, "%s YUY2(%d,%d)", what, x, y );
                break;
            default:
            {
                /* BT.601, limited range: the untagged, sub-720-line default */
                double yy = 1.164383 * (Y - 16), r = yy + 1.596027 * (V - 128),
                       g = yy - 0.391762 * (U - 128) - 0.812968 * (V - 128), b = yy + 2.017232 * (U - 128);
                const uint8_t *px = buf + ry * l.stride[0] + 4 * x;
                int R = fmt == MAV_PIX_RGBA ? px[0] : px[2], G = px[1], B = fmt == MAV_PIX_RGBA ? px[2] : px[0];
                int er = abs( R - (int)lround( fmin( 255, fmax( 0, r ) ) ) ), eg = abs( G - (int)lround( fmin( 255, fmax( 0, g ) ) ) ),
                    eb = abs( B - (int)lround( fmin( 255, fmax( 0, b ) ) ) );
                if (er > maxerr) maxerr = er;
                if (eg > maxerr) maxerr = eg;
                if (eb > maxerr) maxerr = eb;
                CHECK( px[3] == 0xff, "%s alpha", what );
                break;
            }
            }
        }
    }
    CHECK( maxerr <= 1, "%s: RGB error %d", what, maxerr );
    return 0;
}

static int picture_index( const uint8_t *buf, int flip, enum mav_pixel_format fmt )
{
    /* row 0, pixel 0 of the picture: Y = 16 + idx % 200 */
    struct mav_layout l; mav_video_layout( fmt, W, H, &l );
    return buf[(flip ? H - 1 : 0) * l.stride[0]] - 16;
}

static int test_mp4_basic( const uint8_t *mp4, size_t size, int frames, double seconds )
{
    struct mav_parser *p = mav_create( 0 ); struct source s; struct mav_stream_info vi, ai; struct mav_video_output vo;
    struct drained dv, da; int vdone = 0, adone = 0, k; double rms = 0; size_t i; float peak = 0;

    src_start( &s, p, mp4, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "connect mp4" );
    CHECK( mav_stream_count( p ) == 2, "two streams, got %u", mav_stream_count( p ) );
    CHECK( mav_stream_info( p, 0, &vi ) == MAV_OK && vi.type == MAV_STREAM_VIDEO && vi.kind == MAV_CODEC_H264
           && !strcmp( vi.container, "mp4" ) && !strcmp( vi.backend, "stub-video" ), "video info" );
    CHECK( vi.vnative.fmt == MAV_PIX_NV12 && vi.vnative.width == W && vi.vnative.height == H
           && vi.vnative.fps_n == FPS && vi.vnative.fps_d == 1, "native %s %dx%d %u/%u", mav_pix_name( vi.vnative.fmt ),
           vi.vnative.width, vi.vnative.height, vi.vnative.fps_n, vi.vnative.fps_d );
    CHECK( llabs( (long long)vi.duration - frames * 10000000ll / FPS ) <= 10000, "video duration %llu", (unsigned long long)vi.duration );
    CHECK( vi.codec_data_len == sizeof(stub_avcc) && !memcmp( vi.codec_data, stub_avcc, sizeof(stub_avcc) ), "avcC kept" );
    CHECK( mav_stream_info( p, 1, &ai ) == MAV_OK && ai.type == MAV_STREAM_AUDIO && ai.kind == MAV_CODEC_AAC
           && ai.native.fmt == MAV_FMT_F32 && ai.native.rate == 44100 && ai.native.channels == 2
           && !strcmp( ai.backend, "stub-aac" ) && ai.codec_data_len >= 2, "audio info" );
    CHECK( mav_current_video( p, 0, &vo ) == MAV_OK && !memcmp( &vo, &vi.vnative, sizeof(vo) ), "current video = native" );
    CHECK( mav_current_output( p, 0, &(struct mav_output){0} ) == MAV_E_STATE, "video stream has no audio output" );

    /* media_source_start: enable both with the descriptor's (native) type, seek stream 0 to 0 */
    CHECK( mav_enable_video( p, 0, &vi.vnative ) == MAV_OK && mav_enable( p, 1, &ai.native ) == MAV_OK, "enable" );
    CHECK( mav_seek( p, 0, 1, 0, 0, 0 ) == MAV_OK, "seek 0" );
    /* two consumers, interleaved, the audio one faster (four audio buffers per picture) */
    memset( &dv, 0, sizeof(dv) ); memset( &da, 0, sizeof(da) );
    while (!vdone || !adone)
    {
        struct mav_buffer b;
        if (!vdone)
        {
            int r = mav_get_buffer( p, 0, &b );
            if (r == MAV_OK)
            {
                uint8_t *pic = malloc( b.size );
                int expect = dv.buffers;
                CHECK( mav_copy_buffer( p, 0, pic, 0, b.size ) == MAV_OK, "copy picture" );
                CHECK( picture_index( pic, 0, MAV_PIX_NV12 ) == expect % 200, "picture %d has index %d (pts %llu)", expect,
                       picture_index( pic, 0, MAV_PIX_NV12 ), (unsigned long long)b.pts );
                CHECK( llabs( (long long)b.pts - expect * 10000000ll / FPS ) <= 1, "picture %d pts %llu", expect, (unsigned long long)b.pts );
                CHECK( b.duration == 10000000 / FPS || b.duration == 10000000 / FPS + 1, "duration %llu", (unsigned long long)b.duration );
                if (expect == 0 || expect == 37) if (check_picture( pic, b.size, MAV_PIX_NV12, 0, expect, "nv12" )) return 1;
                free( pic );
                if (!dv.buffers) dv.discont = b.discontinuity;
                dv.buffers++;
                mav_release_buffer( p, 0 );
            }
            else { CHECK( r == MAV_NO_BUFFER, "video get_buffer %d", r ); vdone = 1; }
        }
        for (k = 0; k < 4 && !adone; k++)
        {
            if (drain_one( p, 1, &da, &adone )) return 1;
        }
    }
    CHECK( dv.buffers == frames && dv.discont == 1, "%d pictures (discont %d)", dv.buffers, dv.discont );
    CHECK( stub_vmapped == 0 && stub_vlive == 0, "every picture unmapped (%d) and released (%d)", stub_vmapped, stub_vlive );
    for (i = 0; i < da.size / 4; i++) { float v = ((float *)da.data)[i]; rms += v * v; if (fabsf( v ) > peak) peak = fabsf( v ); }
    rms = sqrt( rms / (da.size / 4) );
    CHECK( da.first_pts == 0 && da.gaps == 0, "audio timeline first %llu gaps %d", (unsigned long long)da.first_pts, da.gaps );
    CHECK( fabs( da.size / 8.0 / 44100 - seconds ) < 1024.0 / 44100 + 0.001, "audio %.4f s, expected %.4f", da.size / 8.0 / 44100, seconds );
    CHECK( rms > 0.2 && peak < 0.5, "audio rms %.3f peak %.3f (a 0.35 tone)", rms, peak );
    free( da.data );
    CHECK( stub_verrors == 0, "stub decoder saw %d bad packets", stub_verrors );

    /* one consumer at a time: all video first (audio packets queue), then all audio */
    CHECK( mav_seek( p, 0, 1, 0, 0, 0 ) == MAV_OK, "seek 0 again" );
    if (drain( p, 0, &dv )) return 1;
    CHECK( dv.buffers == frames && dv.gaps == 0 && dv.first_pts == 0, "video-first pass: %d pictures gaps %d", dv.buffers, dv.gaps );
    free( dv.data );
    if (drain( p, 1, &da )) return 1;
    CHECK( da.first_pts == 0 && da.gaps == 0 && fabs( da.size / 8.0 / 44100 - seconds ) < 1024.0 / 44100 + 0.001,
           "audio after queueing: %.4f s gaps %d", da.size / 8.0 / 44100, da.gaps );
    free( da.data );

    /* keyframe seek + exact trim: 1.6 s is picture 48; the demuxer lands on the keyframe at 45 */
    stub_vflushes = 0;
    CHECK( mav_seek( p, 1, 1, 16000000, 0, 0 ) == MAV_OK, "seek 1.6 s (on the audio stream: seeks all)" );
    CHECK( stub_vflushes == 1, "video decoder flushed" );
    {
        struct mav_buffer b; uint8_t *pic;
        CHECK( mav_get_buffer( p, 0, &b ) == MAV_OK && b.discontinuity, "picture after seek" );
        pic = malloc( b.size ); mav_copy_buffer( p, 0, pic, 0, b.size );
        CHECK( llabs( (long long)b.pts - 16000000 ) <= 1 && picture_index( pic, 0, MAV_PIX_NV12 ) == 48,
               "first picture after seek: pts %llu index %d", (unsigned long long)b.pts, picture_index( pic, 0, MAV_PIX_NV12 ) );
        free( pic ); mav_release_buffer( p, 0 );
    }
    if (drain( p, 1, &da )) return 1;
    CHECK( da.first_pts == 16000000 && da.discont == 1 && fabs( da.size / 8.0 / 44100 - (seconds - 1.6) ) < 1024.0 / 44100 + 0.001,
           "audio after seek: first %llu, %.4f s", (unsigned long long)da.first_pts, da.size / 8.0 / 44100 );
    free( da.data );
    if (drain( p, 0, &dv )) return 1;
    CHECK( dv.buffers == frames - 49, "the rest of the pictures (%d)", dv.buffers );
    free( dv.data );

    /* stop at 1.0 s: pictures 0..29, audio up to 1.0 s */
    CHECK( mav_seek( p, 0, 1, 0, 1, 10000000 ) == MAV_OK, "seek 0 stop 1 s" );
    if (drain( p, 0, &dv )) return 1;
    if (drain( p, 1, &da )) return 1;
    CHECK( dv.buffers == 30 && dv.end_pts <= 10000001, "stop: %d pictures to %llu", dv.buffers, (unsigned long long)dv.end_pts );
    CHECK( llabs( (long long)da.end_pts - 10000000 ) <= 1 && da.first_pts == 0, "stop: audio to %llu", (unsigned long long)da.end_pts );
    free( dv.data ); free( da.data );

    /* the earliest-buffer mode (stream handle 0 on the PE side) */
    CHECK( mav_seek( p, 0, 1, 0, 1, vi.duration ) == MAV_OK, "seek 0, no stop" );
    {
        int count[2] = { 0, 0 }; uint64_t last = 0; struct mav_buffer b; int r;
        while ((r = mav_get_buffer( p, -1, &b )) == MAV_OK)
        {
            CHECK( b.stream < 2 && b.pts + 1 >= last, "earliest: stream %u pts %llu after %llu", b.stream, (unsigned long long)b.pts, (unsigned long long)last );
            last = b.pts; count[b.stream]++;
            mav_release_buffer( p, b.stream );
        }
        CHECK( r == MAV_NO_BUFFER && count[0] == frames && count[1] > 100, "earliest: %d pictures %d audio buffers", count[0], count[1] );
    }

    /* disabling a stream: its packets are not queued, the other plays alone */
    mav_disable( p, 1 );
    CHECK( mav_seek( p, 0, 1, 0, 0, 0 ) == MAV_OK, "seek with audio disabled" );
    if (drain( p, 0, &dv )) return 1;
    CHECK( dv.buffers == frames && mav_get_buffer( p, 1, &(struct mav_buffer){0} ) == MAV_NO_BUFFER, "video alone" );
    free( dv.data );
    CHECK( s.oversize == 0 && s.out_of_range == 0, "requests within bounds" );
    src_stop( &s ); mav_destroy( p );
    CHECK( stub_vlive == 0, "no picture leaked (%d)", stub_vlive );
    printf( "PASS: mp4 (h264 + aac, moov at the end): %d pictures in display order from B-frame decode order, pixel-exact nv12; "
            "%.3f s of aac (rms %.2f) gap-free from 0; interleaved and video-first consumption; keyframe seek to 1.6 s exact "
            "on both streams; stop at 1 s; earliest-buffer mode; disable (%d requests)\n", frames, seconds, rms, s.requests );
    return 0;
}

static int test_mp4_formats( const uint8_t *mp4, size_t size )
{
    static const struct { enum mav_pixel_format fmt; int flip; const char *name; } fmts[] =
    {
        { MAV_PIX_NV12, 0, "nv12" }, { MAV_PIX_I420, 0, "i420" }, { MAV_PIX_YV12, 0, "yv12" }, { MAV_PIX_YUY2, 0, "yuy2" },
        { MAV_PIX_BGRx, 0, "bgrx" }, { MAV_PIX_BGRA, 0, "bgra" }, { MAV_PIX_RGBA, 0, "rgba" },
        { MAV_PIX_BGRx, 1, "bgrx bottom-up" }, { MAV_PIX_NV12, 1, "nv12 bottom-up" },
    };
    struct mav_parser *p = mav_create( 0 ); struct source s; struct mav_stream_info vi; unsigned int i;

    src_start( &s, p, mp4, size );
    CHECK( mav_connect( p, size ) == MAV_OK && mav_stream_info( p, 0, &vi ) == MAV_OK, "connect" );
    for (i = 0; i < sizeof(fmts) / sizeof(fmts[0]); i++)
    {
        struct mav_video_output o = vi.vnative; struct mav_buffer b; uint8_t *pic;
        o.fmt = fmts[i].fmt; o.height = fmts[i].flip ? -H : H;
        CHECK( mav_enable_video( p, 0, &o ) == MAV_OK, "enable %s", fmts[i].name );
        CHECK( mav_seek( p, 0, 1, 5 * 10000000ll / FPS, 0, 0 ) == MAV_OK, "seek" );
        CHECK( mav_get_buffer( p, 0, &b ) == MAV_OK, "get %s", fmts[i].name );
        pic = malloc( b.size );
        CHECK( mav_copy_buffer( p, 0, pic, 0, b.size ) == MAV_OK, "copy" );
        if (check_picture( pic, b.size, fmts[i].fmt, fmts[i].flip, 5, fmts[i].name )) return 1;
        free( pic );
        mav_release_buffer( p, 0 );
    }
    {
        struct mav_video_output o = vi.vnative;
        o.width = W / 2;
        CHECK( mav_enable_video( p, 0, &o ) == MAV_E_PARAM, "another size refused (no scaler)" );
        CHECK( mav_get_buffer( p, 0, &(struct mav_buffer){0} ) == MAV_NO_BUFFER, "refused stream is disabled" );
        o = vi.vnative; o.fmt = (enum mav_pixel_format)3;   /* BGR: not produced here */
        CHECK( mav_enable_video( p, 0, &o ) == MAV_E_PARAM, "unsupported pixel format refused" );
        CHECK( mav_enable( p, 0, &(struct mav_output){ MAV_FMT_S16, 44100, 2, 3 } ) == MAV_E_STATE, "audio enable on video refused" );
    }
    src_stop( &s ); mav_destroy( p );
    printf( "PASS: mp4 picture formats pixel-checked: nv12 i420 yv12 yuy2 bgrx bgra rgba (BT.601 within 1), bottom-up bgrx/nv12; "
            "other sizes and formats refused\n" );
    return 0;
}

static int test_mp4_refusals( void )
{
    size_t size, wsize; uint8_t *m, *wav = make_wav( &wsize, 8000, 1, 800 ); struct mav_parser *p; struct source s;
    struct mav_stream_info info;

    /* MADEIRA_WG_VIDEO=0: the ml1980 parser (mp3/wav only) */
    m = make_mp4( &size, AV_CODEC_ID_H264, A_AAC, 30, 1.0 );
    mav_configure( 0, &stub_video, &stub_audio, MAV_PIX_NV12 );
    p = mav_create( 0 ); src_start( &s, p, m, size );
    CHECK( mav_connect( p, size ) == MAV_E_UNSUPPORTED && mav_stream_count( p ) == 0, "video disabled: mp4 refused" );
    src_stop( &s );
    src_start( &s, p, wav, wsize );
    CHECK( mav_connect( p, wsize ) == MAV_OK, "video disabled: wav still plays" );
    src_stop( &s ); mav_destroy( p );
    mav_configure( 1, &stub_video, &stub_audio, MAV_PIX_NV12 );

    /* a compressed-output parser (quartz's demuxing splitters) refuses mp4 */
    p = mav_create( 1 ); src_start( &s, p, m, size );
    CHECK( mav_connect( p, size ) == MAV_E_UNSUPPORTED, "compressed-output parser refuses mp4" );
    src_stop( &s ); mav_destroy( p );

    /* the platform decoder refuses to open: the file is refused with its reason */
    stub_avcc[4] ^= 0x01;
    p = mav_create( 0 ); src_start( &s, p, m, size );
    CHECK( mav_connect( p, size ) == MAV_E_UNSUPPORTED, "backend open failure refuses the file" );
    src_stop( &s ); mav_destroy( p );
    stub_avcc[4] ^= 0x01;
    av_free( m );

    /* no platform backend at all */
    m = make_mp4( &size, AV_CODEC_ID_H264, A_NONE, 30, 0 );
    mav_configure( 1, NULL, NULL, MAV_PIX_NV12 );
    p = mav_create( 0 ); src_start( &s, p, m, size );
    CHECK( mav_connect( p, size ) == MAV_E_UNSUPPORTED, "no backend: refused" );
    src_stop( &s ); mav_destroy( p );
    mav_configure( 1, &stub_video, &stub_audio, MAV_PIX_NV12 );
    av_free( m );

    /* a video codec this port has no decoder for */
    m = make_mp4( &size, AV_CODEC_ID_MPEG4, A_AAC, 30, 1.0 );
    CHECK( m, "mpeg4 mp4" );
    p = mav_create( 0 ); src_start( &s, p, m, size );
    CHECK( mav_connect( p, size ) == MAV_E_UNSUPPORTED, "mpeg4 video refused" );
    src_stop( &s ); mav_destroy( p ); av_free( m );

    /* an audio codec it has no decoder for, next to a good video: the video alone */
    m = make_mp4( &size, AV_CODEC_ID_H264, A_PCM_BE, 30, 1.0 );
    p = mav_create( 0 ); src_start( &s, p, m, size );
    CHECK( mav_connect( p, size ) == MAV_OK && mav_stream_count( p ) == 1, "pcm_s16be not exposed, video is" );
    CHECK( mav_stream_info( p, 0, &info ) == MAV_OK && info.type == MAV_STREAM_VIDEO, "stream 0 is the video" );
    src_stop( &s ); mav_destroy( p ); av_free( m );

    /* audio-only m4a (aac) */
    m = make_mp4( &size, AV_CODEC_ID_NONE, A_AAC, 0, 2.0 );
    p = mav_create( 0 ); src_start( &s, p, m, size );
    CHECK( mav_connect( p, size ) == MAV_OK && mav_stream_count( p ) == 1, "m4a" );
    CHECK( mav_stream_info( p, 0, &info ) == MAV_OK && info.kind == MAV_CODEC_AAC, "m4a is aac" );
    {
        struct drained d;
        CHECK( mav_seek( p, 0, 1, 0, 0, 0 ) == MAV_OK, "seek" );
        if (drain( p, 0, &d )) return 1;
        CHECK( d.first_pts == 0 && d.gaps == 0 && fabs( d.size / 8.0 / 44100 - 2.0 ) < 1024.0 / 44100 + 0.001, "m4a %.4f s", d.size / 8.0 / 44100 );
        free( d.data );
    }
    src_stop( &s ); mav_destroy( p ); av_free( m );
    free( wav );
    printf( "PASS: mp4 refusals: MADEIRA_WG_VIDEO=0 (wav still plays), compressed-output parser, backend open failure, "
            "no backend, mpeg4 video; unsupported audio leaves the video exposed; audio-only m4a plays\n" );
    return 0;
}

static int test_mp4_late_audio( const uint8_t *mp4, size_t size, double seconds )
{
    struct mav_parser *p = mav_create( 0 ); struct source s; struct drained d;
    stub_adelay = 1;
    src_start( &s, p, mp4, size );
    CHECK( mav_connect( p, size ) == MAV_OK, "connect" );
    CHECK( mav_seek( p, 1, 1, 0, 0, 0 ) == MAV_OK, "seek" );
    if (drain( p, 1, &d )) return 1;
    /* the decoder's last packet never comes out; everything else keeps its own time */
    CHECK( d.first_pts == 0 && d.gaps == 0 && fabs( d.size / 8.0 / 44100 - seconds ) < 2048.0 / 44100 + 0.001,
           "late decoder: first %llu gaps %d %.4f s", (unsigned long long)d.first_pts, d.gaps, d.size / 8.0 / 44100 );
    free( d.data );
    src_stop( &s ); mav_destroy( p );
    stub_adelay = 0;
    printf( "PASS: an AAC decoder that answers one packet late keeps a gap-free timeline from 0\n" );
    return 0;
}

static uint8_t *read_file( const char *path, size_t *size )
{
    FILE *f = fopen( path, "rb" ); uint8_t *b; long n;
    if (!f) return NULL;
    fseek( f, 0, SEEK_END ); n = ftell( f ); fseek( f, 0, SEEK_SET );
    b = malloc( n ); *size = fread( b, 1, n, f ); fclose( f );
    return b;
}

int main( int argc, char **argv )
{
    size_t mp2_size, wsize, mp4_size; uint8_t *mp2, *wav, *mp4;
    const int frames = 90; const double seconds = 3.0;
    av_log_set_level( AV_LOG_ERROR );
    if (argc > 1 && !strcmp( argv[1], "cap" ))
    {
        int i;
        for (i = 0; i < 100; i++) mav_log( "line %d", i );
        return 0;
    }
    if (argc > 1 && !strcmp( argv[1], "dup" ))
    {
        int i;
        for (i = 0; i < 20; i++) mav_log( "connect refused (no container, compressed_out=0): same" );
        mav_log( "a different line" );
        return 0;
    }
    mav_configure( 1, &stub_video, &stub_audio, MAV_PIX_NV12 );
    mp2 = make_mp2( &mp2_size, 44100, 3.0 );
    if (!mp2) { printf( "FAIL: no mp2 encoder in the host build\n" ); return 1; }
    if (test_wav()) return 1;
    if (test_wav_compressed_out_and_garbage()) return 1;
    if (test_mpeg( mp2, mp2_size, "synthetic MPEG-1 layer II", 2, 3.0 )) return 1;
    wav = make_wav( &wsize, 44100, 2, 44100 * 4 );
    if (test_read_error( wav, wsize )) return 1;
    if (test_disconnect_wakes_reader( wav, wsize )) return 1;
    mp4 = make_mp4( &mp4_size, AV_CODEC_ID_H264, A_AAC, frames, seconds );
    if (!mp4) { printf( "FAIL: could not synthesise the mp4\n" ); return 1; }
    if (test_mp4_basic( mp4, mp4_size, frames, seconds )) return 1;
    if (test_mp4_formats( mp4, mp4_size )) return 1;
    if (test_mp4_late_audio( mp4, mp4_size, seconds )) return 1;
    if (test_mp4_refusals()) return 1;
    if (argc > 1)
    {
        size_t size; uint8_t *mp3 = read_file( argv[1], &size ); double secs = argc > 2 ? atof( argv[2] ) : 0;
        if (!mp3) { printf( "FAIL: cannot read %s\n", argv[1] ); return 1; }
        if (test_mpeg( mp3, size, "real MP3", 3, secs )) return 1;
        free( mp3 );
    }
    else printf( "SKIP: no real MP3 available (set MADEIRA_TEST_MP3)\n" );
    free( mp2 ); free( wav ); av_free( mp4 );
    return failures ? 1 : 0;
}
"""

mp3 = os.environ.get("MADEIRA_TEST_MP3")
if not mp3:
    for cand in ["/mnt/c/Windows/ImmersiveControlPanel/SystemSettings/Assets/Aria.mp3",
                 "/mnt/c/Windows/ImmersiveControlPanel/SystemSettings/Assets/Guy.mp3"]:
        if Path(cand).exists():
            mp3 = cand
            break

TAG = "[wg-parser] ml1990 "
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "wgp.c"; c.write_text(harness)
    exe = Path(t) / "wgp"
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-Wall", "-Wno-unused-function", "-fsanitize=address,undefined",
                    "-fno-sanitize-recover=undefined", "-I" + str(core.parent), "-I" + str(inc), str(c), "-o", str(exe),
                    str(lib / "libavformat.a"), str(lib / "libavcodec.a"), str(lib / "libswresample.a"),
                    str(lib / "libavutil.a"), "-lm", "-lpthread"], check=True)
    args = [str(exe)]
    if mp3:
        args += [mp3]
    env = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
    env["ASAN_OPTIONS"] = "detect_leaks=1"
    if mp3:
        # first pass: learn the stream's duration from the parser's own connect line
        probe = subprocess.run(args + ["0"], env=env, capture_output=True, text=True)
        m = re.search(r"container=mp3 codec=mp3\w* layer=3 .*? duration=(\d+)ms", probe.stderr)
        assert m, probe.stdout + probe.stderr
        args += ["%.3f" % (int(m.group(1)) / 1000.0)]
    out = subprocess.run(args, env=env, capture_output=True, text=True)
    print(out.stdout, end="")
    assert out.returncode == 0, out.stdout + out.stderr
    lines = [l for l in out.stderr.splitlines() if l.startswith(TAG)]
    assert 0 < len(lines) and not any("suppressed" in l for l in lines), lines
    assert any("connect container=wav codec=pcm_s16le layer=0 rate=22050 channels=2 mask=0x3 out=s16 duration=1000ms" in l for l in lines), lines
    assert any("connect container=mp3 codec=mp2" in l and "layer=2 rate=44100 channels=2" in l for l in lines), lines
    assert any("connect refused (mp3, compressed_out=1)" in l for l in lines), lines
    assert any("connect refused" in l and "no enabled demuxer recognised the stream" in l for l in lines), lines
    assert any("connect container=mp4 stream=0 video codec=h264 backend=stub-video 320x240 fps=30/1 out=nv12" in l for l in lines), lines
    assert any("connect container=mp4 codec=aac layer=0 rate=44100 channels=2 mask=0x3 out=f32" in l and "stream=1 backend=stub-aac" in l for l in lines), lines
    assert any("connect refused (mov,mp4,m4a,3gp,3g2,mj2, compressed_out=0): container disabled by MADEIRA_WG_VIDEO=0" in l for l in lines), lines
    assert any("connect refused (mov,mp4,m4a,3gp,3g2,mj2, compressed_out=1): compressed output requested" in l for l in lines), lines
    assert any("video codec h264 (codec id 27" in l and "stub: unexpected codec data" in l for l in lines), lines
    assert any("video codec h264 (codec id 27" in l and "no video decoder backend" in l for l in lines), lines
    assert any("video codec mpeg4 (codec id 12" in l and "no decoder for it in this port" in l for l in lines), lines
    assert any("audio codec pcm_s16be (codec id" in l and "not exposed" in l for l in lines), lines
    assert "ERROR: AddressSanitizer" not in out.stderr and "runtime error" not in out.stderr, out.stderr
    cap = subprocess.run([str(exe), "cap"], env=env, capture_output=True, text=True)
    assert cap.returncode == 0, cap.stdout + cap.stderr
    capped = [l for l in cap.stderr.splitlines() if l.startswith(TAG)]
    assert len(capped) == 64 and capped[-1] == TAG + "further distinct parser lines suppressed after 63", capped[-3:]
    dup = subprocess.run([str(exe), "dup"], env=env, capture_output=True, text=True)
    duped = [l for l in dup.stderr.splitlines() if l.startswith(TAG)]
    assert [l[len(TAG):] for l in duped] == ["connect refused (no container, compressed_out=0): same"] + \
        ["connect refused (no container, compressed_out=0): same (repeat #%d)" % n for n in (2, 4, 8, 16)] + \
        ["a different line"], duped
    print("PASS: %d [wg-parser] log lines (%d distinct); cap 63 distinct + notice; 20 identical lines -> 5 (#1,#2,#4,#8,#16); "
          "ASan/UBSan clean" % (len(lines), len(set(re.sub(r" \(repeat #\d+\)$", "", l) for l in lines))))
    for l in lines:
        print("  " + l)
