/* The wg_parser core for iOS: a pull demuxer + decoders on libavformat /
 * libavcodec / libswresample, with the platform decoders behind
 * wg_parser_backend_ios.h.                         (MADEIRA ml1980, ml1990)
 *
 * WHY THIS EXISTS
 * ---------------
 * ml1980: a 32-bit title plays its music as MP3 through DirectShow.  quartz's
 * autoplugger asks winegstreamer.dll for a splitter, and both candidates are
 * wg_parser users:
 *
 *   quartz:autoplug Failed to create filter for "MPEG-I Stream Splitter", hr 0x8007000e
 *   quartz:autoplug Failed to create filter for "GStreamer splitter filter", hr 0x8007000e
 *
 * 0x8007000e is quartz_parser.c parser_create()'s E_OUTOFMEMORY, which is what
 * it returns when wg_parser_create() fails -- and on this port every
 * wg_parser_* entry of the unix side returned STATUS_NOT_IMPLEMENTED, because
 * the upstream unix side is a GStreamer pipeline and there is no GStreamer on
 * iOS.
 *
 * ml1990: a 64-bit title opens its menu video (an MP4 embedded in one of its
 * data files) through Media Foundation's source resolver.  mfmp4srcsnk.dll is
 * absent, so the resolver falls back to winegstreamer's media source
 * (media_source.c), which is a wg_parser user too -- and this core refused the
 * MP4 ("no enabled demuxer recognised the stream").  The title reported
 * MF_E_UNSUPPORTED_BYTESTREAM_TYPE, retried about twelve times a second, and
 * its menu, which waits for the video, never appeared.  MP4/MOV with H.264 or
 * HEVC video and AAC (or MPEG audio / PCM) audio is now demuxed here and
 * decoded by VideoToolbox / AudioToolbox (wg_parser_apple_ios.c).
 * MADEIRA_WG_VIDEO=0 (read by the glue) restores the MP3/WAV-only behaviour.
 *
 * WHAT IS IMPLEMENTED
 * -------------------
 * The subset of wg_parser.c's semantics that quartz_parser.c and
 * media_source.c drive:
 *
 *   - the PULL protocol.  The PE side runs a read thread that loops on
 *     wg_parser_get_next_read_offset() (which BLOCKS until the parser wants
 *     bytes) and answers every request with wg_parser_push_data().  Here the
 *     demuxer's AVIOContext read callback is the requester: it publishes
 *     {offset, size}, wakes the read thread, and sleeps until push_data has
 *     copied the bytes straight into the AVIO buffer.  push_data with size 0
 *     is end of file, with a NULL pointer a read error.
 *
 *   - connect() probes and analyses on the caller's thread through that
 *     protocol.  The demuxer name, the probe score and every codec are checked
 *     against an allowlist, so content this port cannot play fails connect()
 *     with an error (quartz goes on to its next filter; media_source reports
 *     the failure) instead of being accepted and never producing a sample.
 *     An unsupported codec is logged with its libavcodec id.
 *
 *   - STREAMS.  An MP3/WAV file exposes its first audio stream.  An MP4 or
 *     an ASF (WMV/WMA, the Windows Media Format reader's files: wm_reader.c)
 *     exposes its first video stream and its first audio stream, in container
 *     order.  A file whose video cannot be decoded is refused outright; one
 *     whose audio cannot be decoded exposes the video alone (logged).  An
 *     ASF's Windows Media video is decoded here, in software, by libavcodec
 *     (mav_lavc_video), its WMA by libavcodec like MPEG audio.
 *
 *   - one demuxer, several consumers.  wg_parser.c runs a GStreamer thread
 *     that parks one buffer per stream; here decoding is LAZY, on the thread
 *     that asks for a buffer, and a packet read for a stream other than the
 *     one being served is queued for that stream (dropped if it is disabled).
 *     A queue another thread reads holds back the reader that fills it once
 *     it passes a soft limit (mav_wait_drain), so a stream that falls behind
 *     no longer loses packets; past the hard limit (an unread stream only)
 *     the overflow is dropped and logged.  One buffer per stream is
 *     outstanding until release_buffer; S_FALSE at end of stream.
 *
 *   - video.  The native format reported by get_current_format is 4:2:0 NV12
 *     at the coded display size (MADEIRA_WG_VIDEO_FORMAT can choose another,
 *     see the glue), which media_source.c turns into NV12 / YV12 / YUY2 /
 *     I420 / IYUV media types.  stream_enable accepts NV12, I420, YV12, YUY2,
 *     UYVY, YVYU, BGRx (RGB32), BGRA (ARGB32), RGBA (ABGR32), BGR (RGB24, the
 *     WM reader's default), RGB16 (565) and RGB15 (555) at the native size,
 *     with a negative height meaning bottom-up rows, exactly as wg_format says.
 *     Frames are laid out the way GStreamer lays them out (4-byte aligned
 *     strides) because that is what wg_format_get_stride() / the PE side
 *     assume.  Decoded pictures come back in decode order and are re-ordered
 *     here by presentation time (a picture is final once the demuxer's decode
 *     time has reached it, which no later packet can undercut).
 *
 *   - "output_compressed" parsers (MPEG-I splitter, WAVE parser, AVI
 *     splitter) hand the COMPRESSED stream to a separate decoder filter.  This
 *     port has no such decoder filters, so they accept PCM only; MP3 and MP4
 *     are refused there and quartz then tries the decoding splitter.
 *
 *   - seek is accurate: the demuxer seeks at or before the target (to a video
 *     keyframe when there is video), decoders are flushed, and decoded output
 *     before the target is dropped (audio trimmed to the sample), so the first
 *     buffer after a seek starts at the requested time.  A stop position ends
 *     every stream there.  Seeking any stream seeks them all, as in wg_parser.c.
 *
 * This file does not include any Wine header.  winegstreamer_unixlib_ios.c
 * includes it and maps the Wine structures onto the small API below, and
 * tests/host/check-wg-parser.py compiles it on its own against a host
 * FFmpeg, with stub backends, to exercise it under ASan.
 *
 * LOGGING: "[wg-parser] ml1990 ..." on stderr.  At most MAV_MAX_LOGS distinct
 * lines per process; a line identical to an earlier one is repeated only at
 * its 2nd, 4th, 8th ... occurrence with the count, so a caller that retries a
 * refused file forever neither floods the log nor hides the first refusals.
 */

#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#include "wg_parser_backend_ios.h"

/***********************************************************************
 *           API (used by winegstreamer_unixlib_ios.c and the host test)
 */

/* Same order as unixlib.h `enum wg_audio_format`; the glue asserts it. */
enum mav_sample_format
{
    MAV_FMT_UNKNOWN = 0,
    MAV_FMT_U8,
    MAV_FMT_S16,
    MAV_FMT_S24,
    MAV_FMT_S32,
    MAV_FMT_F32,
    MAV_FMT_F64,
};

/* The same VALUES as unixlib.h `enum wg_video_format`; the glue asserts it. */
enum mav_pixel_format
{
    MAV_PIX_UNKNOWN = 0,
    MAV_PIX_BGRA = 1,
    MAV_PIX_BGRx = 2,
    MAV_PIX_BGR = 3,            /* 24-bit, B G R bytes: the WM reader's default output */
    MAV_PIX_RGB15 = 4,          /* 16-bit x1r5g5b5, little-endian */
    MAV_PIX_RGB16 = 5,          /* 16-bit r5g6b5, little-endian */
    MAV_PIX_RGBA = 6,
    MAV_PIX_I420 = 8,
    MAV_PIX_NV12 = 9,
    MAV_PIX_UYVY = 11,
    MAV_PIX_YUY2 = 12,
    MAV_PIX_YV12 = 13,
    MAV_PIX_YVYU = 14,
};

enum mav_status
{
    MAV_OK = 0,
    MAV_NO_BUFFER = 1,          /* end of stream, or the stream is disabled */
    MAV_E_STATE = -1,           /* not connected / no buffer / no request pending */
    MAV_E_UNSUPPORTED = -2,     /* content this port does not handle */
    MAV_E_IO = -3,              /* the read protocol failed */
    MAV_E_NOMEM = -4,
    MAV_E_PARAM = -5,
};

enum mav_stream_type
{
    MAV_STREAM_AUDIO = 1,
    MAV_STREAM_VIDEO = 2,
};

enum mav_codec_kind
{
    MAV_CODEC_PCM = 1,
    MAV_CODEC_MPEG_AUDIO = 2,
    MAV_CODEC_AAC = 3,
    MAV_CODEC_H264 = 4,
    MAV_CODEC_HEVC = 5,
    MAV_CODEC_WMA = 6,          /* WMA v1/v2/Pro/Lossless in ASF, on libavcodec */
    MAV_CODEC_WMV = 7,          /* WMV7/8/9, VC-1, MS-MPEG4 in ASF, on libavcodec (mav_lavc_video) */
};

/* Which Windows Media video a MAV_CODEC_WMV stream is (wg_format's WMV
 * formats, mapped by the glue); 0 for the MS-MPEG4 family, which has none. */
enum mav_wmv_format
{
    MAV_WMV_NONE = 0,
    MAV_WMV_WMV1,
    MAV_WMV_WMV2,
    MAV_WMV_WMV3,
    MAV_WMV_WMVA,
    MAV_WMV_WVC1,
};

struct mav_output
{
    enum mav_sample_format fmt;
    uint32_t rate;
    uint32_t channels;
    uint32_t channel_mask;      /* WinMM order == AV_CH_* order for bits 0-17 */
};

struct mav_video_output
{
    enum mav_pixel_format fmt;
    int32_t width, height;      /* height < 0: bottom-up rows (wg_format) */
    uint32_t fps_n, fps_d;
};

struct mav_stream_info
{
    enum mav_stream_type type;
    char codec[32];             /* libavcodec's codec name, for the log */
    char container[16];
    char backend[16];           /* "libavcodec", or the platform backend's name */
    enum mav_codec_kind kind;
    uint32_t layer;             /* MPEG audio layer, 0 otherwise */
    uint32_t bitrate;
    struct mav_output native;   /* audio: what the stream decodes to by default */
    struct mav_video_output vnative;   /* video: likewise */
    uint32_t profile, level;    /* H.264 */
    uint32_t version;           /* WMA: 1, 2, 3 (Pro) or 4 (Lossless) */
    uint32_t block_align, depth;   /* WMA */
    enum mav_wmv_format wmv;    /* WMV */
    uint32_t codec_data_len;    /* AAC: AudioSpecificConfig; H.264: avcC; WMA / WMV: the
                                 * WAVEFORMATEX / BITMAPINFOHEADER extra bytes (if they fit) */
    uint8_t codec_data[64];
    uint64_t duration;          /* 100 ns, 0 when unknown */
};

struct mav_buffer
{
    uint64_t pts;               /* 100 ns, stream time */
    uint64_t duration;          /* 100 ns */
    uint32_t size;              /* bytes */
    uint32_t stream;            /* index of the stream it belongs to */
    int discontinuity;
    int delta;                  /* video: not a keyframe (informational) */
};

#define MAV_MAX_STREAMS 2

struct mav_parser;

static void mav_configure( int video_allowed, const struct mav_video_backend *video,
                           const struct mav_audio_backend *audio, enum mav_pixel_format native );
static struct mav_parser *mav_create( int output_compressed );
static void mav_destroy( struct mav_parser *p );
static int mav_connect( struct mav_parser *p, uint64_t file_size );
static void mav_disconnect( struct mav_parser *p );
static int mav_get_next_read_offset( struct mav_parser *p, uint64_t *offset, uint32_t *size );
static int mav_push_data( struct mav_parser *p, const void *data, uint32_t size );
static unsigned int mav_stream_count( struct mav_parser *p );
static int mav_stream_info( struct mav_parser *p, unsigned int stream, struct mav_stream_info *info );
static int mav_current_output( struct mav_parser *p, unsigned int stream, struct mav_output *out );
static int mav_current_video( struct mav_parser *p, unsigned int stream, struct mav_video_output *out );
static int mav_enable( struct mav_parser *p, unsigned int stream, const struct mav_output *out );
static int mav_enable_video( struct mav_parser *p, unsigned int stream, const struct mav_video_output *out );
static void mav_disable( struct mav_parser *p, unsigned int stream );
/* stream < 0: the earliest buffer of any enabled stream (buffer->stream says which) */
static int mav_get_buffer( struct mav_parser *p, int stream, struct mav_buffer *buffer );
static int mav_copy_buffer( struct mav_parser *p, unsigned int stream, void *dst, uint32_t offset, uint32_t size );
static void mav_release_buffer( struct mav_parser *p, unsigned int stream );
static int mav_seek( struct mav_parser *p, unsigned int stream, int set_start, uint64_t start,
                     int set_stop, uint64_t stop );

/***********************************************************************
 *           implementation
 */

#define MAV_TAG "[wg-parser] ml1990 "
#define MAV_MAX_LOGS 64
#define MAV_AVIO_BUFFER (64 * 1024)
/* One request is at most this many bytes; AVIO copes with short reads. */
#define MAV_MAX_REQUEST (1024 * 1024)
/* Bytes avformat_find_stream_info may read.  Enough for many seconds of any
 * stream here; it bounds the analysis of an MP3 carrying cover art, whose
 * (undecodable) picture stream would otherwise keep the analysis reading. */
#define MAV_PROBESIZE (256 * 1024)
/* mp3dec.c's probe gives AVPROBE_SCORE_EXTENSION / 4 to a file that starts
 * with an ID3v2 tag larger than the probe buffer; anything below that is the
 * "detected only with low score" guess that misreads other MPEG files. */
#define MAV_MIN_PROBE_SCORE (AVPROBE_SCORE_EXTENSION / 4)
/* An ISO media file with a recognisable ftyp/moov/mdat scores 100; half of
 * that is the floor for accepting one without a file name. */
#define MAV_MIN_MOV_PROBE_SCORE (AVPROBE_SCORE_MAX / 2)
/* Consecutive undecodable packets before the stream is ended rather than
 * spun on. */
#define MAV_MAX_DECODE_ERRORS 512
#define MAV_MAX_CHANNELS 8
/* Pictures held for presentation-order output beyond what the decode-time
 * rule releases (a stream without decode times, or a broken one). */
#define MAV_REORDER_MAX 16
/* Packets queued for a stream nobody is reading from yet. */
#ifndef MAV_QUEUE_MAX_PACKETS   /* tests/host/check-wg-parser.py and check-wg-parser-asf.py build with small limits */
#define MAV_QUEUE_MAX_PACKETS 16384
#endif
#ifndef MAV_QUEUE_MAX_BYTES
#define MAV_QUEUE_MAX_BYTES ((size_t)64 << 20)
#endif
/* Back-pressure (mav_wait_drain).  A stream whose queue passes these, while
 * another thread reads it, holds the reader that demuxes for it until it has
 * drained to three quarters of them; the hard limits above then only apply to
 * a stream nobody reads (MAV_BACKPRESSURE_WAIT_MS without a read).  A packet
 * dropped from a video stream breaks every picture up to its next keyframe. */
#ifndef MAV_QUEUE_SOFT_PACKETS
#define MAV_QUEUE_SOFT_PACKETS 1024
#endif
#ifndef MAV_QUEUE_SOFT_BYTES
#define MAV_QUEUE_SOFT_BYTES ((size_t)16 << 20)
#endif
#ifndef MAV_BACKPRESSURE_WAIT_MS
#define MAV_BACKPRESSURE_WAIT_MS 5000
#endif
#define MAV_MAX_DIMENSION 8192

#define MAV_MOV_NAME "mov,mp4,m4a,3gp,3g2,mj2"

/* ---- configuration (set once by the glue, or by the host test) ---- */
static int mav_video_allowed = 1;
static const struct mav_video_backend *mav_vbackend;
static const struct mav_audio_backend *mav_abackend;
static enum mav_pixel_format mav_native_pix = MAV_PIX_NV12;

static void mav_configure( int video_allowed, const struct mav_video_backend *video,
                           const struct mav_audio_backend *audio, enum mav_pixel_format native )
{
    mav_video_allowed = !!video_allowed;
    mav_vbackend = video;
    mav_abackend = audio;
    mav_native_pix = native ? native : MAV_PIX_NV12;
}

/* ---- the log: bounded, and deduplicated ---- */
static pthread_mutex_t mav_log_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { uint32_t hash; uint32_t count; } mav_log_seen[MAV_MAX_LOGS];
static unsigned int mav_log_distinct;
static int mav_log_capped;

static void mav_log( const char *fmt, ... ) __attribute__((format(printf, 1, 2)));
static void mav_log( const char *fmt, ... )
{
    char line[512];
    uint32_t hash = 2166136261u, count = 0;
    unsigned int i;
    va_list args;
    const char *c;

    va_start( args, fmt );
    vsnprintf( line, sizeof(line), fmt, args );
    va_end( args );
    for (c = line; *c; c++) hash = (hash ^ (uint8_t)*c) * 16777619u;

    pthread_mutex_lock( &mav_log_lock );
    for (i = 0; i < mav_log_distinct; i++)
        if (mav_log_seen[i].hash == hash)
        {
            count = ++mav_log_seen[i].count;
            break;
        }
    if (i == mav_log_distinct)
    {
        if (mav_log_distinct + 1 >= MAV_MAX_LOGS)
        {
            if (!mav_log_capped)
            {
                mav_log_capped = 1;
                dprintf( 2, MAV_TAG "further distinct parser lines suppressed after %u\n", MAV_MAX_LOGS - 1 );
            }
            pthread_mutex_unlock( &mav_log_lock );
            return;
        }
        mav_log_seen[mav_log_distinct].hash = hash;
        mav_log_seen[mav_log_distinct].count = count = 1;
        mav_log_distinct++;
    }
    pthread_mutex_unlock( &mav_log_lock );

    if (count == 1)
        dprintf( 2, MAV_TAG "%s\n", line );
    else if (!(count & (count - 1)))
        dprintf( 2, MAV_TAG "%s (repeat #%u)\n", line, count );
}

/* Left in AVCodecContext.opaque so a shared av_log callback can tell this
 * core's decoder from any other user of libavcodec in the process. */
static const char mav_decoder_marker;
#define MAV_DECODER_MARKER ((void *)&mav_decoder_marker)

struct mav_vframe
{
    void *handle;               /* the backend's picture */
    int64_t pts, duration;      /* stream time base */
};

/***********************************************************************
 *           the libavcodec video backend (Windows Media video)
 *
 * WMV7/8 (wmv1, wmv2), WMV9 (wmv3), VC-1 (WMVA, WVC1) and MS-MPEG4 v1-v3 have
 * no platform decoder on iOS, so they are decoded here, in software, by
 * libavcodec, behind the same contract as the platform backend.  The decoders
 * produce 4:2:0 planar pictures, copied into the NV12 layout the contract
 * maps.  They reorder internally: pictures come out in presentation order
 * with their own timestamps, so the core releases them at once (no decode
 * timestamps in ASF to release them by), and they hold the last pictures back
 * until mav_lavc_drain at the end of the stream.
 */
enum
{
    MAV_LAVC_WMV1 = 64, MAV_LAVC_WMV2, MAV_LAVC_WMV3, MAV_LAVC_VC1,
    MAV_LAVC_MSMPEG4V1, MAV_LAVC_MSMPEG4V2, MAV_LAVC_MSMPEG4V3,
};

struct mav_lavc_vdec
{
    AVCodecContext *ctx;
    AVPacket *pkt;
    AVFrame *frame;
    unsigned int bad_format_logged;
};

struct mav_lavc_picture
{
    uint8_t *data;              /* Y plane, then the interleaved CbCr plane */
    uint32_t width, height, y_stride, uv_stride;
    int full_range;
};

static enum AVCodecID mav_lavc_codec_id( int codec )
{
    switch (codec)
    {
    case MAV_LAVC_WMV1:      return AV_CODEC_ID_WMV1;
    case MAV_LAVC_WMV2:      return AV_CODEC_ID_WMV2;
    case MAV_LAVC_WMV3:      return AV_CODEC_ID_WMV3;
    case MAV_LAVC_VC1:       return AV_CODEC_ID_VC1;
    case MAV_LAVC_MSMPEG4V1: return AV_CODEC_ID_MSMPEG4V1;
    case MAV_LAVC_MSMPEG4V2: return AV_CODEC_ID_MSMPEG4V2;
    case MAV_LAVC_MSMPEG4V3: return AV_CODEC_ID_MSMPEG4V3;
    default:                 return AV_CODEC_ID_NONE;
    }
}

static int mav_lavc_supports( int codec )
{
    enum AVCodecID id = mav_lavc_codec_id( codec );
    return id != AV_CODEC_ID_NONE && avcodec_find_decoder( id ) != NULL;
}

static void mav_lavc_close( void *handle )
{
    struct mav_lavc_vdec *d = handle;

    if (!d) return;
    avcodec_free_context( &d->ctx );
    av_packet_free( &d->pkt );
    av_frame_free( &d->frame );
    free( d );
}

static void *mav_lavc_open( int codec, const uint8_t *extradata, uint32_t extradata_size,
                            uint32_t width, uint32_t height, char *why, size_t why_size )
{
    const AVCodec *dec = avcodec_find_decoder( mav_lavc_codec_id( codec ) );
    struct mav_lavc_vdec *d;

    if (!dec)
    {
        snprintf( why, why_size, "no decoder in this build" );
        return NULL;
    }
    if (!(d = calloc( 1, sizeof(*d) ))) return NULL;
    if (!(d->ctx = avcodec_alloc_context3( dec )) || !(d->pkt = av_packet_alloc()) || !(d->frame = av_frame_alloc()))
        goto fail;
    d->ctx->opaque = MAV_DECODER_MARKER;
    d->ctx->width = d->ctx->coded_width = (int)width;
    d->ctx->height = d->ctx->coded_height = (int)height;
    d->ctx->thread_count = 1;   /* every call is made under the parser's lock, one at a time */
    if (extradata_size)
    {
        if (!(d->ctx->extradata = av_mallocz( (size_t)extradata_size + AV_INPUT_BUFFER_PADDING_SIZE ))) goto fail;
        memcpy( d->ctx->extradata, extradata, extradata_size );
        d->ctx->extradata_size = (int)extradata_size;
    }
    if (avcodec_open2( d->ctx, dec, NULL ) < 0)
    {
        snprintf( why, why_size, "decoder did not open" );
        goto fail;
    }
    return d;
fail:
    mav_lavc_close( d );
    return NULL;
}

/* One decoded picture into its own NV12 copy, handed to `emit`. */
static void mav_lavc_emit( struct mav_lavc_vdec *d, const AVFrame *f, mav_vframe_emit emit, void *ctx )
{
    struct mav_lavc_picture *pic;
    uint32_t w = (uint32_t)f->width, h = (uint32_t)f->height, cw = (w + 1) / 2, ch = (h + 1) / 2, x, y;
    int64_t pts = f->pts != AV_NOPTS_VALUE ? f->pts : f->best_effort_timestamp;

    if (f->format != AV_PIX_FMT_YUV420P && f->format != AV_PIX_FMT_YUVJ420P)
    {
        if (d->bad_format_logged++ < 3)
            mav_log( "%s: picture in pixel format %d, not 4:2:0 planar; dropped", d->ctx->codec->name, f->format );
        return;
    }
    if (!w || !h || w > MAV_MAX_DIMENSION || h > MAV_MAX_DIMENSION || !(pic = calloc( 1, sizeof(*pic) ))) return;
    pic->width = w;
    pic->height = h;
    pic->y_stride = w;
    pic->uv_stride = cw * 2;
    pic->full_range = f->format == AV_PIX_FMT_YUVJ420P || f->color_range == AVCOL_RANGE_JPEG;
    if (!(pic->data = malloc( (size_t)w * h + (size_t)pic->uv_stride * ch )))
    {
        free( pic );
        return;
    }
    for (y = 0; y < h; y++) memcpy( pic->data + (size_t)y * w, f->data[0] + (size_t)y * f->linesize[0], w );
    for (y = 0; y < ch; y++)
    {
        const uint8_t *u = f->data[1] + (size_t)y * f->linesize[1], *v = f->data[2] + (size_t)y * f->linesize[2];
        uint8_t *uv = pic->data + (size_t)w * h + (size_t)y * pic->uv_stride;
        for (x = 0; x < cw; x++)
        {
            uv[2 * x] = u[x];
            uv[2 * x + 1] = v[x];
        }
    }
    emit( ctx, pic, pts == AV_NOPTS_VALUE ? INT64_MIN : pts, f->duration > 0 ? f->duration : INT64_MIN );
}

static void mav_lavc_receive( struct mav_lavc_vdec *d, mav_vframe_emit emit, void *ctx )
{
    while (avcodec_receive_frame( d->ctx, d->frame ) >= 0)
    {
        mav_lavc_emit( d, d->frame, emit, ctx );
        av_frame_unref( d->frame );
    }
}

static int mav_lavc_decode( void *handle, const uint8_t *data, uint32_t size, int64_t pts, int64_t duration,
                            int keyframe, mav_vframe_emit emit, void *ctx )
{
    struct mav_lavc_vdec *d = handle;
    int err;

    /* not reference-counted: libavcodec takes a padded copy */
    d->pkt->data = (uint8_t *)data;
    d->pkt->size = (int)size;
    d->pkt->pts = pts == INT64_MIN ? AV_NOPTS_VALUE : pts;
    d->pkt->dts = AV_NOPTS_VALUE;
    d->pkt->duration = duration == INT64_MIN ? 0 : duration;
    d->pkt->flags = keyframe ? AV_PKT_FLAG_KEY : 0;
    while ((err = avcodec_send_packet( d->ctx, d->pkt )) == AVERROR(EAGAIN))
        mav_lavc_receive( d, emit, ctx );
    d->pkt->data = NULL;
    d->pkt->size = 0;
    if (err >= 0) mav_lavc_receive( d, emit, ctx );
    return err < 0 ? -1 : 0;
}

/* End of the stream: the pictures the decoder still holds. */
static void mav_lavc_drain( void *handle, mav_vframe_emit emit, void *ctx )
{
    struct mav_lavc_vdec *d = handle;

    if (avcodec_send_packet( d->ctx, NULL ) >= 0) mav_lavc_receive( d, emit, ctx );
}

static int mav_lavc_map( void *frame, struct mav_vplanes *planes )
{
    struct mav_lavc_picture *pic = frame;

    planes->y = pic->data;
    planes->uv = pic->data + (size_t)pic->width * pic->height;
    planes->y_stride = pic->y_stride;
    planes->uv_stride = pic->uv_stride;
    planes->width = pic->width;
    planes->height = pic->height;
    planes->full_range = pic->full_range;
    return 0;
}

static void mav_lavc_unmap( void *frame )
{
    (void)frame;
}

static void mav_lavc_release( void *frame )
{
    struct mav_lavc_picture *pic = frame;

    if (!pic) return;
    free( pic->data );
    free( pic );
}

static void mav_lavc_flush( void *handle )
{
    avcodec_flush_buffers( ((struct mav_lavc_vdec *)handle)->ctx );
}

static const struct mav_video_backend mav_lavc_video =
{
    "libavcodec", mav_lavc_supports, mav_lavc_open, mav_lavc_decode, mav_lavc_map, mav_lavc_unmap,
    mav_lavc_release, mav_lavc_flush, mav_lavc_close,
};

struct mav_stream
{
    unsigned int number;        /* index among the exposed streams */
    int av_index;               /* AVStream index */
    enum mav_stream_type type;
    struct mav_stream_info info;
    AVRational time_base;
    int64_t origin;             /* stream time base: the timestamp that is 0 */

    /* ---- audio ---- */
    AVCodecContext *dec;        /* libavcodec decoder (MPEG audio, PCM) */
    void *adec;                 /* backend decoder (AAC) */
    AVFrame *frame;
    AVFrame *bframe;            /* the backend decoder's output, persistent */
    int64_t apts[8];            /* pts of packets the backend has not answered yet */
    unsigned int apts_count;
    SwrContext *swr;
    int swr_in_fmt, swr_in_rate;
    AVChannelLayout swr_in_layout;
    struct mav_output out;

    /* ---- video ---- */
    const struct mav_video_backend *vbackend;   /* the platform's, or mav_lavc_video */
    void *vdec;
    struct mav_video_output vout;
    struct mav_vframe *reorder; /* sorted by pts */
    unsigned int reorder_count, reorder_cap;
    int64_t last_dts;           /* stream time base, INT64_MIN = none yet */
    int64_t last_vpts;
    int64_t frame_duration;     /* 100 ns, from the frame rate */
    int bt709;

    /* ---- packets ---- */
    AVPacket *pkt;              /* the packet being decoded */
    int pkt_pending;
    AVPacket **queue;
    unsigned int queue_head, queue_count, queue_cap;
    size_t queue_bytes;
    pthread_t reader;           /* the thread that last asked for this stream's buffers */
    int has_reader;
    int unread;                 /* not read for MAV_BACKPRESSURE_WAIT_MS: queued without waiting */

    /* ---- the one outstanding output buffer ---- */
    uint8_t *buf;
    size_t buf_cap;
    struct mav_buffer cur;
    int has_buffer;

    int enabled, eos, draining, discontinuity;
    int64_t next_pts;           /* 100 ns */
    int64_t seek_target;        /* 100 ns, -1 = none */
    unsigned int decode_errors, errors_logged;
};

struct mav_parser
{
    /* ---- the read protocol (io_lock) ---- */
    pthread_mutex_t io_lock;
    pthread_cond_t read_cond;   /* a request was published / disconnect */
    pthread_cond_t done_cond;   /* the request was answered / disconnect */
    int connected;
    struct
    {
        uint8_t *dest;
        uint64_t offset;
        uint32_t size;          /* non-zero while a request is outstanding */
        int done;
        int result;             /* bytes, 0 = EOF, < 0 = read error */
    } req;

    /* ---- demux / decode state (lock) ---- */
    pthread_mutex_t lock;
    int output_compressed;
    uint64_t file_size;
    uint64_t pos;               /* next byte offset the AVIO callback reads */

    AVIOContext *avio;
    AVFormatContext *fmt;
    AVPacket *read_pkt;
    int is_mov;
    int is_asf;
    int ready;                  /* connected and streams exposed */
    int demux_eof;
    unsigned int read_errors_logged;
    int64_t stop;               /* 100 ns, -1 = none */

    struct mav_stream *streams[MAV_MAX_STREAMS];
    unsigned int stream_count;

    /* ---- back-pressure (lock) ---- */
    pthread_cond_t drain_cond;  /* a queue shrank, a stream changed state, or closing */
    unsigned int bp_waiters;    /* readers inside mav_wait_drain */
    unsigned int generation;    /* bumped by seek: a waiter re-checks everything */
    int closing;                /* disconnect: waiters leave, then the streams go */
};

/***********************************************************************
 *           the read protocol
 */
static int mav_avio_read( void *opaque, uint8_t *dest, int size )
{
    struct mav_parser *p = opaque;
    int result;

    if (size <= 0) return AVERROR(EINVAL);
    if (p->file_size && p->pos >= p->file_size) return AVERROR_EOF;
    if (size > MAV_MAX_REQUEST) size = MAV_MAX_REQUEST;

    pthread_mutex_lock( &p->io_lock );
    if (!p->connected)
    {
        pthread_mutex_unlock( &p->io_lock );
        return AVERROR_EXIT;
    }
    p->req.dest = dest;
    p->req.offset = p->pos;
    p->req.size = size;
    p->req.done = 0;
    p->req.result = 0;
    pthread_cond_broadcast( &p->read_cond );
    while (!p->req.done && p->connected)
        pthread_cond_wait( &p->done_cond, &p->io_lock );
    if (!p->req.done)
    {
        /* disconnected while waiting: nobody will answer */
        p->req.size = 0;
        p->req.dest = NULL;
        pthread_mutex_unlock( &p->io_lock );
        return AVERROR_EXIT;
    }
    result = p->req.result;
    p->req.dest = NULL;
    pthread_mutex_unlock( &p->io_lock );

    if (result > 0)
    {
        p->pos += result;
        return result;
    }
    return result ? AVERROR(EIO) : AVERROR_EOF;
}

static int64_t mav_avio_seek( void *opaque, int64_t offset, int whence )
{
    struct mav_parser *p = opaque;
    int64_t target;

    whence &= ~AVSEEK_FORCE;
    switch (whence)
    {
    case AVSEEK_SIZE:
        return p->file_size ? (int64_t)p->file_size : AVERROR(ENOSYS);
    case SEEK_SET:
        target = offset;
        break;
    case SEEK_CUR:
        target = (int64_t)p->pos + offset;
        break;
    case SEEK_END:
        if (!p->file_size) return AVERROR(ENOSYS);
        target = (int64_t)p->file_size + offset;
        break;
    default:
        return AVERROR(EINVAL);
    }
    if (target < 0) return AVERROR(EINVAL);
    p->pos = target;
    return target;
}

static int mav_get_next_read_offset( struct mav_parser *p, uint64_t *offset, uint32_t *size )
{
    pthread_mutex_lock( &p->io_lock );
    while (p->connected && !(p->req.size && !p->req.done))
        pthread_cond_wait( &p->read_cond, &p->io_lock );
    if (!p->connected)
    {
        pthread_mutex_unlock( &p->io_lock );
        return MAV_E_STATE;
    }
    *offset = p->req.offset;
    *size = p->req.size;
    pthread_mutex_unlock( &p->io_lock );
    return MAV_OK;
}

static int mav_push_data( struct mav_parser *p, const void *data, uint32_t size )
{
    pthread_mutex_lock( &p->io_lock );
    if (!p->req.size || p->req.done || !p->req.dest)
    {
        pthread_mutex_unlock( &p->io_lock );
        return MAV_E_STATE;
    }
    if (!data)
        p->req.result = -1;
    else if (!size)
        p->req.result = 0;
    else
    {
        uint32_t n = size < p->req.size ? size : p->req.size;
        memcpy( p->req.dest, data, n );
        p->req.result = (int)n;
    }
    p->req.done = 1;
    p->req.size = 0;
    pthread_cond_broadcast( &p->done_cond );
    pthread_mutex_unlock( &p->io_lock );
    return MAV_OK;
}

static void mav_set_connected( struct mav_parser *p, int connected )
{
    pthread_mutex_lock( &p->io_lock );
    p->connected = connected;
    p->req.size = 0;
    p->req.done = 0;
    p->req.dest = NULL;
    pthread_cond_broadcast( &p->read_cond );
    pthread_cond_broadcast( &p->done_cond );
    pthread_mutex_unlock( &p->io_lock );
}

/***********************************************************************
 *           lifetime
 */
static struct mav_parser *mav_create( int output_compressed )
{
    struct mav_parser *p = calloc( 1, sizeof(*p) );

    if (!p) return NULL;
    pthread_mutex_init( &p->io_lock, NULL );
    pthread_cond_init( &p->read_cond, NULL );
    pthread_cond_init( &p->done_cond, NULL );
    pthread_mutex_init( &p->lock, NULL );
    pthread_cond_init( &p->drain_cond, NULL );
    p->output_compressed = !!output_compressed;
    p->stop = -1;
    return p;
}

static void mav_queue_clear( struct mav_stream *s )
{
    while (s->queue_count)
    {
        av_packet_free( &s->queue[s->queue_head] );
        s->queue_head++;
        s->queue_count--;
    }
    s->queue_head = 0;
    s->queue_bytes = 0;
}

static void mav_reorder_clear( struct mav_stream *s )
{
    unsigned int i;

    for (i = 0; i < s->reorder_count; i++)
        if (s->vbackend) s->vbackend->release( s->reorder[i].handle );
    s->reorder_count = 0;
}

static void mav_stream_free( struct mav_stream *s )
{
    if (!s) return;
    mav_reorder_clear( s );
    free( s->reorder );
    if (s->vdec && s->vbackend) s->vbackend->close( s->vdec );
    if (s->adec && mav_abackend) mav_abackend->close( s->adec );
    mav_queue_clear( s );
    free( s->queue );
    swr_free( &s->swr );
    av_channel_layout_uninit( &s->swr_in_layout );
    avcodec_free_context( &s->dec );
    av_packet_free( &s->pkt );
    av_frame_free( &s->frame );
    av_frame_free( &s->bframe );
    free( s->buf );
    free( s );
}

static void mav_teardown( struct mav_parser *p )
{
    unsigned int i;

    for (i = 0; i < MAV_MAX_STREAMS; i++)
    {
        mav_stream_free( p->streams[i] );
        p->streams[i] = NULL;
    }
    p->stream_count = 0;
    av_packet_free( &p->read_pkt );
    avformat_close_input( &p->fmt );
    if (p->avio)
    {
        av_freep( &p->avio->buffer );
        avio_context_free( &p->avio );
    }
    p->ready = p->is_mov = p->is_asf = p->demux_eof = 0;
    p->read_errors_logged = 0;
    p->stop = -1;
}

static void mav_disconnect( struct mav_parser *p )
{
    /* Wake the PE read thread (it gets an error and exits once the filter
     * clears its own flag) and any demuxer read waiting for an answer, THEN
     * take the decode lock, which that read may be holding. */
    mav_set_connected( p, 0 );
    pthread_mutex_lock( &p->lock );
    /* A reader held by back-pressure sleeps without the lock: wake it, and
     * free nothing until it has left mav_wait_drain.  It finishes its request
     * under the lock, before this thread gets the lock back. */
    p->closing = 1;
    pthread_cond_broadcast( &p->drain_cond );
    while (p->bp_waiters) pthread_cond_wait( &p->drain_cond, &p->lock );
    mav_teardown( p );
    p->closing = 0;
    pthread_mutex_unlock( &p->lock );
}

static void mav_destroy( struct mav_parser *p )
{
    if (!p) return;
    mav_disconnect( p );
    pthread_cond_destroy( &p->drain_cond );
    pthread_mutex_destroy( &p->lock );
    pthread_cond_destroy( &p->done_cond );
    pthread_cond_destroy( &p->read_cond );
    pthread_mutex_destroy( &p->io_lock );
    free( p );
}

/***********************************************************************
 *           formats
 */
static enum AVSampleFormat mav_av_format( enum mav_sample_format fmt )
{
    switch (fmt)
    {
    case MAV_FMT_U8:  return AV_SAMPLE_FMT_U8;
    case MAV_FMT_S16: return AV_SAMPLE_FMT_S16;
    case MAV_FMT_S24: return AV_SAMPLE_FMT_S32;   /* packed to 3 bytes after conversion */
    case MAV_FMT_S32: return AV_SAMPLE_FMT_S32;
    case MAV_FMT_F32: return AV_SAMPLE_FMT_FLT;
    case MAV_FMT_F64: return AV_SAMPLE_FMT_DBL;
    default:          return AV_SAMPLE_FMT_NONE;
    }
}

static uint32_t mav_bytes_per_sample( enum mav_sample_format fmt )
{
    switch (fmt)
    {
    case MAV_FMT_U8:  return 1;
    case MAV_FMT_S16: return 2;
    case MAV_FMT_S24: return 3;
    case MAV_FMT_S32:
    case MAV_FMT_F32: return 4;
    case MAV_FMT_F64: return 8;
    default:          return 0;
    }
}

static const char *mav_format_name( enum mav_sample_format fmt )
{
    static const char *const names[] = { "unknown", "u8", "s16", "s24", "s32", "f32", "f64" };
    return (unsigned)fmt < sizeof(names) / sizeof(names[0]) ? names[fmt] : "?";
}

static const char *mav_pix_name( enum mav_pixel_format fmt )
{
    switch (fmt)
    {
    case MAV_PIX_BGRA: return "bgra";
    case MAV_PIX_BGRx: return "bgrx";
    case MAV_PIX_BGR:  return "bgr";
    case MAV_PIX_RGB15: return "rgb15";
    case MAV_PIX_RGB16: return "rgb16";
    case MAV_PIX_RGBA: return "rgba";
    case MAV_PIX_I420: return "i420";
    case MAV_PIX_NV12: return "nv12";
    case MAV_PIX_UYVY: return "uyvy";
    case MAV_PIX_YUY2: return "yuy2";
    case MAV_PIX_YV12: return "yv12";
    case MAV_PIX_YVYU: return "yvyu";
    default:           return "?";
    }
}

#define MAV_ALIGN4(x) (((x) + 3u) & ~3u)

/* GStreamer's layout of a raw video frame (what wg_format_get_stride() and
 * the PE side assume): plane offsets and strides.  Returns the frame size. */
struct mav_layout
{
    uint32_t stride[3];
    size_t offset[3];
    uint32_t chroma_height;
    size_t size;
};

static size_t mav_video_layout( enum mav_pixel_format fmt, uint32_t w, uint32_t h, struct mav_layout *l )
{
    memset( l, 0, sizeof(*l) );
    l->chroma_height = (h + 1) / 2;
    switch (fmt)
    {
    case MAV_PIX_NV12:
        l->stride[0] = l->stride[1] = MAV_ALIGN4( w );
        l->offset[1] = (size_t)l->stride[0] * h;
        l->size = l->offset[1] + (size_t)l->stride[1] * l->chroma_height;
        break;
    case MAV_PIX_I420:
    case MAV_PIX_YV12:
        l->stride[0] = MAV_ALIGN4( w );
        l->stride[1] = l->stride[2] = MAV_ALIGN4( (w + 1) / 2 );
        l->offset[1] = (size_t)l->stride[0] * h;
        l->offset[2] = l->offset[1] + (size_t)l->stride[1] * l->chroma_height;
        l->size = l->offset[2] + (size_t)l->stride[2] * l->chroma_height;
        break;
    case MAV_PIX_YUY2:
    case MAV_PIX_UYVY:
    case MAV_PIX_YVYU:
    case MAV_PIX_RGB15:
    case MAV_PIX_RGB16:
        l->stride[0] = MAV_ALIGN4( w * 2 );
        l->size = (size_t)l->stride[0] * h;
        break;
    case MAV_PIX_BGR:
        l->stride[0] = MAV_ALIGN4( w * 3 );
        l->size = (size_t)l->stride[0] * h;
        break;
    case MAV_PIX_BGRA:
    case MAV_PIX_BGRx:
    case MAV_PIX_RGBA:
        l->stride[0] = w * 4;
        l->size = (size_t)l->stride[0] * h;
        break;
    default:
        return 0;
    }
    return l->size;
}

/* The codecs this port accepts, and what they decode to natively.  PCM keeps
 * its own sample format (a WAVE parser must hand it on unchanged); MPEG audio
 * is reported as S16, which is what every DirectShow audio renderer takes. */
static int mav_classify_audio( enum AVCodecID id, enum mav_codec_kind *kind, uint32_t *layer,
                               enum mav_sample_format *native )
{
    *layer = 0;
    *kind = MAV_CODEC_PCM;
    switch (id)
    {
    case AV_CODEC_ID_PCM_U8:    *native = MAV_FMT_U8;  return 1;
    case AV_CODEC_ID_PCM_S16LE: *native = MAV_FMT_S16; return 1;
    case AV_CODEC_ID_PCM_S24LE: *native = MAV_FMT_S24; return 1;
    case AV_CODEC_ID_PCM_S32LE: *native = MAV_FMT_S32; return 1;
    case AV_CODEC_ID_PCM_F32LE: *native = MAV_FMT_F32; return 1;
    case AV_CODEC_ID_PCM_F64LE: *native = MAV_FMT_F64; return 1;
    case AV_CODEC_ID_MP1: *layer = 1; break;
    case AV_CODEC_ID_MP2: *layer = 2; break;
    case AV_CODEC_ID_MP3: *layer = 3; break;
    case AV_CODEC_ID_AAC:
        /* decoded by the platform backend, to float */
        *kind = MAV_CODEC_AAC;
        *native = MAV_FMT_F32;
        return 1;
    case AV_CODEC_ID_WMAV1:
    case AV_CODEC_ID_WMAV2:
    case AV_CODEC_ID_WMAPRO:
    case AV_CODEC_ID_WMALOSSLESS:
        /* libavcodec, reported as S16 like MPEG audio (the WM reader's default) */
        *kind = MAV_CODEC_WMA;
        *native = MAV_FMT_S16;
        return 1;
    default: return 0;
    }
    *kind = MAV_CODEC_MPEG_AUDIO;
    *native = MAV_FMT_S16;
    return 1;
}

static uint32_t mav_layout_mask( const AVChannelLayout *layout )
{
    if (layout->order == AV_CHANNEL_ORDER_NATIVE && av_popcount64( layout->u.mask ) == layout->nb_channels
        && !(layout->u.mask & ~(uint64_t)0x3ffff))
        return (uint32_t)layout->u.mask;
    {
        AVChannelLayout def;
        uint32_t mask = 0;
        av_channel_layout_default( &def, layout->nb_channels );
        if (def.order == AV_CHANNEL_ORDER_NATIVE) mask = (uint32_t)(def.u.mask & 0x3ffff);
        av_channel_layout_uninit( &def );
        return mask;
    }
}

static int64_t mav_to_100ns( const struct mav_stream *s, int64_t ts )
{
    return av_rescale_q( ts - s->origin, s->time_base, (AVRational){ 1, 10000000 } );
}

/***********************************************************************
 *           connect
 */
static int mav_refuse( struct mav_parser *p, int status, const char *why )
{
    mav_log( "connect refused (%s, compressed_out=%d): %s",
             p->fmt && p->fmt->iformat ? p->fmt->iformat->name : "no container",
             p->output_compressed, why );
    return status;
}

static int mav_refuse_codec( struct mav_parser *p, const char *what, const AVCodecParameters *par,
                             const char *why )
{
    char text[320];
    snprintf( text, sizeof(text), "%s codec %s (codec id %d, tag %#x): %s", what,
              avcodec_get_name( par->codec_id ), (int)par->codec_id, par->codec_tag, why );
    return mav_refuse( p, MAV_E_UNSUPPORTED, text );
}

static struct mav_stream *mav_stream_new( struct mav_parser *p, AVStream *st, enum mav_stream_type type )
{
    struct mav_stream *s = calloc( 1, sizeof(*s) );

    if (!s) return NULL;
    s->av_index = st->index;
    s->type = type;
    s->info.type = type;
    s->time_base = st->time_base;
    /* MP4 timestamps are already on the presentation timeline (edit lists
     * applied by the demuxer), and so are ASF's (its preroll taken off by the
     * demuxer), both on one clock for every stream; an MP3/WAV stream starts
     * at its own start. */
    s->origin = p->is_mov || p->is_asf ? 0 : (st->start_time != AV_NOPTS_VALUE ? st->start_time : 0);
    s->last_dts = s->last_vpts = INT64_MIN;
    s->seek_target = -1;
    if (!(s->pkt = av_packet_alloc()))
    {
        free( s );
        return NULL;
    }
    snprintf( s->info.container, sizeof(s->info.container), "%s", p->is_mov ? "mp4" : p->fmt->iformat->name );   /* asf: "asf" */
    if (p->fmt->duration != AV_NOPTS_VALUE && p->fmt->duration > 0 && !p->is_mov)
        s->info.duration = (uint64_t)p->fmt->duration * 10;   /* AV_TIME_BASE is 1 us */
    else if (st->duration != AV_NOPTS_VALUE && st->duration > 0)
        s->info.duration = av_rescale_q( st->duration, st->time_base, (AVRational){ 1, 10000000 } );
    else if (p->fmt->duration != AV_NOPTS_VALUE && p->fmt->duration > 0)
        s->info.duration = (uint64_t)p->fmt->duration * 10;
    return s;
}

/* Returns MAV_OK, or MAV_E_UNSUPPORTED with *why set, or MAV_E_NOMEM. */
static int mav_open_audio( struct mav_parser *p, struct mav_stream *s, AVStream *st, char *why, size_t why_size )
{
    const AVCodecParameters *par = st->codecpar;
    const AVCodec *codec;

    if (!mav_classify_audio( par->codec_id, &s->info.kind, &s->info.layer, &s->info.native.fmt ))
    {
        snprintf( why, why_size, "no decoder for it in this port" );
        return MAV_E_UNSUPPORTED;
    }
    if (p->output_compressed && s->info.kind != MAV_CODEC_PCM)
    {
        snprintf( why, why_size, "compressed output requested and no decoder filter exists; "
                  "the decoding splitter is tried next" );
        return MAV_E_UNSUPPORTED;
    }
    s->info.bitrate = par->bit_rate > 0 && par->bit_rate < UINT32_MAX ? (uint32_t)par->bit_rate : 0;
    snprintf( s->info.codec, sizeof(s->info.codec), "%s", avcodec_get_name( par->codec_id ) );

    if (s->info.kind == MAV_CODEC_AAC)
    {
        uint32_t rate = par->sample_rate, channels = par->ch_layout.nb_channels;

        if (!mav_video_allowed || !mav_abackend || !mav_abackend->supports( MAV_BACKEND_AAC ))
        {
            snprintf( why, why_size, "no AAC decoder backend" );
            return MAV_E_UNSUPPORTED;
        }
        if (!(s->adec = mav_abackend->open( MAV_BACKEND_AAC, par->extradata, par->extradata_size,
                                            &rate, &channels, why, why_size )))
            return MAV_E_UNSUPPORTED;
        if (!rate || rate > 384000 || !channels || channels > MAV_MAX_CHANNELS)
        {
            snprintf( why, why_size, "the decoder reports rate %u channels %u", rate, channels );
            return MAV_E_UNSUPPORTED;
        }
        if (!(s->bframe = av_frame_alloc())) return MAV_E_NOMEM;
        s->bframe->format = AV_SAMPLE_FMT_FLT;
        s->bframe->sample_rate = rate;
        s->bframe->nb_samples = MAV_AUDIO_BACKEND_MAX_FRAMES;
        av_channel_layout_default( &s->bframe->ch_layout, channels );
        if (av_frame_get_buffer( s->bframe, 0 ) < 0) return MAV_E_NOMEM;
        snprintf( s->info.backend, sizeof(s->info.backend), "%s", mav_abackend->name );
        s->info.native.rate = rate;
        s->info.native.channels = channels;
        s->info.native.channel_mask = mav_layout_mask( &s->bframe->ch_layout );
        if (par->extradata && par->extradata_size <= sizeof(s->info.codec_data))
        {
            memcpy( s->info.codec_data, par->extradata, par->extradata_size );
            s->info.codec_data_len = par->extradata_size;
        }
    }
    else
    {
        if (!(codec = avcodec_find_decoder( par->codec_id )))
        {
            snprintf( why, why_size, "no decoder in this build" );
            return MAV_E_UNSUPPORTED;
        }
        if (!(s->dec = avcodec_alloc_context3( codec ))) return MAV_E_NOMEM;
        s->dec->opaque = MAV_DECODER_MARKER;
        if (avcodec_parameters_to_context( s->dec, par ) < 0)
        {
            snprintf( why, why_size, "codec parameters rejected" );
            return MAV_E_UNSUPPORTED;
        }
        s->dec->pkt_timebase = st->time_base;
        if (avcodec_open2( s->dec, codec, NULL ) < 0)
        {
            snprintf( why, why_size, "decoder did not open" );
            return MAV_E_UNSUPPORTED;
        }
        if (s->dec->sample_rate <= 0 || s->dec->ch_layout.nb_channels <= 0
            || s->dec->ch_layout.nb_channels > MAV_MAX_CHANNELS)
        {
            snprintf( why, why_size, "no usable rate / channel count" );
            return MAV_E_UNSUPPORTED;
        }
        snprintf( s->info.codec, sizeof(s->info.codec), "%s", codec->name );
        snprintf( s->info.backend, sizeof(s->info.backend), "libavcodec" );
        if (s->info.kind == MAV_CODEC_WMA)
        {
            /* what wg_format describes a WMA stream by (the codec format) */
            s->info.version = par->codec_id == AV_CODEC_ID_WMAV1 ? 1 : par->codec_id == AV_CODEC_ID_WMAV2 ? 2
                              : par->codec_id == AV_CODEC_ID_WMAPRO ? 3 : 4;
            s->info.block_align = par->block_align > 0 ? (uint32_t)par->block_align : 0;
            s->info.depth = par->bits_per_coded_sample > 0 ? (uint32_t)par->bits_per_coded_sample : 16;
            if (par->extradata && par->extradata_size <= (int)sizeof(s->info.codec_data))
            {
                memcpy( s->info.codec_data, par->extradata, par->extradata_size );
                s->info.codec_data_len = par->extradata_size;
            }
        }
        s->info.native.rate = s->dec->sample_rate;
        s->info.native.channels = s->dec->ch_layout.nb_channels;
        s->info.native.channel_mask = mav_layout_mask( &s->dec->ch_layout );
    }
    if (!(s->frame = av_frame_alloc())) return MAV_E_NOMEM;
    s->out = s->info.native;
    return MAV_OK;
}

static int mav_open_video( struct mav_parser *p, struct mav_stream *s, AVStream *st, char *why, size_t why_size )
{
    const AVCodecParameters *par = st->codecpar;
    AVRational fps = st->avg_frame_rate;
    int codec;

    /* H.264 / HEVC from an MP4 go to the platform decoder (avcC / hvcC codec
     * data); Windows Media video from an ASF to libavcodec. */
    s->vbackend = mav_vbackend;
    switch (par->codec_id)
    {
    case AV_CODEC_ID_H264: codec = MAV_BACKEND_H264; s->info.kind = MAV_CODEC_H264; break;
    case AV_CODEC_ID_HEVC: codec = MAV_BACKEND_HEVC; s->info.kind = MAV_CODEC_HEVC; break;
    case AV_CODEC_ID_WMV1: codec = MAV_LAVC_WMV1; s->info.wmv = MAV_WMV_WMV1; break;
    case AV_CODEC_ID_WMV2: codec = MAV_LAVC_WMV2; s->info.wmv = MAV_WMV_WMV2; break;
    case AV_CODEC_ID_WMV3: codec = MAV_LAVC_WMV3; s->info.wmv = MAV_WMV_WMV3; break;
    case AV_CODEC_ID_VC1:
        codec = MAV_LAVC_VC1;
        s->info.wmv = par->codec_tag == MKTAG('W','M','V','A') ? MAV_WMV_WMVA : MAV_WMV_WVC1;
        break;
    case AV_CODEC_ID_MSMPEG4V1: codec = MAV_LAVC_MSMPEG4V1; break;
    case AV_CODEC_ID_MSMPEG4V2: codec = MAV_LAVC_MSMPEG4V2; break;
    case AV_CODEC_ID_MSMPEG4V3: codec = MAV_LAVC_MSMPEG4V3; break;
    default:
        snprintf( why, why_size, "no decoder for it in this port" );
        return MAV_E_UNSUPPORTED;
    }
    if (codec >= MAV_LAVC_WMV1)
    {
        s->info.kind = MAV_CODEC_WMV;
        s->vbackend = &mav_lavc_video;
    }
    snprintf( s->info.codec, sizeof(s->info.codec), "%s", avcodec_get_name( par->codec_id ) );
    if (p->is_asf != (s->info.kind == MAV_CODEC_WMV))
    {
        snprintf( why, why_size, "not in this container here (H.264 / HEVC in MP4, Windows Media video in ASF)" );
        return MAV_E_UNSUPPORTED;
    }
    if (!s->vbackend || !s->vbackend->supports( codec ))
    {
        snprintf( why, why_size, "no video decoder backend for it" );
        return MAV_E_UNSUPPORTED;
    }
    if (par->width <= 0 || par->height <= 0 || par->width > MAV_MAX_DIMENSION || par->height > MAV_MAX_DIMENSION)
    {
        snprintf( why, why_size, "unusable picture size %dx%d", par->width, par->height );
        return MAV_E_UNSUPPORTED;
    }
    if (!(s->vdec = s->vbackend->open( codec, par->extradata, par->extradata_size, par->width, par->height,
                                       why, why_size )))
        return MAV_E_UNSUPPORTED;
    snprintf( s->info.backend, sizeof(s->info.backend), "%s", s->vbackend->name );

    if (fps.num <= 0 || fps.den <= 0) fps = st->r_frame_rate;
    if (fps.num <= 0 || fps.den <= 0 || av_q2d( fps ) > 1000)
    {
        mav_log( "stream %u: no frame rate in the container; assuming 30/1", s->number );
        fps = (AVRational){ 30, 1 };
    }
    s->info.vnative.fmt = mav_native_pix;
    s->info.vnative.width = par->width;
    s->info.vnative.height = par->height;
    s->info.vnative.fps_n = fps.num;
    s->info.vnative.fps_d = fps.den;
    s->frame_duration = av_rescale( 10000000, fps.den, fps.num );
    s->info.bitrate = par->bit_rate > 0 && par->bit_rate < UINT32_MAX ? (uint32_t)par->bit_rate : 0;
    s->info.profile = par->profile > 0 ? par->profile : 0;
    s->info.level = par->level > 0 ? par->level : 0;
    if (par->extradata && par->extradata_size <= sizeof(s->info.codec_data))
    {
        memcpy( s->info.codec_data, par->extradata, par->extradata_size );
        s->info.codec_data_len = par->extradata_size;
    }
    switch (par->color_space)
    {
    case AVCOL_SPC_BT709: s->bt709 = 1; break;
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M:
    case AVCOL_SPC_FCC: s->bt709 = 0; break;
    default: s->bt709 = par->height >= 720; break;   /* the usual assumption for untagged video */
    }
    s->vout = s->info.vnative;
    return MAV_OK;
}

static int mav_connect_locked( struct mav_parser *p )
{
    AVStream *vst = NULL, *ast = NULL;
    const char *name;
    uint8_t *avio_buf;
    char why[160];
    unsigned int i;
    int err, status, is_mp3;

    if (!(avio_buf = av_malloc( MAV_AVIO_BUFFER ))) return MAV_E_NOMEM;
    if (!(p->avio = avio_alloc_context( avio_buf, MAV_AVIO_BUFFER, 0, p, mav_avio_read, NULL, mav_avio_seek )))
    {
        av_free( avio_buf );
        return MAV_E_NOMEM;
    }
    if (!(p->fmt = avformat_alloc_context())) return MAV_E_NOMEM;
    p->fmt->pb = p->avio;
    p->fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    p->fmt->probesize = MAV_PROBESIZE;

    if ((err = avformat_open_input( &p->fmt, NULL, NULL, NULL )) < 0)
    {
        /* avformat_open_input freed the context (not our AVIO) */
        p->fmt = NULL;
        return mav_refuse( p, err == AVERROR_EXIT || err == AVERROR(EIO) ? MAV_E_IO : MAV_E_UNSUPPORTED,
                           "no enabled demuxer recognised the stream" );
    }
    name = p->fmt->iformat->name;
    is_mp3 = !strcmp( name, "mp3" );
    p->is_mov = !strcmp( name, MAV_MOV_NAME );
    p->is_asf = !strcmp( name, "asf" );
    if (!is_mp3 && strcmp( name, "wav" ) && !((p->is_mov || p->is_asf) && mav_video_allowed))
        return mav_refuse( p, MAV_E_UNSUPPORTED, p->is_mov || p->is_asf ? "container disabled by MADEIRA_WG_VIDEO=0"
                                                                         : "container not in the allowlist" );
    /* An ASF header object scores like a recognised MP4 (its GUID matches). */
    if (p->fmt->probe_score < (p->is_mov || p->is_asf ? MAV_MIN_MOV_PROBE_SCORE : MAV_MIN_PROBE_SCORE))
    {
        snprintf( why, sizeof(why), "probe score %d below %d", p->fmt->probe_score,
                  p->is_mov || p->is_asf ? MAV_MIN_MOV_PROBE_SCORE : MAV_MIN_PROBE_SCORE );
        return mav_refuse( p, MAV_E_UNSUPPORTED, why );
    }
    /* The mp3 demuxer only ever carries MPEG audio and an MP4 or ASF only
     * compressed streams: a compressed-output parser is refused before the
     * stream analysis reads anything more. */
    if (p->output_compressed && (is_mp3 || p->is_mov || p->is_asf))
        return mav_refuse( p, MAV_E_UNSUPPORTED,
                           "compressed output requested and no decoder filter exists; "
                           "the decoding splitter is tried next" );

    /* Only the stream types this port can expose are analysed; a cover-art
     * picture is not decodable here and would only keep the analysis reading. */
    for (i = 0; i < p->fmt->nb_streams; i++)
    {
        enum AVMediaType type = p->fmt->streams[i]->codecpar->codec_type;
        if (type != AVMEDIA_TYPE_AUDIO && !((p->is_mov || p->is_asf) && type == AVMEDIA_TYPE_VIDEO))
            p->fmt->streams[i]->discard = AVDISCARD_ALL;
    }

    if ((err = avformat_find_stream_info( p->fmt, NULL )) < 0)
        return mav_refuse( p, err == AVERROR_EXIT || err == AVERROR(EIO) ? MAV_E_IO : MAV_E_UNSUPPORTED,
                           "stream analysis failed" );

    for (i = 0; i < p->fmt->nb_streams; i++)
    {
        AVStream *s = p->fmt->streams[i];

        if (s->disposition & AV_DISPOSITION_ATTACHED_PIC) continue;
        if (s->codecpar->codec_type == AVMEDIA_TYPE_VIDEO)
        {
            if (!p->is_mov && !p->is_asf) return mav_refuse( p, MAV_E_UNSUPPORTED, "the file has a video stream" );
            if (!vst) vst = s;
        }
        if (s->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && !ast) ast = s;
    }
    if (!vst && !ast) return mav_refuse( p, MAV_E_UNSUPPORTED, p->is_mov || p->is_asf ? "no audio or video stream"
                                                                                     : "no audio stream" );

    if (!(p->read_pkt = av_packet_alloc())) return MAV_E_NOMEM;

    /* Container order, so stream numbers follow the file's track order. */
    for (i = 0; i < p->fmt->nb_streams; i++)
    {
        AVStream *st = p->fmt->streams[i];
        struct mav_stream *s;

        if (st != vst && st != ast) continue;
        if (!(s = mav_stream_new( p, st, st == vst ? MAV_STREAM_VIDEO : MAV_STREAM_AUDIO ))) return MAV_E_NOMEM;
        s->number = p->stream_count;
        why[0] = 0;
        status = st == vst ? mav_open_video( p, s, st, why, sizeof(why) )
                           : mav_open_audio( p, s, st, why, sizeof(why) );
        if (status == MAV_E_NOMEM)
        {
            mav_stream_free( s );
            return status;
        }
        if (status)
        {
            /* An MP4's or ASF's audio is optional; its video, or the only stream, is not. */
            if (st == ast && vst)
            {
                char text[320];
                snprintf( text, sizeof(text), "audio codec %s (codec id %d, tag %#x) not exposed: %s",
                          avcodec_get_name( st->codecpar->codec_id ), (int)st->codecpar->codec_id,
                          st->codecpar->codec_tag, why );
                mav_log( "%s", text );
                mav_stream_free( s );
                continue;
            }
            status = mav_refuse_codec( p, st == vst ? "video" : "audio", st->codecpar, why );
            mav_stream_free( s );
            return status;
        }
        p->streams[p->stream_count++] = s;
    }
    if (!p->stream_count) return mav_refuse( p, MAV_E_UNSUPPORTED, "no decodable stream" );

    for (i = 0; i < p->fmt->nb_streams; i++)
    {
        unsigned int j;
        p->fmt->streams[i]->discard = AVDISCARD_ALL;
        for (j = 0; j < p->stream_count; j++)
            if (p->streams[j]->av_index == (int)i) p->fmt->streams[i]->discard = AVDISCARD_DEFAULT;
    }

    for (i = 0; i < p->stream_count; i++)
    {
        struct mav_stream *s = p->streams[i];

        s->enabled = 1;
        s->discontinuity = 1;
        s->next_pts = 0;
        /* MP4 audio carries its encoder delay as packets before time 0
         * (the edit list); they are decoded and trimmed like a seek to 0. */
        s->seek_target = p->is_mov ? 0 : -1;
        if (s->type == MAV_STREAM_VIDEO)
            mav_log( "connect container=%s stream=%u video codec=%s backend=%s %dx%d fps=%u/%u out=%s "
                     "duration=%llums bitrate=%u profile=%u level=%u",
                     s->info.container, i, s->info.codec, s->info.backend, s->info.vnative.width,
                     s->info.vnative.height, s->info.vnative.fps_n, s->info.vnative.fps_d,
                     mav_pix_name( s->vout.fmt ), (unsigned long long)(s->info.duration / 10000),
                     s->info.bitrate, s->info.profile, s->info.level );
        else
            mav_log( "connect container=%s codec=%s layer=%u rate=%u channels=%u mask=%#x out=%s "
                     "duration=%llums bitrate=%u compressed_out=%d stream=%u backend=%s",
                     s->info.container, s->info.codec, s->info.layer, s->info.native.rate,
                     s->info.native.channels, s->info.native.channel_mask,
                     mav_format_name( s->out.fmt ), (unsigned long long)(s->info.duration / 10000),
                     s->info.bitrate, p->output_compressed, i, s->info.backend );
    }
    p->stop = -1;
    p->demux_eof = 0;
    p->ready = 1;
    return MAV_OK;
}

static int mav_connect( struct mav_parser *p, uint64_t file_size )
{
    int status;

    pthread_mutex_lock( &p->lock );
    if (p->fmt || p->avio)
    {
        pthread_mutex_unlock( &p->lock );
        return MAV_E_STATE;
    }
    p->file_size = file_size;
    p->pos = 0;
    mav_set_connected( p, 1 );
    if ((status = mav_connect_locked( p )))
    {
        mav_teardown( p );
        /* like wg_parser.c: a failed connect ends the read protocol */
        mav_set_connected( p, 0 );
    }
    pthread_mutex_unlock( &p->lock );
    return status;
}

/***********************************************************************
 *           stream queries and format
 */
static struct mav_stream *mav_get_stream( struct mav_parser *p, unsigned int stream )
{
    return p->ready && stream < p->stream_count ? p->streams[stream] : NULL;
}

static unsigned int mav_stream_count( struct mav_parser *p )
{
    unsigned int count;

    pthread_mutex_lock( &p->lock );
    count = p->ready ? p->stream_count : 0;
    pthread_mutex_unlock( &p->lock );
    return count;
}

static int mav_stream_info( struct mav_parser *p, unsigned int stream, struct mav_stream_info *info )
{
    struct mav_stream *s;
    int status = MAV_E_STATE;

    pthread_mutex_lock( &p->lock );
    if ((s = mav_get_stream( p, stream )))
    {
        *info = s->info;
        status = MAV_OK;
    }
    pthread_mutex_unlock( &p->lock );
    return status;
}

static int mav_current_output( struct mav_parser *p, unsigned int stream, struct mav_output *out )
{
    struct mav_stream *s;
    int status = MAV_E_STATE;

    pthread_mutex_lock( &p->lock );
    if ((s = mav_get_stream( p, stream )) && s->type == MAV_STREAM_AUDIO)
    {
        *out = s->out;
        status = MAV_OK;
    }
    pthread_mutex_unlock( &p->lock );
    return status;
}

static int mav_current_video( struct mav_parser *p, unsigned int stream, struct mav_video_output *out )
{
    struct mav_stream *s;
    int status = MAV_E_STATE;

    pthread_mutex_lock( &p->lock );
    if ((s = mav_get_stream( p, stream )) && s->type == MAV_STREAM_VIDEO)
    {
        *out = s->vout;
        status = MAV_OK;
    }
    pthread_mutex_unlock( &p->lock );
    return status;
}

static int mav_enable( struct mav_parser *p, unsigned int stream, const struct mav_output *out )
{
    struct mav_stream *s;
    int status = MAV_OK;

    pthread_mutex_lock( &p->lock );
    if (!(s = mav_get_stream( p, stream )) || s->type != MAV_STREAM_AUDIO)
        status = MAV_E_STATE;
    else if (mav_av_format( out->fmt ) == AV_SAMPLE_FMT_NONE || !out->rate || out->rate > 768000
             || !out->channels || out->channels > MAV_MAX_CHANNELS)
    {
        /* Refused, and the stream stays disabled: its buffers would be in a
         * format nobody asked for. */
        s->enabled = 0;
        s->has_buffer = 0;
        status = MAV_E_PARAM;
    }
    else
    {
        if (memcmp( out, &s->out, sizeof(*out) ))
        {
            /* the held buffer is in the old format */
            s->has_buffer = 0;
            swr_free( &s->swr );
            s->out = *out;
        }
        s->enabled = 1;
    }
    pthread_mutex_unlock( &p->lock );
    return status;
}

static int mav_enable_video( struct mav_parser *p, unsigned int stream, const struct mav_video_output *out )
{
    struct mav_layout layout;
    struct mav_stream *s;
    int status = MAV_OK;

    pthread_mutex_lock( &p->lock );
    if (!(s = mav_get_stream( p, stream )) || s->type != MAV_STREAM_VIDEO)
        status = MAV_E_STATE;
    else if (!mav_video_layout( out->fmt, s->info.vnative.width, s->info.vnative.height, &layout )
             || out->width != s->info.vnative.width
             || (out->height != s->info.vnative.height && out->height != -s->info.vnative.height))
    {
        /* No scaler here: only the native size, in one of the layouts
         * mav_video_layout knows.  The stream stays disabled. */
        s->enabled = 0;
        s->has_buffer = 0;
        status = MAV_E_PARAM;
    }
    else
    {
        if (out->fmt != s->vout.fmt || out->height != s->vout.height) s->has_buffer = 0;
        s->vout = *out;
        s->enabled = 1;
    }
    pthread_mutex_unlock( &p->lock );
    return status;
}

static void mav_disable( struct mav_parser *p, unsigned int stream )
{
    struct mav_stream *s;

    pthread_mutex_lock( &p->lock );
    if ((s = mav_get_stream( p, stream )))
    {
        s->enabled = 0;
        s->has_buffer = 0;
        /* its queued packets will not be read */
        mav_queue_clear( s );
        if (p->bp_waiters) pthread_cond_broadcast( &p->drain_cond );
    }
    pthread_mutex_unlock( &p->lock );
}

/***********************************************************************
 *           packets
 */
static void mav_queue_push( struct mav_stream *s, AVPacket *pkt )
{
    if (s->queue_count >= MAV_QUEUE_MAX_PACKETS || s->queue_bytes + pkt->size > MAV_QUEUE_MAX_BYTES)
    {
        mav_log( "stream %u: %u packets (%zu bytes) queued and not read; dropping further packets",
                 s->number, s->queue_count, s->queue_bytes );
        s->discontinuity = 1;
        av_packet_free( &pkt );
        return;
    }
    if (s->queue_head + s->queue_count == s->queue_cap)
    {
        if (s->queue_head)
        {
            memmove( s->queue, s->queue + s->queue_head, s->queue_count * sizeof(*s->queue) );
            s->queue_head = 0;
        }
        if (s->queue_count == s->queue_cap)
        {
            unsigned int cap = s->queue_cap ? s->queue_cap * 2 : 64;
            AVPacket **grown = realloc( s->queue, cap * sizeof(*grown) );
            if (!grown)
            {
                av_packet_free( &pkt );
                s->discontinuity = 1;
                return;
            }
            s->queue = grown;
            s->queue_cap = cap;
        }
    }
    s->queue[s->queue_head + s->queue_count++] = pkt;
    s->queue_bytes += pkt->size;
}

static int mav_queue_over( const struct mav_stream *s, unsigned int num, unsigned int den )
{
    return s->queue_count > MAV_QUEUE_SOFT_PACKETS / den * num || s->queue_bytes > MAV_QUEUE_SOFT_BYTES / den * num;
}

/* Back-pressure.  `waiter` just queued a packet for
 * `owner`, whose queue is past its soft limit while another thread reads it.
 * Dropping would break the owner's pictures (or audio) up to its next
 * keyframe, so the waiter sleeps -- WITHOUT the parser lock, which the owner's
 * reader needs to drain its queue -- until that queue is back under three
 * quarters of the limit.  The waiter holds no packet and no demuxer state
 * while it sleeps; it re-checks its own queue when it wakes.  It also wakes on
 * a seek (generation), a disable or end of the owner's stream, and disconnect
 * (closing).  An owner not read for MAV_BACKPRESSURE_WAIT_MS is marked unread:
 * its packets are queued again without waiting (and dropped past the hard
 * limit, as before) until it is read. */
static void mav_wait_drain( struct mav_parser *p, struct mav_stream *waiter, struct mav_stream *owner )
{
    unsigned int generation = p->generation;
    struct timespec deadline;

    clock_gettime( CLOCK_REALTIME, &deadline );
    deadline.tv_sec += MAV_BACKPRESSURE_WAIT_MS / 1000;
    deadline.tv_nsec += (long)(MAV_BACKPRESSURE_WAIT_MS % 1000) * 1000000;
    if (deadline.tv_nsec >= 1000000000) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000; }
    p->bp_waiters++;
    while (!p->closing && p->generation == generation && owner->enabled && !owner->eos && !owner->unread
           && mav_queue_over( owner, 3, 4 ))
    {
        if (pthread_cond_timedwait( &p->drain_cond, &p->lock, &deadline ) == ETIMEDOUT)
        {
            if (!p->closing && p->generation == generation && owner->enabled && !owner->eos
                && mav_queue_over( owner, 3, 4 ))
            {
                owner->unread = 1;
                mav_log( "stream %u: not read for %d ms while stream %u reads ahead (%u packets, %zu bytes "
                         "queued); queueing without waiting", owner->number, MAV_BACKPRESSURE_WAIT_MS,
                         waiter->number, owner->queue_count, owner->queue_bytes );
            }
            break;
        }
    }
    p->bp_waiters--;
    if (p->closing) pthread_cond_broadcast( &p->drain_cond );   /* mav_disconnect waits for bp_waiters == 0 */
}

/* Moves the next packet of stream `s` into `dst`, reading (and queueing for
 * the other streams) as needed.  Returns 0 at the end of the data. */
static int mav_next_packet( struct mav_parser *p, struct mav_stream *s, AVPacket *dst )
{
    unsigned int i;
    int err;

    for (;;)
    {
        struct mav_stream *owner = NULL;
        AVPacket *copy;

        if (s->queue_count)
        {
            AVPacket *q = s->queue[s->queue_head++];
            s->queue_count--;
            s->queue_bytes -= q->size;
            if (!s->queue_count) s->queue_head = 0;
            s->unread = 0;
            av_packet_move_ref( dst, q );
            av_packet_free( &q );
            if (p->bp_waiters) pthread_cond_broadcast( &p->drain_cond );
            return 1;
        }
        if (p->demux_eof || p->closing) return 0;
        if ((err = av_read_frame( p->fmt, p->read_pkt )) < 0)
        {
            if (err != AVERROR_EOF && err != AVERROR_EXIT && p->read_errors_logged < 3)
            {
                p->read_errors_logged++;
                mav_log( "read error %d at byte %llu; draining", err, (unsigned long long)p->pos );
            }
            p->demux_eof = 1;
            return 0;
        }
        for (i = 0; i < p->stream_count; i++)
            if (p->streams[i]->av_index == p->read_pkt->stream_index) owner = p->streams[i];
        if (owner == s)
        {
            s->unread = 0;
            av_packet_move_ref( dst, p->read_pkt );
            return 1;
        }
        if (!owner || !owner->enabled || owner->eos)
        {
            av_packet_unref( p->read_pkt );
            continue;
        }
        if (!(copy = av_packet_alloc()))
        {
            av_packet_unref( p->read_pkt );
            owner->discontinuity = 1;
            continue;
        }
        av_packet_move_ref( copy, p->read_pkt );
        mav_queue_push( owner, copy );
        /* Only for an owner another thread reads: one thread serving both
         * streams (the earliest-buffer mode, or a caller that alternates)
         * would wait for itself. */
        if (mav_queue_over( owner, 1, 1 ) && !owner->unread
            && !(owner->has_reader && pthread_equal( owner->reader, pthread_self() )))
            mav_wait_drain( p, s, owner );
    }
}

/***********************************************************************
 *           audio
 */
static int mav_reserve( struct mav_stream *s, size_t need )
{
    size_t want;
    uint8_t *grown;

    if (s->buf_cap >= need) return 1;
    want = s->buf_cap ? s->buf_cap : 16384;
    while (want < need) want *= 2;
    if (!(grown = realloc( s->buf, want ))) return 0;
    s->buf = grown;
    s->buf_cap = want;
    return 1;
}

static int mav_setup_swr( struct mav_stream *s, const AVFrame *frame )
{
    AVChannelLayout out_layout;
    int err;

    if (s->swr && s->swr_in_fmt == frame->format && s->swr_in_rate == frame->sample_rate
        && !av_channel_layout_compare( &s->swr_in_layout, &frame->ch_layout ))
        return 0;

    swr_free( &s->swr );
    av_channel_layout_uninit( &s->swr_in_layout );
    if (!s->out.channel_mask || av_popcount( s->out.channel_mask ) != (int)s->out.channels
        || av_channel_layout_from_mask( &out_layout, s->out.channel_mask ) < 0)
        av_channel_layout_default( &out_layout, s->out.channels );
    err = swr_alloc_set_opts2( &s->swr, &out_layout, mav_av_format( s->out.fmt ), s->out.rate,
                               &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL );
    av_channel_layout_uninit( &out_layout );
    if (err < 0 || (err = swr_init( s->swr )) < 0)
    {
        swr_free( &s->swr );
        return err < 0 ? err : AVERROR(EINVAL);
    }
    s->swr_in_fmt = frame->format;
    s->swr_in_rate = frame->sample_rate;
    av_channel_layout_copy( &s->swr_in_layout, &frame->ch_layout );
    return 0;
}

/* Converts `frame` (or, with NULL, the converter's tail) into s->buf, and
 * returns the number of output frames it produced, < 0 on error. */
static int mav_convert( struct mav_stream *s, const AVFrame *frame )
{
    uint32_t bps = mav_bytes_per_sample( s->out.fmt );
    uint32_t conv_bps = bps == 3 ? 4 : bps;
    int want, got;
    uint8_t *outp;

    if (frame && mav_setup_swr( s, frame ) < 0) return -1;
    if (!s->swr) return 0;
    want = swr_get_out_samples( s->swr, frame ? frame->nb_samples : 0 );
    if (want <= 0) return 0;
    if (!mav_reserve( s, (size_t)want * s->out.channels * conv_bps )) return -1;
    outp = s->buf;
    got = swr_convert( s->swr, &outp, want,
                       frame ? (const uint8_t **)frame->extended_data : NULL,
                       frame ? frame->nb_samples : 0 );
    if (got <= 0) return got;
    if (bps == 3)
    {
        /* S24: the top three bytes of each little-endian S32 sample, in place
         * (the write index never overtakes the read index) */
        size_t n = (size_t)got * s->out.channels, i;
        for (i = 0; i < n; i++)
        {
            s->buf[i * 3 + 0] = s->buf[i * 4 + 1];
            s->buf[i * 3 + 1] = s->buf[i * 4 + 2];
            s->buf[i * 3 + 2] = s->buf[i * 4 + 3];
        }
    }
    return got;
}

/* Sets s->cur for `frames` converted frames starting at `pts`, applying the
 * seek target and the stop position.  Returns 1 if a buffer is left. */
static int mav_finish_buffer( struct mav_parser *p, struct mav_stream *s, int64_t pts, int frames )
{
    uint32_t frame_bytes = mav_bytes_per_sample( s->out.fmt ) * s->out.channels;
    int64_t dur = av_rescale( frames, 10000000, s->out.rate );
    int64_t skip = 0, keep = frames;

    s->next_pts = pts + dur;
    if (s->seek_target >= 0)
    {
        if (pts + dur <= s->seek_target) return 0;
        if (pts < s->seek_target)
        {
            skip = av_rescale( s->seek_target - pts, s->out.rate, 10000000 );
            if (skip > frames) skip = frames;
            pts = s->seek_target;
        }
        s->seek_target = -1;
    }
    keep = frames - skip;
    if (p->stop >= 0)
    {
        if (pts >= p->stop)
        {
            s->eos = 1;
            return 0;
        }
        if (pts + av_rescale( keep, 10000000, s->out.rate ) > p->stop)
        {
            int64_t cut = av_rescale( p->stop - pts, s->out.rate, 10000000 );
            if (cut < keep) keep = cut;
            s->eos = 1;   /* nothing after this buffer is wanted */
        }
    }
    if (keep <= 0) return 0;
    if (skip) memmove( s->buf, s->buf + skip * frame_bytes, keep * frame_bytes );

    s->cur.pts = pts > 0 ? (uint64_t)pts : 0;
    s->cur.duration = av_rescale( keep, 10000000, s->out.rate );
    s->cur.size = (uint32_t)(keep * frame_bytes);
    s->cur.stream = s->number;
    s->cur.discontinuity = s->discontinuity;
    s->cur.delta = 0;
    s->discontinuity = 0;
    s->has_buffer = 1;
    return 1;
}

static int64_t mav_frame_pts( struct mav_stream *s, const AVFrame *frame )
{
    int64_t ts = frame->best_effort_timestamp;

    if (ts == AV_NOPTS_VALUE) return s->next_pts;
    return mav_to_100ns( s, ts );
}

static int mav_give_up( struct mav_stream *s )
{
    mav_log( "%s: %u consecutive undecodable packets; ending the stream", s->info.codec, s->decode_errors );
    s->eos = 1;
    return MAV_NO_BUFFER;
}

/* The platform backend: one packet in, float frames out. */
static int mav_audio_next_backend( struct mav_parser *p, struct mav_stream *s )
{
    for (;;)
    {
        int64_t pts;
        int n, got;

        if (s->eos) return MAV_NO_BUFFER;
        if (!mav_next_packet( p, s, s->pkt ))
        {
            /* the converter's tail (only non-empty when resampling) */
            got = mav_convert( s, NULL );
            s->eos = 1;
            if (got > 0 && mav_finish_buffer( p, s, s->next_pts, got ))
            {
                s->eos = 1;
                return MAV_OK;
            }
            return MAV_NO_BUFFER;
        }
        /* The decoder may answer a packet late; timestamps follow the
         * packets in order, not the calls. */
        pts = s->pkt->pts != AV_NOPTS_VALUE ? mav_to_100ns( s, s->pkt->pts ) : INT64_MIN;
        if (s->apts_count == sizeof(s->apts) / sizeof(s->apts[0]))
        {
            memmove( s->apts, s->apts + 1, (s->apts_count - 1) * sizeof(s->apts[0]) );
            s->apts_count--;
        }
        s->apts[s->apts_count++] = pts;
        n = mav_abackend->decode( s->adec, s->pkt->data, s->pkt->size, (float *)s->bframe->data[0],
                                  MAV_AUDIO_BACKEND_MAX_FRAMES );
        av_packet_unref( s->pkt );
        if (n < 0)
        {
            if (s->errors_logged < 3)
            {
                s->errors_logged++;
                mav_log( "%s: packet rejected by %s (%d), skipped", s->info.codec, s->info.backend, n );
            }
            s->apts_count--;
            if (++s->decode_errors > MAV_MAX_DECODE_ERRORS) return mav_give_up( s );
            continue;
        }
        s->decode_errors = 0;
        if (!n) continue;
        pts = s->apts[0];
        memmove( s->apts, s->apts + 1, (s->apts_count - 1) * sizeof(s->apts[0]) );
        s->apts_count--;
        if (pts == INT64_MIN) pts = s->next_pts;
        s->bframe->nb_samples = n > MAV_AUDIO_BACKEND_MAX_FRAMES ? MAV_AUDIO_BACKEND_MAX_FRAMES : n;
        if ((got = mav_convert( s, s->bframe )) < 0)
        {
            mav_log( "sample conversion failed; ending the stream" );
            s->eos = 1;
            return MAV_NO_BUFFER;
        }
        if (got && mav_finish_buffer( p, s, pts, got )) return MAV_OK;
    }
}

/* Produces the next buffer.  Returns MAV_OK with s->has_buffer set, or
 * MAV_NO_BUFFER at end of stream. */
static int mav_audio_next( struct mav_parser *p, struct mav_stream *s )
{
    int err;

    if (s->adec) return mav_audio_next_backend( p, s );
    for (;;)
    {
        if (s->eos) return MAV_NO_BUFFER;

        err = avcodec_receive_frame( s->dec, s->frame );
        if (!err)
        {
            int64_t pts = mav_frame_pts( s, s->frame );
            int got = mav_convert( s, s->frame );

            av_frame_unref( s->frame );
            if (got < 0)
            {
                mav_log( "sample conversion failed; ending the stream" );
                s->eos = 1;
                return MAV_NO_BUFFER;
            }
            s->decode_errors = 0;
            if (got && mav_finish_buffer( p, s, pts, got )) return MAV_OK;
            continue;
        }
        if (err == AVERROR_EOF)
        {
            /* the converter's tail (only non-empty when resampling) */
            int got = mav_convert( s, NULL );
            int64_t pts = s->next_pts;

            s->eos = 1;
            if (got > 0 && mav_finish_buffer( p, s, pts, got ))
            {
                s->eos = 1;
                return MAV_OK;
            }
            return MAV_NO_BUFFER;
        }
        if (err != AVERROR(EAGAIN))
        {
            /* A decoding error on output; the next packet may be fine. */
            if (++s->decode_errors > MAV_MAX_DECODE_ERRORS) return mav_give_up( s );
        }

        if (s->draining)
        {
            /* receive_frame must reach EOF once drained; guard anyway */
            if (err == AVERROR(EAGAIN)) { s->eos = 1; return MAV_NO_BUFFER; }
            continue;
        }

        if (!s->pkt_pending)
        {
            if (!mav_next_packet( p, s, s->pkt ))
            {
                avcodec_send_packet( s->dec, NULL );
                s->draining = 1;
                continue;
            }
            s->pkt_pending = 1;
        }
        err = avcodec_send_packet( s->dec, s->pkt );
        if (err == AVERROR(EAGAIN)) continue;   /* output first, then this packet again */
        av_packet_unref( s->pkt );
        s->pkt_pending = 0;
        if (err < 0)
        {
            if (s->errors_logged < 3)
            {
                s->errors_logged++;
                mav_log( "%s: packet rejected (%d), skipped", s->info.codec, err );
            }
            if (++s->decode_errors > MAV_MAX_DECODE_ERRORS) return mav_give_up( s );
        }
    }
}

/***********************************************************************
 *           video
 */
static void mav_vframe_emit_cb( void *ctx, void *handle, int64_t pts, int64_t duration )
{
    struct mav_stream *s = ctx;
    unsigned int i;

    if (s->reorder_count == s->reorder_cap)
    {
        unsigned int cap = s->reorder_cap ? s->reorder_cap * 2 : 8;
        struct mav_vframe *grown = realloc( s->reorder, cap * sizeof(*grown) );
        if (!grown)
        {
            s->vbackend->release( handle );
            return;
        }
        s->reorder = grown;
        s->reorder_cap = cap;
    }
    if (pts == INT64_MIN)
    {
        /* no timestamp: right after the latest picture known */
        int64_t last = s->reorder_count ? s->reorder[s->reorder_count - 1].pts : s->last_vpts;
        int64_t step = duration != INT64_MIN && duration > 0 ? duration
                       : av_rescale_q( s->frame_duration, (AVRational){ 1, 10000000 }, s->time_base );
        pts = last == INT64_MIN ? s->origin : last + (step > 0 ? step : 1);
    }
    for (i = s->reorder_count; i > 0 && s->reorder[i - 1].pts > pts; i--)
        s->reorder[i] = s->reorder[i - 1];
    s->reorder[i].handle = handle;
    s->reorder[i].pts = pts;
    s->reorder[i].duration = duration;
    s->reorder_count++;
}

static inline uint8_t mav_clip8( int v )
{
    return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v;
}

struct mav_yuv_coefs
{
    int y, rv, gu, gv, bu, yoff;
};

static void mav_yuv_coefs( int bt709, int full, struct mav_yuv_coefs *c )
{
    double kr = bt709 ? 0.2126 : 0.299, kb = bt709 ? 0.0722 : 0.114, kg = 1.0 - kr - kb;
    double ys = full ? 1.0 : 255.0 / 219.0, cs = full ? 1.0 : 255.0 / 224.0;

    c->y = (int)lround( ys * 65536 );
    c->rv = (int)lround( 2 * (1 - kr) * cs * 65536 );
    c->bu = (int)lround( 2 * (1 - kb) * cs * 65536 );
    c->gu = (int)lround( 2 * (1 - kb) * kb / kg * cs * 65536 );
    c->gv = (int)lround( 2 * (1 - kr) * kr / kg * cs * 65536 );
    c->yoff = full ? 0 : 16;
}

/* Writes one decoded 4:2:0 bi-planar picture into `dst` in s->vout's format
 * and layout.  A picture smaller than the output is padded with black; a
 * larger one is cropped (the codec's cropping is the decoder's business). */
static void mav_convert_picture( struct mav_stream *s, const struct mav_vplanes *src, uint8_t *dst,
                                 const struct mav_layout *l )
{
    uint32_t w = s->vout.width, h = s->vout.height < 0 ? -s->vout.height : s->vout.height;
    uint32_t cw = src->width < w ? src->width : w, ch = src->height < h ? src->height : h;
    uint32_t ccw = (cw + 1) / 2, cch = (ch + 1) / 2, x, y;
    int flip = s->vout.height < 0;
    int planar = s->vout.fmt == MAV_PIX_NV12 || s->vout.fmt == MAV_PIX_I420 || s->vout.fmt == MAV_PIX_YV12;
    int packed = s->vout.fmt == MAV_PIX_YUY2 || s->vout.fmt == MAV_PIX_UYVY || s->vout.fmt == MAV_PIX_YVYU;

    if (cw < w || ch < h)
    {
        /* black: Y 16 / chroma 128, or RGB black (opaque where there is alpha) */
        if (packed)
            for (y = 0; y < h; y++)
                for (x = 0; x < l->stride[0] / 4; x++)
                    memcpy( dst + (size_t)y * l->stride[0] + x * 4,
                            s->vout.fmt == MAV_PIX_UYVY ? "\x80\x10\x80\x10" : "\x10\x80\x10\x80", 4 );
        else if (planar)
        {
            memset( dst, 16, l->offset[1] );
            memset( dst + l->offset[1], 128, l->size - l->offset[1] );
        }
        else if (s->vout.fmt == MAV_PIX_BGR || s->vout.fmt == MAV_PIX_RGB15 || s->vout.fmt == MAV_PIX_RGB16)
            memset( dst, 0, l->size );
        else
            for (y = 0; y < h; y++)
                for (x = 0; x < w; x++)
                    memcpy( dst + (size_t)y * l->stride[0] + x * 4, "\0\0\0\xff", 4 );
    }

#define DST_ROW(plane, row, rows) (dst + l->offset[plane] + (size_t)l->stride[plane] * (flip ? (rows) - 1 - (row) : (row)))
    switch (s->vout.fmt)
    {
    case MAV_PIX_NV12:
        for (y = 0; y < ch; y++) memcpy( DST_ROW( 0, y, h ), src->y + (size_t)y * src->y_stride, cw );
        for (y = 0; y < cch; y++) memcpy( DST_ROW( 1, y, l->chroma_height ), src->uv + (size_t)y * src->uv_stride, ccw * 2 );
        break;
    case MAV_PIX_I420:
    case MAV_PIX_YV12:
    {
        int u_plane = s->vout.fmt == MAV_PIX_I420 ? 1 : 2, v_plane = 3 - u_plane;
        for (y = 0; y < ch; y++) memcpy( DST_ROW( 0, y, h ), src->y + (size_t)y * src->y_stride, cw );
        for (y = 0; y < cch; y++)
        {
            const uint8_t *uv = src->uv + (size_t)y * src->uv_stride;
            uint8_t *u = DST_ROW( u_plane, y, l->chroma_height ), *v = DST_ROW( v_plane, y, l->chroma_height );
            for (x = 0; x < ccw; x++)
            {
                u[x] = uv[2 * x];
                v[x] = uv[2 * x + 1];
            }
        }
        break;
    }
    case MAV_PIX_YUY2:
    case MAV_PIX_UYVY:
    case MAV_PIX_YVYU:
    {
        /* byte offsets of Y0, U, Y1, V in each 4-byte pair */
        int y0 = s->vout.fmt == MAV_PIX_UYVY ? 1 : 0, y1 = y0 + 2;
        int uo = s->vout.fmt == MAV_PIX_YUY2 ? 1 : s->vout.fmt == MAV_PIX_UYVY ? 0 : 3;
        int vo = s->vout.fmt == MAV_PIX_YUY2 ? 3 : s->vout.fmt == MAV_PIX_UYVY ? 2 : 1;
        for (y = 0; y < ch; y++)
        {
            const uint8_t *yr = src->y + (size_t)y * src->y_stride, *uv = src->uv + (size_t)(y / 2) * src->uv_stride;
            uint8_t *o = DST_ROW( 0, y, h );
            for (x = 0; x < cw; x += 2)
            {
                o[2 * x + y0] = yr[x];
                o[2 * x + uo] = uv[x];
                o[2 * x + y1] = x + 1 < cw ? yr[x + 1] : yr[x];
                o[2 * x + vo] = uv[x + 1];
            }
        }
        break;
    }
    case MAV_PIX_BGRA:
    case MAV_PIX_BGRx:
    case MAV_PIX_RGBA:
    {
        struct mav_yuv_coefs c;
        int ri = s->vout.fmt == MAV_PIX_RGBA ? 0 : 2, bi = 2 - ri;
        mav_yuv_coefs( s->bt709, src->full_range, &c );
        for (y = 0; y < ch; y++)
        {
            const uint8_t *yr = src->y + (size_t)y * src->y_stride, *uv = src->uv + (size_t)(y / 2) * src->uv_stride;
            uint8_t *o = DST_ROW( 0, y, h );
            for (x = 0; x < cw; x++)
            {
                int yy = (yr[x] - c.yoff) * c.y + 32768;
                int u = uv[(x & ~1u)] - 128, v = uv[(x & ~1u) + 1] - 128;
                o[4 * x + ri] = mav_clip8( (yy + c.rv * v) >> 16 );
                o[4 * x + 1] = mav_clip8( (yy - c.gu * u - c.gv * v) >> 16 );
                o[4 * x + bi] = mav_clip8( (yy + c.bu * u) >> 16 );
                o[4 * x + 3] = 0xff;
            }
        }
        break;
    }
    case MAV_PIX_BGR:
    case MAV_PIX_RGB15:
    case MAV_PIX_RGB16:
    {
        struct mav_yuv_coefs c;
        mav_yuv_coefs( s->bt709, src->full_range, &c );
        for (y = 0; y < ch; y++)
        {
            const uint8_t *yr = src->y + (size_t)y * src->y_stride, *uv = src->uv + (size_t)(y / 2) * src->uv_stride;
            uint8_t *o = DST_ROW( 0, y, h );
            for (x = 0; x < cw; x++)
            {
                int yy = (yr[x] - c.yoff) * c.y + 32768;
                int u = uv[(x & ~1u)] - 128, v = uv[(x & ~1u) + 1] - 128;
                uint8_t r = mav_clip8( (yy + c.rv * v) >> 16 );
                uint8_t g = mav_clip8( (yy - c.gu * u - c.gv * v) >> 16 );
                uint8_t b = mav_clip8( (yy + c.bu * u) >> 16 );
                if (s->vout.fmt == MAV_PIX_BGR)
                {
                    o[3 * x] = b;
                    o[3 * x + 1] = g;
                    o[3 * x + 2] = r;
                }
                else
                {
                    uint16_t px = s->vout.fmt == MAV_PIX_RGB16
                                  ? (uint16_t)((r >> 3) << 11 | (g >> 2) << 5 | b >> 3)
                                  : (uint16_t)((r >> 3) << 10 | (g >> 3) << 5 | b >> 3);
                    o[2 * x] = (uint8_t)px;
                    o[2 * x + 1] = (uint8_t)(px >> 8);
                }
            }
        }
        break;
    }
    default:
        break;
    }
#undef DST_ROW
}

/* One picture out of the reorder queue, into s->buf.  Returns 1 if it is
 * the next buffer, 0 if it was dropped (before the seek target, past the
 * stop, or unmappable). */
static int mav_video_emit( struct mav_parser *p, struct mav_stream *s, struct mav_vframe *f )
{
    struct mav_vplanes planes;
    struct mav_layout l;
    int64_t pts = mav_to_100ns( s, f->pts ), dur;
    size_t size;

    dur = f->duration != INT64_MIN && f->duration > 0
          ? av_rescale_q( f->duration, s->time_base, (AVRational){ 1, 10000000 } ) : s->frame_duration;
    s->last_vpts = f->pts;
    if (s->seek_target >= 0)
    {
        if (pts + dur <= s->seek_target)
        {
            s->vbackend->release( f->handle );
            return 0;
        }
        s->seek_target = -1;
    }
    if (p->stop >= 0 && pts >= p->stop)
    {
        s->vbackend->release( f->handle );
        s->eos = 1;
        return 0;
    }
    size = mav_video_layout( s->vout.fmt, s->vout.width, s->vout.height < 0 ? -s->vout.height : s->vout.height, &l );
    if (!size || size > UINT32_MAX || !mav_reserve( s, size ))
    {
        s->vbackend->release( f->handle );
        s->eos = 1;
        mav_log( "stream %u: cannot hold a %zu-byte picture; ending the stream", s->number, size );
        return 0;
    }
    if (s->vbackend->map( f->handle, &planes ))
    {
        s->vbackend->release( f->handle );
        if (s->errors_logged < 3)
        {
            s->errors_logged++;
            mav_log( "stream %u: a decoded picture could not be mapped; dropped", s->number );
        }
        s->discontinuity = 1;
        return 0;
    }
    mav_convert_picture( s, &planes, s->buf, &l );
    s->vbackend->unmap( f->handle );
    s->vbackend->release( f->handle );

    s->next_pts = pts + dur;
    s->cur.pts = pts > 0 ? (uint64_t)pts : 0;
    s->cur.duration = dur;
    s->cur.size = (uint32_t)size;
    s->cur.stream = s->number;
    s->cur.discontinuity = s->discontinuity;
    s->cur.delta = 0;
    s->discontinuity = 0;
    s->has_buffer = 1;
    return 1;
}

static int mav_video_next( struct mav_parser *p, struct mav_stream *s )
{
    for (;;)
    {
        int err;

        if (s->eos) return MAV_NO_BUFFER;
        /* A picture is final once no later packet can present before it:
         * later packets decode at or after the last decode time, and a
         * picture never presents before it decodes. */
        if (s->reorder_count && (s->draining || s->reorder_count > MAV_REORDER_MAX
                                 || s->vbackend == &mav_lavc_video   /* already in presentation order */
                                 || (s->last_dts != INT64_MIN && s->reorder[0].pts <= s->last_dts)))
        {
            struct mav_vframe f = s->reorder[0];
            memmove( s->reorder, s->reorder + 1, (s->reorder_count - 1) * sizeof(*s->reorder) );
            s->reorder_count--;
            if (mav_video_emit( p, s, &f )) return MAV_OK;
            continue;
        }
        if (s->draining)
        {
            s->eos = 1;
            return MAV_NO_BUFFER;
        }
        if (!mav_next_packet( p, s, s->pkt ))
        {
            /* libavcodec holds its last pictures until it is drained */
            if (s->vbackend == &mav_lavc_video && !p->closing) mav_lavc_drain( s->vdec, mav_vframe_emit_cb, s );
            s->draining = 1;
            continue;
        }
        err = s->vbackend->decode( s->vdec, s->pkt->data, s->pkt->size,
                                    s->pkt->pts != AV_NOPTS_VALUE ? s->pkt->pts : INT64_MIN,
                                    s->pkt->duration > 0 ? s->pkt->duration : INT64_MIN,
                                    !!(s->pkt->flags & AV_PKT_FLAG_KEY), mav_vframe_emit_cb, s );
        s->last_dts = s->pkt->dts != AV_NOPTS_VALUE ? s->pkt->dts : INT64_MIN;
        av_packet_unref( s->pkt );
        if (err < 0)
        {
            if (s->errors_logged < 3)
            {
                s->errors_logged++;
                mav_log( "%s: packet rejected by %s (%d), skipped", s->info.codec, s->info.backend, err );
            }
            s->discontinuity = 1;
            if (++s->decode_errors > MAV_MAX_DECODE_ERRORS) return mav_give_up( s );
        }
        else s->decode_errors = 0;
    }
}

/***********************************************************************
 *           buffers
 */
static int mav_stream_next( struct mav_parser *p, struct mav_stream *s )
{
    if (!s->enabled) return MAV_NO_BUFFER;
    if (s->has_buffer) return MAV_OK;
    return s->type == MAV_STREAM_VIDEO ? mav_video_next( p, s ) : mav_audio_next( p, s );
}

static int mav_get_buffer( struct mav_parser *p, int stream, struct mav_buffer *buffer )
{
    struct mav_stream *s = NULL;
    int status = MAV_NO_BUFFER;
    unsigned int i;

    pthread_mutex_lock( &p->lock );
    if (!p->ready)
        status = MAV_E_STATE;
    else if (stream >= 0)
    {
        if (!(s = mav_get_stream( p, stream ))) status = MAV_E_STATE;
        else
        {
            s->reader = pthread_self();
            s->has_reader = 1;
            status = mav_stream_next( p, s );
            /* disabled while this reader slept in mav_wait_drain */
            if (status == MAV_OK && !s->enabled)
            {
                s->has_buffer = 0;
                status = MAV_NO_BUFFER;
            }
        }
    }
    else
    {
        /* wg_parser.c: the earliest buffer of all streams, by pts.  This
         * thread reads them all, so none waits for another (mav_wait_drain). */
        for (i = 0; i < p->stream_count; i++)
        {
            p->streams[i]->reader = pthread_self();
            p->streams[i]->has_reader = 1;
        }
        for (i = 0; i < p->stream_count; i++)
        {
            struct mav_stream *c = p->streams[i];
            if (mav_stream_next( p, c ) != MAV_OK || !c->enabled) continue;
            if (!s || c->cur.pts < s->cur.pts) s = c;
        }
        status = s ? MAV_OK : MAV_NO_BUFFER;
    }
    if (status == MAV_OK) *buffer = s->cur;
    /* a queue may have shrunk, or a stream ended: a waiter re-checks */
    if (p->bp_waiters) pthread_cond_broadcast( &p->drain_cond );
    pthread_mutex_unlock( &p->lock );
    return status;
}

static int mav_copy_buffer( struct mav_parser *p, unsigned int stream, void *dst, uint32_t offset, uint32_t size )
{
    struct mav_stream *s;
    int status = MAV_OK;

    pthread_mutex_lock( &p->lock );
    if (!(s = mav_get_stream( p, stream )) || !s->has_buffer)
        status = MAV_E_STATE;
    else if (offset > s->cur.size || size > s->cur.size - offset || (size && !dst))
        status = MAV_E_PARAM;
    else
        memcpy( dst, s->buf + offset, size );
    pthread_mutex_unlock( &p->lock );
    return status;
}

static void mav_release_buffer( struct mav_parser *p, unsigned int stream )
{
    struct mav_stream *s;

    pthread_mutex_lock( &p->lock );
    if ((s = mav_get_stream( p, stream ))) s->has_buffer = 0;
    pthread_mutex_unlock( &p->lock );
}

/***********************************************************************
 *           seek
 */
static int mav_seek( struct mav_parser *p, unsigned int stream, int set_start, uint64_t start,
                     int set_stop, uint64_t stop )
{
    struct mav_stream *s, *ref = NULL;
    int status = MAV_OK;
    unsigned int i;

    pthread_mutex_lock( &p->lock );
    if (!(s = mav_get_stream( p, stream )))
    {
        pthread_mutex_unlock( &p->lock );
        return MAV_E_STATE;
    }
    if (set_stop)
    {
        /* wg_parser.c: a stop at the duration means "no stop" */
        if (stop == s->info.duration || (s->info.duration && stop > s->info.duration))
            p->stop = -1;
        else
            p->stop = stop > INT64_MAX ? -1 : (int64_t)stop;
    }
    if (set_start)
    {
        int64_t target = (int64_t)(start > INT64_MAX / 2 ? INT64_MAX / 2 : start), ts;
        int err;

        /* Seek on the video stream, so the demuxer lands on a keyframe. */
        for (i = 0; i < p->stream_count; i++)
            if (!ref || p->streams[i]->type == MAV_STREAM_VIDEO) ref = p->streams[i];
        ts = av_rescale_q( target, (AVRational){ 1, 10000000 }, ref->time_base ) + ref->origin;

        /* A failed read (a NULL push) latches in the AVIOContext; a seek is
         * the PE side's way to start over, so it must not stay failed. */
        p->avio->error = 0;
        p->avio->eof_reached = 0;
        err = avformat_seek_file( p->fmt, ref->av_index, INT64_MIN, ts, ts, 0 );
        if (err < 0) err = av_seek_frame( p->fmt, ref->av_index, ts, AVSEEK_FLAG_BACKWARD );
        if (err < 0)
        {
            mav_log( "seek to %llums failed (%d)", (unsigned long long)(start / 10000), err );
            status = MAV_E_IO;
        }
        else
        {
            p->demux_eof = 0;
            for (i = 0; i < p->stream_count; i++)
            {
                struct mav_stream *c = p->streams[i];

                if (c->dec) avcodec_flush_buffers( c->dec );
                if (c->adec) mav_abackend->flush( c->adec );
                if (c->vdec)
                {
                    mav_reorder_clear( c );
                    c->vbackend->flush( c->vdec );
                }
                swr_free( &c->swr );
                if (c->pkt_pending) av_packet_unref( c->pkt );
                c->pkt_pending = 0;
                mav_queue_clear( c );
                c->apts_count = 0;
                c->has_buffer = 0;
                c->eos = c->draining = 0;
                c->decode_errors = 0;
                c->discontinuity = 1;
                c->seek_target = target;
                c->next_pts = target;
                c->last_dts = c->last_vpts = INT64_MIN;
            }
            p->generation++;
            if (p->bp_waiters) pthread_cond_broadcast( &p->drain_cond );
        }
    }
    pthread_mutex_unlock( &p->lock );
    return status;
}
