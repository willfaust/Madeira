/* iOS unix side for dlls/winegstreamer: the WMA decoder, on libavcodec.
 *                                                        (MADEIRA, 2026-09-19)
 *
 * WHY THIS EXISTS
 * ---------------
 * A 2008-era title that plays its music and cutscene dialogue through
 * XAudio2 2.2 gets loud static instead.  The chain, from the device log:
 *
 *   err:module:load_dll [dll-missing] L"C:\windows\system32\winegstreamer.dll"
 *                        status=c0000135
 *   err:ole:com_get_class_object no class object {5b4d4e54-...} (wg_wma_decoder)
 *   fixme:ole:CoCreateInstanceEx no instance created for interface
 *       {bf94c121-...} (IMFTransform) of class {2eeb4adf-...}
 *       (CLSID_CWMADecMediaObject), hr 0x80070005
 *
 * FAudio decodes an xWMA/WMA voice by asking COM for the Windows WMA decoder
 * MFT (libs/faudio/src/FAudio_platform_win32_wmadec.c: CoCreateInstance of
 * CLSID_CWMADecMediaObject for IMFTransform).  In Wine that CLSID lives in
 * wmadmod.dll, which forwards to CLSID_wg_wma_decoder {5b4d4e54-...} in
 * winegstreamer.dll, whose decoder is a GStreamer pipeline in
 * winegstreamer.so.  There is no GStreamer on iOS, so the whole chain was
 * absent -- and FAudio, given no decoder, submits the COMPRESSED bytes to the
 * mixer as if they were PCM.  That is exactly the "wrong audio" plus the
 * 8x-full-scale peaks our audio census reported, while a PCM menu sound (which
 * needs no decoder at all) stayed clean.
 *
 * The prefix registry already registers all of it (the shipped
 * app/Madeira/prefix-template.tar.gz was snapshotted from a host Wine that ran
 * wine.inf's RegisterDllsSection), so nothing has to be registered here: what
 * was missing is the PE winegstreamer.dll (built with --enable-winegstreamer,
 * see docs/MEDIA.md) and
 * this, its unix side.
 *
 * SHAPE
 * -----
 * Same shape as nsi_unixlib_ios.c: the unix call table of a Wine DLL,
 * hand-written for this port, bound BY NAME in virtual_ios.c's
 * load_builtin_unixlib().  The table's INDEX LAYOUT is dlls/winegstreamer/
 * unixlib.h's `enum unix_funcs`, entry for entry, including the entries this
 * port does not implement -- an index that drifts from the header silently
 * dispatches one call to another function's argument block.
 *
 * What is implemented is the wg_transform subset that wma_decoder.c and
 * video_decoder.c's WMV decoder use: create / destroy / push_data /
 * read_data / get_output_type / set_output_type / drain / flush / get_status
 * (+ notify_qos as a no-op, and wg_init_gstreamer as a benign success so
 * main.c's init_gstreamer_proc lets the DLL load), for three kinds of
 * transform: WMA audio (below), WMV video (the section "the WMV decoder") and
 * the audio resampler (resampler.c's; the section after it).  "Transform
 * kinds" is how a call finds its kind.  The wg_muxer
 * side returns STATUS_NOT_IMPLEMENTED.  Those callers already handle a
 * component that is not available; what they must never get is a success
 * with an untouched output field (no fake success).
 *
 * ml1980: the wg_parser side (quartz's splitters, and the same pull protocol
 * for the MF media source) is implemented for AUDIO files only -- MP3 (and
 * MPEG-1 layer I/II) and WAV/PCM, decoded to interleaved PCM -- by
 * wg_parser_av_ios.c on libavformat/libavcodec; its header has the details.
 * Video and anything else unrecognised fail connect() with an error so quartz
 * moves on to its next filter.  MADEIRA_WG_PARSER=0 restores the refusal.
 * ml1990 adds MP4/MOV (H.264 / HEVC on VideoToolbox, AAC on AudioToolbox, in
 * wg_parser_apple_ios.c) for the Media Foundation source; MADEIRA_WG_VIDEO=0
 * restores the MP3/WAV-only parser.
 *
 * wg_transform_create also REFUSES anything that is not a WMA family
 * stream, Windows Media video (WMV1/WMV2/WMV3/WMVA/WVC1) or raw audio (the
 * resampler, on libswresample).  winegstreamer's other transforms (aac, h264,
 * the colour converter) are real GStreamer pipelines with no replacement
 * here, and a transform that accepts an H.264 stream and then emits nothing
 * is worse for the caller than one that never opened.
 * MADEIRA_WG_WMV_TRANSFORM=0 refuses the WMV one too, MADEIRA_WG_RESAMPLER=0
 * the resampler.
 *
 * DECODING
 * --------
 * libavcodec, from build/ffmpeg/build.sh (FFmpeg 7.1.5, LGPL configuration:
 * --disable-gpl --disable-nonfree, wmav1/wmav2/wmapro/wmalossless/xma1/xma2
 * only).  The input media type is a WAVEFORMATEX -- wg_media_type_from_mf()
 * produces it with MFCreateWaveFormatExFromMFMediaType -- so the codec id,
 * sample rate, channel count/mask, nBlockAlign and the cbSize codec-private
 * bytes are all right there, and no container parser is needed.
 *
 * PACKETISATION: every WMA decoder in libavcodec wants ONE packet of exactly
 * avctx->block_align bytes.  A pushed sample is one or more such packets
 * (FAudio submits whole xWMA blocks), so the bytes are accumulated and split
 * here; a trailing partial packet waits for the next push and is only decoded
 * at drain time.
 *
 * FORMAT CONVERSION: libswresample, for sample format and channel layout ONLY.
 * The output type's sample rate must equal the input's -- a resampler is a
 * different transform (CLSID_wg_resampler), the WMA MFT never advertises a
 * rate change, and silently resampling here would hide a negotiation bug as a
 * pitch bug.
 *
 * -------------------------------------------------------------------------
 * xWMA AND ITS LYING BIT RATE   (device log u87, 2026-09-19)
 * -------------------------------------------------------------------------
 * The first device run decoded one stream and failed EVERY packet of another:
 *
 *   [wma] decoder created fmt=wmav2 tag=0x161 44100Hz 1ch block=139 extradata=10 ...
 *   [wma] decoder created fmt=wmav2 tag=0x161 22050Hz 2ch block=1487 extradata=16 ...
 *   [wma] avcodec_send_packet failed (-1), dropping 1487 bytes   x4762
 *
 * The two streams differ in where their codec-private data comes from, and
 * that is the whole story.
 *
 * `extradata=10` is a REAL WMA v2 codec-private blob, the one an ASF header
 * carries: {DWORD samples_per_block; WORD encode_options; DWORD
 * super_block_align}.  libavcodec reads flags2 = AV_RL16(extradata + 4) out of
 * it (libavcodec/wmadec.c wma_decode_init), which is `encode_options`, and
 * that stream decodes.
 *
 * `extradata=16` is NOT codec-private data at all.  FAudio has none to give --
 * an xWMA RIFF's `fmt ` chunk is a plain WAVEFORMATEX with no tail -- so
 * FAudio_WMADEC_init INVENTS one:
 *
 *   static const uint8_t fake_codec_data[16] = {0,0,0,0,31,0,0,0,0,0,0,0,0,0,0,0};
 *
 * That is the right thing to do and the 31 is not arbitrary: FFmpeg's own xWMA
 * demuxer writes the identical shape, six bytes with [4] = 31, over the
 * comment "setup extradata with our experimentally obtained value"
 * (libavformat/xwma.c).  flags2 = 31 means exp-VLC + bit reservoir + variable
 * block length, which is what the Microsoft xWMA encoder produces -- and it is
 * why block_align is 1487 rather than a couple of hundred bytes: with a bit
 * reservoir a packet is a SUPERFRAME holding several 1024-sample frames.
 *
 * So the flags are right.  What is wrong is the bit rate, and xwma.c says so
 * in as many words, right above the fixup this file now mirrors:
 *
 *   "XWMA encoder only allows a few channel/sample rate/bitrate combinations,
 *    but some create identical files with fake bitrate (1ch 22050hz at
 *    20/48/192kbps are all 20kbps, with the exact same codec data).
 *    Decoder needs correct bitrate to work, so it's normalized here."
 *
 * 22050 Hz stereo -- our failing stream -- is one of the listed rows.  The
 * bit rate is not cosmetic to libavcodec: ff_wma_init (libavcodec/wma.c)
 * derives `bps` from it and then picks the coefficient VLC table
 * (coef_vlc_table, wma.c:335-343), the high band start (high_freq, :149-181),
 * whether noise coding is on (:111) and -- decisively for a bit-reservoir
 * stream -- `byte_offset_bits` (:141), which is how many bits of the
 * SUPERFRAME HEADER hold the offset of the first frame.  Get that wrong and
 * every superframe is misparsed and wma_decode_superframe falls through to its
 * `fail:` label, whose statement is a bare `return -1` (wmadec.c:992).  The
 * log's `(-1)` is that exact line and no other error path in the decoder.
 *
 * WHAT THIS FILE DOES ABOUT IT, AND WHY IT IS A RETRY AND NOT A TABLE LOOKUP.
 * xwma.c's table is applied here (xwma_true_bit_rate below), but only as a
 * CANDIDATE, because a table cannot be trusted on its own from this side: the
 * same entry point also serves honest ASF WMA v2 (that is the 44100 Hz stream
 * that already worked), and "1ch 44100 Hz at 96 kbps" is both a row in that
 * table and a perfectly ordinary real file.  So the decoder is opened with the
 * bit rate the media type reported, and only if a packet FAILS BEFORE ANY
 * OUTPUT HAS BEEN PRODUCED is it reopened once with the normalised rate and
 * the same packet retried.  That is self-validating: it cannot touch a stream
 * that already decodes, it costs one reopen on a stream that does not, and
 * whichever rate wins is logged so the next device log states it as fact
 * rather than leaving it to be inferred.
 *
 * A HOST REPRODUCTION IS ONLY PARTIAL, and the honest note is worth keeping:
 * FFmpeg's own wmav2 ENCODER emits flags2 = 0x0001 -- no bit reservoir, one
 * frame per packet -- so it cannot produce a superframe stream to reproduce
 * the device failure exactly.  Decoding such a stream with flags2 = 31 fails
 * every packet (verified), which confirms the flags path; the bit-rate
 * sensitivity above is read from libavcodec's source and from FFmpeg's own
 * xWMA fixup, not measured here.
 *
 * -------------------------------------------------------------------------
 * THE BIT RATE WAS NEVER THE WHOLE STORY: flags2's BLOCK-SIZE COUNT
 *                                          (MADEIRA, 2026-09-21, host-proved)
 * -------------------------------------------------------------------------
 * Real wave-bank streams were finally decoded on the host, packet by packet,
 * through this same libavcodec.  One combination failed every declared bit
 * rate -- 32000 Hz mono, block_align 1280 -- while three others from the same
 * bank decoded perfectly.  The bit rate the table names for it (20000) is
 * RIGHT: the wave bank's own duration divided by its packet count says eight
 * 2048-sample frames per 1280-byte packet, which is 20000 bit/s exactly, and
 * the frames-per-packet nibble in the packet headers averages 7.85.
 *
 * What is wrong is the OTHER number the caller invents.  ff_wma_init derives
 * the count of MDCT block sizes from bits 3-4 of flags2:
 *
 *     nb = ((flags2 >> 3) & 3) + 1;
 *     if ((bit_rate / channels) >= 32000) nb += 2;
 *     if (nb > frame_len_bits - BLOCK_MIN_BITS) nb = frame_len_bits - BLOCK_MIN_BITS;
 *     s->nb_block_sizes = nb + 1;
 *
 * and wma_decode_block then reads its three block-length fields
 * av_log2(nb_block_sizes - 1) + 1 bits wide each.  The synthetic flags2 = 31
 * has bits 3-4 = 3, so nb = 4 and nb_block_sizes = 5, which is THREE bits per
 * field; this stream's encoder used three block sizes, which is TWO.  Every
 * frame is then read three bits out of phase and the decoder reports exactly
 * what the device log shows -- "next_block_len_bits 6 out of range".
 *
 * That is also why the failure looked like it belonged to one rate: at 22050
 * Hz and below, frame_len_bits is 10 and the `nb_max` clamp above pins
 * nb_block_sizes at 4 whatever bits 3-4 say, so the fabricated 31 is harmless.
 * At 32000 Hz and above, frame_len_bits is 11, the clamp lets 5 through, and
 * the fabrication becomes audible -- as silence, because the old ladder ran
 * out of guesses and muted.
 *
 * SO THE SEARCH IS OVER DERIVED PARAMETERS, NOT DECLARED ONES.  bit_rate and
 * flags2 reach the decoder only through four quantities -- byte_offset_bits,
 * nb_block_sizes, use_noise_coding and the coefficient VLC table -- and two
 * candidates with the same four are the same decoder however different their
 * declared numbers look.  wma_build_candidates() below enumerates them in
 * evidence order and drops duplicates by that signature, so the ladder is
 * short, finite and complete: it cannot mute a stream before every distinct
 * superframe-offset width and block-size count has been tried.
 *
 * AND A CANDIDATE IS JUDGED BY THE STREAM'S OWN ARITHMETIC.  "avcodec_send_
 * packet returned 0" is far too weak -- switching the bit reservoir off makes
 * every packet "succeed" as one independent frame.  A packet decoded under the
 * right parameters yields exactly the frame count its own superframe header
 * declares, so wma_packet_ok() compares the two (see its comment for the
 * slack), and that is what separates "it decoded" from "it decoded THIS
 * stream".  Host result, real wave-bank streams, seventeen of them across all
 * six (channels, rate, block_align) combinations one bank holds: every packet
 * of every stream, where before this the 32000 Hz mono streams decoded none.
 *
 * -------------------------------------------------------------------------
 * A FAILED PACKET MUST STILL PRODUCE TIME
 * -------------------------------------------------------------------------
 * Dropping a packet silently is not the same as producing silence, and the
 * difference is audible.  FAudio's decode loop
 * (FAudio_INTERNAL_DecodeWMAMF) walks the voice with two independent cursors:
 * `samples_pos`, which advances by what the VOICE consumed, and `output_pos`,
 * which advances by what the DECODER produced, and it copies
 * `output_buf + samples_pos`.  Its output buffer is sized from the xWMA dpds
 * table -- the byte count the stream PROMISES -- and allocated with pRealloc,
 * which does not zero.  A decoder that returns fewer bytes than the dpds table
 * promised therefore leaves the tail of that buffer holding whatever was in
 * the heap, and a voice whose cursor has run past `output_pos` reads it.
 *
 * So a packet that fails to decode now emits SILENCE of the length that packet
 * represented (its share of nAvgBytesPerSec, or the frame count of the last
 * packet that did decode) rather than nothing at all.  The decoder's byte
 * budget then still matches the container's, and the failure is inaudible
 * instead of being someone else's uninitialised memory.
 *
 * The per-packet failure line is capped at 8 per decoder -- the first run
 * printed 4,762 identical lines, which is a way to lose a device log -- and a
 * one-line summary is printed when the transform is flushed or destroyed.
 */

#include "config.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

/* ml1980: the wg_parser core (libavformat demux + decode, the PE read-thread
 * pull protocol).  It includes no Wine header, so it comes first; the Wine
 * side of the wg_parser entries is at the end of this file. */
#include "wg_parser_av_ios.c"

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winbase.h"
#include "winternl.h"
#include "winerror.h"
#include "mferror.h"

#include "unixlib.h"

/* XMA is not in mmreg.h (it is an Xbox-era tag that never reached the public
 * SDK header), and neither is the WAVEFORMATEXTENSIBLE subformat base. */
#define MADEIRA_WAVE_FORMAT_XMA1  0x0165
#define MADEIRA_WAVE_FORMAT_XMA2  0x0166

/* Per-decoder cap on the per-packet failure line; the rest are counted and
 * reported once. */
#define MADEIRA_WMA_MAX_FAIL_LOGS 8

/* Upper bound on the parameter ladder.  The generator below deduplicates by
 * the parameters libavcodec actually derives, so a real stream uses far fewer
 * than this; the cap is only there so a malformed media type cannot make the
 * list grow. */
#define MADEIRA_WMA_MAX_CANDIDATES 48

/* How many packet headers the frames-per-packet average is taken over before
 * it is used to rank candidates.  One packet is not enough: the nibble swings
 * by three or four either side of the mean on a bit-reservoir stream, which is
 * how the old ladder came to try 26666 and 22857 bit/s for a 20000 bit/s
 * stream. */
#define MADEIRA_WMA_NIBBLE_WINDOW 16

struct wma_candidate
{
    INT64 bit_rate;
    int flags2;
    const char *why;
};

static const GUID madeira_MFMediaType_Audio =
    { 0x73647561, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

/* {0000XXXX-0000-0010-8000-00AA00389B71}: the MEDIASUBTYPE / KSDATAFORMAT
 * family whose Data1 IS the wave format tag.  Used to read the real tag out of
 * a WAVEFORMATEXTENSIBLE, which is what MFCreateWaveFormatExFromMFMediaType
 * produces for >2 channels or >16 bits. */
static BOOL madeira_subtype_tag( const GUID *guid, UINT *tag )
{
    static const GUID base =
        { 0x00000000, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

    if (guid->Data2 != base.Data2 || guid->Data3 != base.Data3 ||
        memcmp( guid->Data4, base.Data4, sizeof(base.Data4) ))
        return FALSE;
    *tag = guid->Data1;
    return TRUE;
}

#define MADEIRA_WG_TRANSFORM_MAGIC 0x574d4144  /* 'WMAD' */

struct wma_transform
{
    UINT32 magic;
    pthread_mutex_t lock;

    const AVCodec *codec;
    AVCodecContext *avctx;
    AVFrame *frame;
    AVPacket *packet;
    SwrContext *swr;

    /* everything needed to REOPEN the decoder with a different bit rate */
    enum AVCodecID codec_id;
    BYTE *extradata;
    UINT32 extradata_size;
    UINT32 channel_mask;
    INT64 bit_rate;         /* what the decoder is open with now */
    INT64 bit_rate_alt;     /* xwma.c's normalised value, 0 if none applies */
    INT64 header_rate;      /* nAvgBytesPerSec * 8, whatever it is worth */
    int flags2_open;        /* the flags2 the decoder is open with */
    BOOL produced_output;

    UINT32 block_align;     /* input packet size, bytes */
    UINT32 rate;
    UINT32 in_channels;
    UINT32 avg_bytes;       /* nAvgBytesPerSec, for the silence estimate */
    UINT32 depth;           /* WAVEFORMATEX wBitsPerSample, as gst-libav passes it */

    /* negotiated PCM output */
    enum AVSampleFormat out_sample_fmt;
    AVChannelLayout out_layout;
    UINT32 out_channels;
    UINT32 out_frame_size;  /* bytes per PCM frame (all channels) */

    /* the exact WAVEFORMATEX(-EXTENSIBLE) the caller set as the output type,
     * kept verbatim so wg_transform_get_output_type hands back what was
     * negotiated rather than a reconstruction of it */
    BYTE *out_format;
    UINT32 out_format_size;

    /* staged compressed input */
    BYTE *in_buf;
    size_t in_cap, in_len;

    /* decoded PCM, consumed by read_data */
    BYTE *pcm_buf;
    size_t pcm_cap, pcm_pos, pcm_len;

    /* 100 ns, of the first frame still in pcm_buf */
    INT64 pts;
    BOOL have_pts;
    BOOL draining;
    BOOL discontinuity;

    /* failure accounting (see the header comment's last section) */
    UINT32 fail_count;
    UINT32 fail_logged;
    UINT64 silence_frames;
    UINT32 last_frames;     /* frames the last SUCCESSFUL packet produced */

    /* v95 instrumentation: what actually arrives, and at what phase */
    UINT32 push_count;
    UINT32 packet_count;
    UINT32 short_tail_dropped;
    UINT32 candidate;       /* index into the parameter candidate list */

    /* w2: a candidate is not "accepted" until it has produced SANE audio for
     * several packets running, and a decoder that runs out of candidates is
     * muted for good.  Garbage at +19 dB is worse than no audio. */
    UINT32 good_packets;
    UINT32 insane_frames;
    BOOL frame_rejected;   /* set by append_frame for the packet in flight */
    BOOL muted;

    /* ml1120: the ladder, and what judges it */
    struct wma_candidate candidates[MADEIRA_WMA_MAX_CANDIDATES];
    UINT32 candidate_count;
    UINT32 coded_frames;    /* frames the packet in flight produced */
    UINT32 frame_slack;     /* frames the next packet may legitimately lose */
    UINT32 nibble_sum;      /* frames-per-packet nibbles seen so far, and */
    UINT32 nibble_packets;  /* how many headers they came from */
    BOOL accepted;          /* a candidate has proved itself; stop searching */
    BOOL search_done;       /* every rung has been tried */
    BOOL search_off;        /* MADEIRA_WMA_SEARCH=0 */

    /* the rung that got furthest, to fall back to rather than leaving the
     * decoder holding whatever the last rung was */
    INT64 best_rate;
    int best_flags2;
    UINT32 best_good;

    /* MADEIRA_WMA_DUMP=1: the exact bytes, for decoding on the host */
    int dump_fd;
    UINT32 dumped_packets;
};

/* How many consecutive sane packets a candidate must produce before it is
 * believed.  One is not enough: w2 shows a wrong configuration decoding a
 * single packet "successfully" and then emitting noise. */
#define MADEIRA_WMA_ACCEPT_PACKETS 3
/* Float PCM from a WMA decoder lives in [-1, 1].  A little headroom is normal
 * (inter-sample peaks, lossless content); 9.4 -- what the device census
 * measured -- is not audio. */
/* Host decode of real streams: legitimate peaks of 1.27 and 1.54 (lossy
 * overshoot); garbage from wrong parameters reads 4.5 to 15.  1.25 rejected
 * real audio. */
#define MADEIRA_WMA_SANE_PEAK 3.0f

/* The whole file logs with dprintf(2, ...) rather than ERR/TRACE: this unix
 * side has no Wine debug channel of its own in this build, and the app runs
 * with WINEDEBUG=err+all,err-virtual, so a channel-gated line would be
 * invisible in exactly the device logs these messages exist for. */
/*
 * ml990: CAPPED, AND THEN GATED.
 *
 * dprintf(2, ...) here is a real write(2) to the log file (stderr is dup2'd to
 * it), and this macro fires roughly eight times per decoded audio packet --
 * push, packet number, three "nothing decoded at N bit/s" lines, a provisional
 * rate line.  In device log x101 it was 1610 lines, second only to the
 * thread-stack walk, and every one of them is a syscall on the audio thread
 * during gameplay.
 *
 * Two changes, in the order that matters:
 *   1. A HARD CAP on the steady-state lines, so a stream that is failing every
 *      packet cannot turn a decode problem into a logging problem.  The first
 *      MADEIRA_WMA_MAX_LOGS lines are exactly what they were -- which is what
 *      a diagnosis needs, because the interesting part of a WMA failure is
 *      always at the start of the stream.
 *   2. MADEIRA_DIAG=1 lifts the cap entirely, for when the stream itself is
 *      what is under investigation.
 *
 * The cap is announced once so a reader never mistakes silence for success.
 */
#define MADEIRA_WMA_MAX_LOGS 200

static unsigned int wma_log_count;

/* MADEIRA_DIAG=1 lifts the cap; read once.  Local to this file so the media
 * unix side links against nothing but upstream's libntdll_unix.a. */
static int wma_diag_on( void )
{
    static int diag = -1;
    int d = __atomic_load_n( &diag, __ATOMIC_RELAXED );

    if (d < 0)
    {
        const char *v = getenv( "MADEIRA_DIAG" );
        d = (v && *v && v[0] != '0') ? 1 : 0;
        __atomic_store_n( &diag, d, __ATOMIC_RELAXED );
    }
    return d;
}

#define WMA_LOG( fmt, ... )                                                          \
    do {                                                                             \
        unsigned int _n = __atomic_add_fetch( &wma_log_count, 1, __ATOMIC_RELAXED ); \
        if (_n <= MADEIRA_WMA_MAX_LOGS)                                              \
            dprintf( 2, "[wma] " fmt, ## __VA_ARGS__ );                              \
        else if (_n == MADEIRA_WMA_MAX_LOGS + 1)                                     \
            dprintf( 2, "[wma] further per-packet lines suppressed after %u "         \
                        "(rev=ml1120; MADEIRA_DIAG=1 removes the cap)\n",             \
                     (unsigned int)MADEIRA_WMA_MAX_LOGS );                           \
        else if (wma_diag_on())                                                      \
            dprintf( 2, "[wma] " fmt, ## __VA_ARGS__ );                              \
    } while (0)

/***********************************************************************
 *           libavcodec's own diagnostics
 *
 * MADEIRA 2026-09-19 (log v95).  wmadec explains every one of its failures --
 * "nb_frames is 0 bits left 11888", "next_block_len_bits 6 out of range",
 * "overflow (470 > 466) in spectral RLE" -- and each one names a DIFFERENT
 * field of the bitstream, which is the difference between "wrong parameters"
 * and "wrong bytes".  Those lines were already in v95 and were nearly missed:
 * they go to stderr through av_log's default callback with libavcodec's own
 * "[wmav2 @ 0x...]" prefix, so a grep for this port's "[wma]" tag does not
 * find them.  Routing them through the same tag makes the decoder's own
 * diagnosis part of the log everyone actually reads.
 *
 * Capped, because a stream that fails every packet produces one of these per
 * frame -- v95 spent 11,000 lines on them.
 */
#define MADEIRA_WMA_MAX_AV_LOGS 64

static unsigned int wma_av_log_count;

/* The WMV transform's decoders are opened by the wg_parser core's backend and
 * then marked with this instead of MAV_DECODER_MARKER (wmv_create). */
static const char wmv_decoder_marker;
#define WMV_DECODER_MARKER ((void *)&wmv_decoder_marker)

/* ml1980: the same callback serves the wg_parser core, whose demuxer and
 * decoder contexts are told apart by their class (the demuxer / its I/O) or
 * by the marker the core leaves in AVCodecContext.opaque, so a parser
 * diagnostic is not reported as a WMA one.  One cap for all of them. */
static const char *av_log_owner( void *avcl )
{
    const AVClass *cls = avcl ? *(const AVClass **)avcl : NULL;

    if (!cls || !cls->class_name) return "[wma] av:";
    if (!strcmp( cls->class_name, "AVFormatContext" ) || !strcmp( cls->class_name, "AVIOContext" ))
        return "[wg-parser] av:";
    if (!strcmp( cls->class_name, "AVCodecContext" )
        && ((AVCodecContext *)avcl)->opaque == MAV_DECODER_MARKER)
        return "[wg-parser] av:";
    if (!strcmp( cls->class_name, "AVCodecContext" )
        && ((AVCodecContext *)avcl)->opaque == WMV_DECODER_MARKER)
        return "[wmv] av:";
    return "[wma] av:";
}

static void wma_av_log( void *avcl, int level, const char *fmt, va_list args )
{
    char buf[512];
    int n;

    if (level > AV_LOG_WARNING) return;
    if (wma_av_log_count >= MADEIRA_WMA_MAX_AV_LOGS)
    {
        if (wma_av_log_count == MADEIRA_WMA_MAX_AV_LOGS)
        {
            wma_av_log_count++;
            dprintf( 2, "[wma] av: further libavcodec/libavformat diagnostics suppressed\n" );
        }
        return;
    }
    wma_av_log_count++;
    n = vsnprintf( buf, sizeof(buf), fmt, args );
    if (n <= 0) return;
    dprintf( 2, "%s %s%s", av_log_owner( avcl ), buf, buf[strlen(buf) - 1] == '\n' ? "" : "\n" );
}

static pthread_once_t wma_av_log_once = PTHREAD_ONCE_INIT;

static void wma_install_av_log(void)
{
    av_log_set_callback( wma_av_log );
}

static struct wma_transform *get_wma_transform( wg_transform_t handle )
{
    struct wma_transform *transform = (struct wma_transform *)(UINT_PTR)handle;

    if (!transform || transform->magic != MADEIRA_WG_TRANSFORM_MAGIC) return NULL;
    return transform;
}

/***********************************************************************
 *           media type helpers
 */
static const WAVEFORMATEX *audio_format( const struct wg_media_type *type )
{
    if (!IsEqualGUID( &type->major, &madeira_MFMediaType_Audio )) return NULL;
    if (!type->u.audio || type->format_size < sizeof(WAVEFORMATEX)) return NULL;
    return type->u.audio;
}

/* The effective format tag: WAVE_FORMAT_EXTENSIBLE hides it in SubFormat. */
static UINT format_tag( const WAVEFORMATEX *wfx, UINT32 size )
{
    UINT tag = wfx->wFormatTag;

    if (tag == WAVE_FORMAT_EXTENSIBLE && size >= sizeof(WAVEFORMATEXTENSIBLE))
    {
        const WAVEFORMATEXTENSIBLE *ext = (const WAVEFORMATEXTENSIBLE *)wfx;
        UINT sub;
        if (madeira_subtype_tag( &ext->SubFormat, &sub )) return sub;
    }
    return tag;
}

static UINT32 channel_mask( const WAVEFORMATEX *wfx, UINT32 size )
{
    if (wfx->wFormatTag == WAVE_FORMAT_EXTENSIBLE && size >= sizeof(WAVEFORMATEXTENSIBLE))
        return ((const WAVEFORMATEXTENSIBLE *)wfx)->dwChannelMask;
    return 0;
}

static enum AVCodecID codec_id_from_tag( UINT tag )
{
    switch (tag)
    {
    case WAVE_FORMAT_MSAUDIO1:          return AV_CODEC_ID_WMAV1;
    case WAVE_FORMAT_WMAUDIO2:          return AV_CODEC_ID_WMAV2;
    case WAVE_FORMAT_WMAUDIO3:          return AV_CODEC_ID_WMAPRO;
    case WAVE_FORMAT_WMAUDIO_LOSSLESS:  return AV_CODEC_ID_WMALOSSLESS;
    case MADEIRA_WAVE_FORMAT_XMA1:      return AV_CODEC_ID_XMA1;
    case MADEIRA_WAVE_FORMAT_XMA2:      return AV_CODEC_ID_XMA2;
    default:                            return AV_CODEC_ID_NONE;
    }
}

/* WinMM's dwChannelMask and FFmpeg's AV_CH_* share the first 18 bit positions
 * (SPEAKER_FRONT_LEFT == AV_CH_FRONT_LEFT == 1, and so on in the same order),
 * which is why this is a widen and not a table. */
static void layout_from_mask( AVChannelLayout *layout, UINT32 mask, UINT32 channels )
{
    if (mask && av_popcount( mask ) == (int)channels &&
        av_channel_layout_from_mask( layout, mask ) >= 0)
        return;
    av_channel_layout_default( layout, channels );
}

/***********************************************************************
 *           xwma_true_bit_rate
 *
 * libavformat/xwma.c, verbatim: the (channels, sample rate, reported bit rate)
 * combinations the Microsoft xWMA encoder is known to LIE about, and what the
 * stream really is.  Returns 0 when the combination is not one of them.
 *
 * Kept as a candidate rather than applied unconditionally -- see the header
 * comment: "1ch 44100 Hz at 96 kbps" is both a row here and an ordinary real
 * ASF file, and this entry point serves both.
 */
static INT64 xwma_true_bit_rate( UINT32 channels, UINT32 rate, INT64 br )
{
    if (channels == 1)
    {
        if (rate == 22050 && (br == 48000 || br == 192000)) return 20000;
        if (rate == 32000 && (br == 48000 || br == 192000)) return 20000;
        if (rate == 44100 && (br == 96000 || br == 192000)) return 48000;
    }
    else if (channels == 2)
    {
        if (rate == 22050 && (br == 48000 || br == 192000)) return 32000;
        if (rate == 32000 && br == 192000) return 48000;
    }
    return 0;
}

/* The flags word libavcodec reads out of WMA v1/v2 codec-private data
 * (wmadec.c wma_decode_init).  Logged on creation because it is the single
 * most useful number for diagnosing a stream that will not decode. */
static UINT wma_flags2( enum AVCodecID id, const BYTE *ed, UINT32 n )
{
    if (id == AV_CODEC_ID_WMAV1 && n >= 4) return ed[2] | (ed[3] << 8);
    if (id == AV_CODEC_ID_WMAV2 && n >= 6) return ed[4] | (ed[5] << 8);
    return 0;
}

/***********************************************************************
 *           buffers
 */
static BOOL buffer_reserve( BYTE **buf, size_t *cap, size_t need )
{
    size_t want;
    BYTE *grown;

    if (*cap >= need) return TRUE;
    want = *cap ? *cap : 4096;
    while (want < need) want *= 2;
    if (!(grown = realloc( *buf, want ))) return FALSE;
    *buf = grown;
    *cap = want;
    return TRUE;
}

static void pcm_compact( struct wma_transform *transform )
{
    if (!transform->pcm_pos) return;
    if (transform->pcm_pos >= transform->pcm_len)
    {
        transform->pcm_pos = transform->pcm_len = 0;
        return;
    }
    memmove( transform->pcm_buf, transform->pcm_buf + transform->pcm_pos,
             transform->pcm_len - transform->pcm_pos );
    transform->pcm_len -= transform->pcm_pos;
    transform->pcm_pos = 0;
}

/***********************************************************************
 *           open_decoder
 *
 * Opens (or REOPENS) the libavcodec decoder at a given bit rate.  Everything
 * it needs is kept on the transform, because the retry path below has to be
 * able to build a second context after the media type is long gone.
 */
static int open_decoder( struct wma_transform *transform, INT64 bit_rate, int flags2_override )
{
    AVCodecContext *avctx;
    int err;

    if (transform->avctx) avcodec_free_context( &transform->avctx );
    swr_free( &transform->swr );

    if (!(avctx = avcodec_alloc_context3( transform->codec ))) return AVERROR(ENOMEM);
    avctx->sample_rate = transform->rate;
    avctx->block_align = transform->block_align;
    avctx->bit_rate = bit_rate;
    /* w2: gst-libav sets this from the caps `depth` (gstavcodecmap.c) and
     * winegstreamer puts the WAVEFORMATEX depth there, so the desktop path
     * that decodes these streams DOES pass it.  It was dropped here on the
     * grounds that no WMA decoder reads it -- true today, but matching the
     * working path exactly is worth more than being right about that. */
    avctx->bits_per_coded_sample = transform->depth;
    /* bits_per_coded_sample is deliberately NOT set from the WAVEFORMATEX:
     * wma_decoder.c's SetOutputType writes the OUTPUT sample size back into
     * the input block (`wfx->wBitsPerSample = sample_size;`), so for a float
     * output that field says 32, which is not the coded sample size.  No WMA
     * decoder in libavcodec reads it -- they take everything from extradata,
     * block_align and bit_rate -- so the honest value is none. */
    layout_from_mask( &avctx->ch_layout, transform->channel_mask, transform->in_channels );

    if (transform->extradata_size)
    {
        if (!(avctx->extradata = av_mallocz( transform->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE )))
        {
            avcodec_free_context( &avctx );
            return AVERROR(ENOMEM);
        }
        memcpy( avctx->extradata, transform->extradata, transform->extradata_size );
        avctx->extradata_size = transform->extradata_size;
        /* flags2 lives at extradata+4 for WMA v2 and at extradata+2 for WMA v1
         * (wmadec.c wma_decode_init).  A candidate may clear a bit there; the
         * transform's own copy is left untouched so each attempt starts from
         * what the caller supplied. */
        if (flags2_override >= 0)
        {
            UINT32 at = transform->codec_id == AV_CODEC_ID_WMAV2 ? 4
                      : transform->codec_id == AV_CODEC_ID_WMAV1 ? 2 : 0;
            if (at && transform->extradata_size >= at + 2)
            {
                avctx->extradata[at] = (uint8_t)(flags2_override & 0xff);
                avctx->extradata[at + 1] = (uint8_t)((flags2_override >> 8) & 0xff);
            }
        }
    }

    if ((err = avcodec_open2( avctx, transform->codec, NULL )) < 0)
    {
        avcodec_free_context( &avctx );
        return err;
    }
    transform->avctx = avctx;
    transform->bit_rate = bit_rate;
    transform->flags2_open = flags2_override >= 0 ? flags2_override
        : (int)wma_flags2( transform->codec_id, transform->extradata,
                           transform->extradata_size );
    /* A fresh decoder primes itself: wma_decode_init sets
     * avctx->internal->skip_samples to two frames and the bit reservoir starts
     * empty, so the first packet after this legitimately yields up to three
     * frames fewer than its header declares (wma_packet_ok). */
    transform->frame_slack = 3;
    return 0;
}

/***********************************************************************
 *           decode
 *
 * Converts one decoded AVFrame into the negotiated PCM format and appends it
 * to pcm_buf.  swr is built on the FIRST frame, not at open time: the decoder
 * only commits to a sample format and channel layout once it has seen a
 * packet, and using the frame's own values keeps this correct for the
 * multi-stream XMA decoders too.
 */
/* w2: DOES IT LOOK LIKE AUDIO?  libavcodec can "decode" a packet under the
 * wrong configuration -- wrong bit rate, wrong flags2 -- without returning an
 * error, and what comes out is noise at many times full scale (the device
 * census read peak=9.406 after one such packet was accepted).  A WMA
 * decoder's float output lives in [-1, 1]; anything far outside it is not a
 * quiet mistake, it is the loudest possible one.  Such a frame is rejected and
 * the caller emits silence instead, which also stops a bad candidate from
 * ever satisfying the acceptance test below.
 *
 * The DECODED frame is checked, before conversion, so a caller that asked for
 * 16-bit output is protected too: converted to s16 the noise would merely be
 * clipped to full scale, not rejected.  Integer frames (WMA Lossless) are
 * bounded by their format and are not checked. */
static BOOL frame_is_sane( const AVFrame *frame )
{
    int planes, plane, per_plane, i;

    if (frame->format == AV_SAMPLE_FMT_FLTP)
    {
        planes = frame->ch_layout.nb_channels;
        per_plane = frame->nb_samples;
    }
    else if (frame->format == AV_SAMPLE_FMT_FLT)
    {
        planes = 1;
        per_plane = frame->nb_samples * frame->ch_layout.nb_channels;
    }
    else return TRUE;

    for (plane = 0; plane < planes; plane++)
    {
        const float *f = (const float *)frame->extended_data[plane];

        for (i = 0; i < per_plane; i++)
        {
            float v = f[i] < 0.0f ? -f[i] : f[i];
            /* NaN/Inf compare false against everything, so catch them too. */
            if (!(v <= MADEIRA_WMA_SANE_PEAK)) return FALSE;
        }
    }
    return TRUE;
}

static NTSTATUS append_frame( struct wma_transform *transform, AVFrame *frame )
{
    int out_samples, converted;
    size_t need;
    uint8_t *dst;

    if (!frame_is_sane( frame ))
    {
        transform->insane_frames++;
        transform->frame_rejected = TRUE;
        return STATUS_SUCCESS;   /* not a transform error: silence */
    }

    if (!transform->swr)
    {
        AVChannelLayout in_layout = {0};
        int err;

        if (frame->ch_layout.nb_channels)
            av_channel_layout_copy( &in_layout, &frame->ch_layout );
        else
            av_channel_layout_default( &in_layout, transform->in_channels );

        err = swr_alloc_set_opts2( &transform->swr,
                &transform->out_layout, transform->out_sample_fmt, transform->rate,
                &in_layout, frame->format, frame->sample_rate ? frame->sample_rate : (int)transform->rate,
                0, NULL );
        av_channel_layout_uninit( &in_layout );
        if (err < 0 || !transform->swr)
        {
            WMA_LOG( "swr_alloc_set_opts2 failed (%d)\n", err );
            return STATUS_UNSUCCESSFUL;
        }
        if ((err = swr_init( transform->swr )) < 0)
        {
            WMA_LOG( "swr_init failed (%d)\n", err );
            swr_free( &transform->swr );
            return STATUS_UNSUCCESSFUL;
        }
    }

    /* swr_get_out_samples() accounts for whatever the converter is holding
     * back; the rate is unchanged, so this is nb_samples plus that. */
    out_samples = swr_get_out_samples( transform->swr, frame->nb_samples );
    if (out_samples <= 0) return STATUS_SUCCESS;

    need = transform->pcm_len + (size_t)out_samples * transform->out_frame_size;
    if (!buffer_reserve( &transform->pcm_buf, &transform->pcm_cap, need ))
        return STATUS_NO_MEMORY;

    dst = transform->pcm_buf + transform->pcm_len;
    converted = swr_convert( transform->swr, &dst, out_samples,
                             (const uint8_t **)frame->extended_data, frame->nb_samples );
    if (converted < 0)
    {
        WMA_LOG( "swr_convert failed (%d)\n", converted );
        return STATUS_UNSUCCESSFUL;
    }
    if (converted <= 0) return STATUS_SUCCESS;

    transform->pcm_len += (size_t)converted * transform->out_frame_size;
    transform->produced_output = TRUE;
    return STATUS_SUCCESS;
}

/* Silence of the length a packet that failed to decode represented, so the
 * decoder's byte budget keeps matching the container's (see the header
 * comment: FAudio indexes its own output buffer by the VOICE's cursor, and
 * that buffer is not zeroed). */
static NTSTATUS append_silence_for_packet( struct wma_transform *transform, size_t bytes )
{
    UINT32 frames = transform->last_frames;
    size_t need;

    /* Prefer the frame count of the last packet that DID decode -- exact for
     * the constant-geometry WMA superframes xWMA uses.  Failing that, the
     * packet's share of the stream's own byte rate, which is what a CBR
     * container's block_align encodes. */
    if (!frames && transform->avg_bytes)
        frames = (UINT32)((UINT64)bytes * transform->rate / transform->avg_bytes);
    if (!frames) return STATUS_SUCCESS;

    need = transform->pcm_len + (size_t)frames * transform->out_frame_size;
    if (!buffer_reserve( &transform->pcm_buf, &transform->pcm_cap, need ))
        return STATUS_NO_MEMORY;
    memset( transform->pcm_buf + transform->pcm_len, 0,
            (size_t)frames * transform->out_frame_size );
    transform->pcm_len += (size_t)frames * transform->out_frame_size;
    transform->silence_frames += frames;
    return STATUS_SUCCESS;
}

/***********************************************************************
 *           what a WMA v2 superframe header looks like, and what arrived
 *
 * MADEIRA 2026-09-19 (log v95).  With FFmpeg's own xWMA parameters -- flags2
 * = 31, xwma.c's normalised bit rate, the container's block_align -- EVERY
 * packet of every bit-reservoir stream failed, and the complaints libavcodec
 * printed name every field of the bitstream in turn:
 *
 *     2289  nb_frames is N bits left M          (the superframe header)
 *     1744  overflow (N > M) in spectral RLE    (the coefficient VLCs)
 *     ~3600 next/prev/block_len_bits out of range  (the block-length fields)
 *      863  frame_len overflow
 *
 * `nb_frames` is read from bits 4..7 of the packet's FIRST BYTE, before any
 * parameter-derived field width is used, so a packet whose nb_frames nibble is
 * implausible is a packet that does not START where we think it does.  That is
 * a different bug from every parameter theory, and these two helpers are how
 * the next log tells the two apart instead of inviting a third guess: the
 * first bytes of the first packets are printed verbatim, with the header
 * nibbles broken out and the bit rate those nibbles IMPLY.
 */
static UINT wma_frame_len_bits( enum AVCodecID id, UINT32 rate )
{
    /* libavcodec/wma.c ff_wma_get_frame_len_bits, for versions 1 and 2. */
    if (rate <= 16000) return 9;
    if (rate <= 22050 || (rate <= 32000 && id == AV_CODEC_ID_WMAV1)) return 10;
    return 11;
}

/* Does the decoder, as it is open now, read this stream as bit-reservoir
 * SUPERFRAMES?  Only then does a packet start with the 4-bit superframe index
 * and the 4-bit frame count that implied_bit_rate() and wma_packet_ok() read.
 * Without the reservoir flag (flags2 bit 1) -- FFmpeg's own WMA encoder, and
 * WMA v1/v2 files that were encoded that way -- a packet is ONE frame and its
 * first byte is ordinary bitstream, so reading a "frame count" out of it is
 * reading noise.  Other WMA-family codecs (Pro, Lossless, XMA) have their own
 * packet formats and never use this arithmetic. */
static BOOL wma_superframes( const struct wma_transform *transform, int flags2 )
{
    return (transform->codec_id == AV_CODEC_ID_WMAV1 || transform->codec_id == AV_CODEC_ID_WMAV2)
           && (flags2 & 0x0002);
}

/* The ladder below searches WMA v1/v2 decoder parameters (bit rate, flags2).
 * No other codec in the family reads either, so for them there is nothing to
 * search. */
static BOOL wma_searchable( const struct wma_transform *transform )
{
    return transform->codec_id == AV_CODEC_ID_WMAV1 || transform->codec_id == AV_CODEC_ID_WMAV2;
}

/* bit rate implied by "this packet holds nb_frames frames of frame_len
 * samples in block_align bytes" -- the arithmetic that independently
 * reproduces every row of xwma.c's table, so it is the honest third candidate
 * when the table has no row for a stream. */
static INT64 implied_bit_rate( struct wma_transform *transform, UINT nb_frames )
{
    UINT64 samples;

    if (!nb_frames || nb_frames > 15) return 0;
    samples = (UINT64)nb_frames << wma_frame_len_bits( transform->codec_id, transform->rate );
    if (!samples) return 0;
    return (INT64)((UINT64)transform->block_align * 8 * transform->rate / samples);
}

/* The same arithmetic over every packet header seen so far.  A bit-reservoir
 * stream's nibble swings several frames either side of its mean, so only the
 * average names the rate; packet 0 on its own names a neighbour of it. */
static INT64 implied_bit_rate_avg( struct wma_transform *transform )
{
    UINT64 samples;

    if (!transform->nibble_sum || !transform->nibble_packets) return 0;
    samples = (UINT64)transform->nibble_sum << wma_frame_len_bits( transform->codec_id, transform->rate );
    return (INT64)((UINT64)transform->block_align * 8 * transform->rate *
                   transform->nibble_packets / samples);
}

/***********************************************************************
 *           the parameter ladder
 *
 * MADEIRA 2026-09-21.  See the header comment: bit_rate and flags2 reach the
 * WMA v1/v2 decoder only through the four quantities ff_wma_init derives from
 * them, so the search enumerates those.  wma_derived() is ff_wma_init's own
 * arithmetic, kept here so two candidates that would build the SAME decoder
 * are never both tried -- that is what keeps a complete ladder short.
 */
static void wma_derived( enum AVCodecID id, UINT32 rate, UINT32 channels, INT64 bit_rate, int flags2,
                         int *byte_offset_bits, int *nb_block_sizes, int *noise,
                         int *coef_vlc_table )
{
    UINT flb = wma_frame_len_bits( id, rate );
    float bps = (float)bit_rate / (float)(channels * rate);
    float bps1 = channels == 2 ? bps * 1.6f : bps;
    /* version 2 normalises the rate the thresholds below compare against */
    UINT32 sr1 = id != AV_CODEC_ID_WMAV2 ? rate :
                 rate >= 44100 ? 44100 : (rate >= 22050 ? 22050 :
                 (rate >= 16000 ? 16000 : (rate >= 11025 ? 11025 : 8000)));
    int nb, nb_max;

    *byte_offset_bits = av_log2( (int)(bps * (1 << flb) / 8.0 + 0.5) ) + 2;

    if (flags2 & 0x0004)
    {
        nb = ((flags2 >> 3) & 3) + 1;
        if ((bit_rate / channels) >= 32000) nb += 2;
        nb_max = (int)flb - 7;   /* BLOCK_MIN_BITS */
        if (nb > nb_max) nb = nb_max;
        *nb_block_sizes = nb + 1;
    }
    else *nb_block_sizes = 1;

    *noise = 1;
    if (sr1 == 44100) { if (bps1 >= 0.61f) *noise = 0; }
    else if (sr1 == 22050) { if (bps1 >= 1.16f) *noise = 0; }
    else if (sr1 == 8000) { if (bps > 0.75f) *noise = 0; }

    *coef_vlc_table = 2;
    if (rate >= 32000)
    {
        if (bps1 < 0.72f) *coef_vlc_table = 0;
        else if (bps1 < 1.16f) *coef_vlc_table = 1;
    }
}

/* A bit rate that lands ff_wma_init on a given byte_offset_bits, so a
 * superframe-offset width no declared rate reaches is still tried before a
 * stream is given up on.  The middle of the av_log2 window, so rounding in
 * either direction stays inside it. */
static INT64 wma_rate_for_byte_offset_bits( enum AVCodecID id, UINT32 rate, UINT32 channels, int bob )
{
    double target = 1.5 * (double)(1 << (bob - 2));

    return (INT64)(target * 8.0 * channels * rate / (double)(1 << wma_frame_len_bits( id, rate )));
}

/* The bit rates an xWMA/XACT wave-bank header can declare: its average-bytes
 * table times eight.  A header that lies is still lying with one of these, and
 * each of them lands the noise-coding and coefficient-table thresholds where
 * the encoder meant them to land -- which a synthesised rate does not. */
static const INT64 wma_declared_rates[] =
    { 20000, 32000, 48000, 64000, 96000, 160000, 192000 };

static void add_candidate( struct wma_transform *transform, INT64 bit_rate, int flags2,
                           const char *why )
{
    int bob, nbs, noise, cvt;
    UINT32 i;

    if (transform->candidate_count >= MADEIRA_WMA_MAX_CANDIDATES) return;
    if (bit_rate <= 0) return;
    wma_derived( transform->codec_id, transform->rate, transform->in_channels, bit_rate, flags2,
                 &bob, &nbs, &noise, &cvt );
    /* ff_wma_init refuses byte_offset_bits + 3 > MIN_CACHE_BITS; opening such
     * a candidate would only cost a failed avcodec_open2. */
    if (bob + 3 > 25) return;

    for (i = 0; i < transform->candidate_count; i++)
    {
        int b2, n2, s2, c2;

        wma_derived( transform->codec_id, transform->rate, transform->in_channels,
                     transform->candidates[i].bit_rate, transform->candidates[i].flags2,
                     &b2, &n2, &s2, &c2 );
        if (b2 == bob && n2 == nbs && s2 == noise && c2 == cvt &&
            ((transform->candidates[i].flags2 ^ flags2) & 0x0007) == 0)
            return;
    }
    transform->candidates[transform->candidate_count].bit_rate = bit_rate;
    transform->candidates[transform->candidate_count].flags2 = flags2;
    transform->candidates[transform->candidate_count].why = why;
    transform->candidate_count++;
}

/* Every flags2 worth trying at one bit rate, in evidence order: the one the
 * caller supplied, then the block-size counts it may have invented wrongly,
 * then no block switching at all. */
static void add_flags_variants( struct wma_transform *transform, INT64 bit_rate,
                                int flags2, const char *why, const char *why_blocks )
{
    int v;

    add_candidate( transform, bit_rate, flags2, why );
    for (v = 3; v >= 0; v--)
        add_candidate( transform, bit_rate, (flags2 & ~0x18) | (v << 3), why_blocks );
    add_candidate( transform, bit_rate, flags2 & ~0x0004, "no block switching" );
}

/* Rebuild the ordered ladder.  Called again whenever the frames-per-packet
 * average has moved on, because that average is the only piece of evidence
 * that improves as packets arrive; everything already tried keeps its place,
 * since the list is regenerated from the same fixed sources in the same order
 * and the cursor into it is an index. */
static void wma_build_candidates( struct wma_transform *transform )
{
    INT64 implied = implied_bit_rate_avg( transform );
    INT64 nearest = 0;
    int flags2 = (int)wma_flags2( transform->codec_id, transform->extradata,
                                  transform->extradata_size );
    UINT32 i;
    int bob;

    transform->candidate_count = 0;

    if (implied > 0)
    {
        INT64 best = 0;

        for (i = 0; i < sizeof(wma_declared_rates) / sizeof(wma_declared_rates[0]); i++)
        {
            INT64 d = wma_declared_rates[i] - implied;

            if (d < 0) d = -d;
            if (!nearest || d < best) { best = d; nearest = wma_declared_rates[i]; }
        }
    }

    add_flags_variants( transform, transform->bit_rate, flags2,
                        "the rate the decoder was opened with",
                        "that rate with a different block-size count" );
    add_flags_variants( transform, transform->bit_rate_alt, flags2,
                        "libavformat/xwma.c's fake-rate table",
                        "that rate with a different block-size count" );
    add_flags_variants( transform, nearest, flags2,
                        "the declared rate nearest this stream's frames-per-packet average",
                        "that rate with a different block-size count" );
    add_flags_variants( transform, transform->header_rate, flags2,
                        "the rate the container declared",
                        "that rate with a different block-size count" );
    for (i = 0; i < sizeof(wma_declared_rates) / sizeof(wma_declared_rates[0]); i++)
        add_flags_variants( transform, wma_declared_rates[i], flags2,
                            "another rate a wave-bank header can declare",
                            "another declared rate with a different block-size count" );
    /* and finally whatever superframe-offset width no declared rate reached,
     * so "no configuration decodes this stream" means what it says */
    for (bob = 7; bob <= 12; bob++)
        add_flags_variants( transform,
                            wma_rate_for_byte_offset_bits( transform->codec_id, transform->rate,
                                                           transform->in_channels, bob ),
                            flags2, "an untried superframe-offset width",
                            "an untried superframe-offset width and block-size count" );
}

/***********************************************************************
 *           wma_packet_ok
 *
 * Did this packet decode, or did it merely fail to complain?  A packet
 * decoded under the right parameters yields exactly the frame count its own
 * superframe header declares -- the nibble this port already logs -- and a
 * configuration that misreads the bitstream yields a different one.  The
 * clearest case is the bit reservoir switched off: every packet then
 * "succeeds" as one independent frame, which is what the old ladder's last
 * guess did and why a stream could be accepted and then sound wrong.
 *
 * `slack` is the frames a packet may legitimately be short by: two for
 * libavcodec's own decoder priming (wma_decode_init sets
 * avctx->internal->skip_samples = 2 * frame_len, trimmed from the first output
 * after every open) plus one for a bit-reservoir restart, which happens at the
 * start of a stream and again after any failed packet.
 *
 * A nibble of zero is a packet that carries only reservoir bytes for the next
 * superframe.  It legitimately produces nothing, and libavcodec says so at
 * WARNING level rather than failing, so it is good exactly when it produced
 * nothing.
 *
 * All of that holds only for a SUPERFRAME stream (wma_superframes()).  Any
 * other packet has no frame count to check against, so it is good when it
 * decoded without an error and without a rejected frame.  Judging those by a
 * "nibble" too read their first byte as a frame count, failed nearly every
 * packet of every non-reservoir WMA v1/v2 stream, and muted them all.
 */
static BOOL wma_packet_ok( struct wma_transform *transform, int err, UINT nibble )
{
    if (err < 0 || transform->frame_rejected) return FALSE;
    if (!wma_superframes( transform, transform->flags2_open )) return TRUE;
    if (!nibble) return transform->coded_frames == 0;
    return transform->coded_frames <= nibble &&
           transform->coded_frames + transform->frame_slack >= nibble;
}

/***********************************************************************
 *           MADEIRA_WMA_DUMP=1 -- the exact bytes, for the host
 *
 * The device cannot decode these streams and the host has no copy of them, so
 * every round so far has been an argument about bytes nobody could look at.
 * With MADEIRA_WMA_DUMP=1 in Documents/madeira-env.txt each decoder writes
 * Documents/wma-dump-<n>.bin:
 *
 *   magic "MADWMA01" (8)      -- so a truncated or mixed-up file is obvious
 *   u32 codec tag             -- 0x161 &c, what the media type said
 *   u32 sample rate
 *   u32 channels
 *   u32 block_align
 *   u32 nAvgBytesPerSec       -- the value FAudio declared, fake or not
 *   u32 extradata size
 *   extradata bytes           -- MF_MT_USER_DATA verbatim
 *   then, per packet: u32 length, then that many bytes
 *
 * Capped at 64 packets: enough for a host decode to succeed or fail the same
 * way, small enough to move off a device.
 */
#define MADEIRA_WMA_DUMP_PACKETS 64

static unsigned int wma_dump_seq;

static void dump_open( struct wma_transform *transform, UINT codec_tag )
{
    const char *docs;
    char path[512];
    UINT32 head[6];
    int fd;

    transform->dump_fd = -1;
    if (!getenv( "MADEIRA_WMA_DUMP" )) return;

    docs = getenv( "MADEIRA_DOCS_DIR" );
    if (docs) snprintf( path, sizeof(path), "%s/wma-dump-%u.bin", docs, wma_dump_seq++ );
    else snprintf( path, sizeof(path), "/tmp/wma-dump-%u.bin", wma_dump_seq++ );

    if ((fd = open( path, O_WRONLY | O_CREAT | O_TRUNC, 0644 )) < 0)
    {
        WMA_LOG( "dump: cannot create %s (%d)\n", path, errno );
        return;
    }
    head[0] = codec_tag;
    head[1] = transform->rate;
    head[2] = transform->in_channels;
    head[3] = transform->block_align;
    head[4] = transform->avg_bytes;
    head[5] = transform->extradata_size;
    if (write( fd, "MADWMA01", 8 ) != 8 ||
        write( fd, head, sizeof(head) ) != (ssize_t)sizeof(head) ||
        (transform->extradata_size &&
         write( fd, transform->extradata, transform->extradata_size )
             != (ssize_t)transform->extradata_size))
    {
        WMA_LOG( "dump: short write on %s\n", path );
        close( fd );
        return;
    }
    transform->dump_fd = fd;
    WMA_LOG( "dump: writing the first %u packets to %s\n", MADEIRA_WMA_DUMP_PACKETS, path );
}

static void dump_packet_to_file( struct wma_transform *transform, const BYTE *data, size_t size )
{
    UINT32 len = (UINT32)size;

    if (transform->dump_fd < 0) return;
    if (transform->dumped_packets >= MADEIRA_WMA_DUMP_PACKETS)
    {
        close( transform->dump_fd );
        transform->dump_fd = -1;
        return;
    }
    transform->dumped_packets++;
    if (write( transform->dump_fd, &len, sizeof(len) ) != (ssize_t)sizeof(len) ||
        write( transform->dump_fd, data, size ) != (ssize_t)size)
    {
        close( transform->dump_fd );
        transform->dump_fd = -1;
    }
}

static void dump_packet_head( struct wma_transform *transform, const BYTE *data, size_t size )
{
    char hex[3 * 16 + 1];
    unsigned int i, n = size < 16 ? (unsigned int)size : 16;
    UINT nibble_hi, nibble_lo;

    for (i = 0; i < n; i++)
    {
        static const char d[] = "0123456789abcdef";
        hex[i * 3 + 0] = d[(data[i] >> 4) & 0xf];
        hex[i * 3 + 1] = d[data[i] & 0xf];
        hex[i * 3 + 2] = ' ';
    }
    hex[n * 3] = 0;

    if (!wma_superframes( transform, transform->flags2_open ))
    {
        /* one frame per packet: byte 0 is bitstream, not a header */
        WMA_LOG( "pkt#%u %zu bytes: %s| no superframe header (flags2=%#x)\n",
                 transform->packet_count, size, hex, transform->flags2_open );
        return;
    }

    /* wmadec.c: skip_bits(4) is the super-frame index, get_bits(4) is
     * nb_frames.  Bits are MSB-first, so they are the two nibbles of byte 0. */
    nibble_hi = data[0] >> 4;
    nibble_lo = data[0] & 0xf;
    WMA_LOG( "pkt#%u %zu bytes: %s| superframe index=%u nb_frames nibble=%u"
             " -> implies %d bit/s (open at %d)\n",
             transform->packet_count, size, hex, nibble_hi, nibble_lo,
             (int)implied_bit_rate( transform, nibble_lo ), (int)transform->bit_rate );
}

/* The next rung of the ladder wma_build_candidates() generated.  Every rung is
 * validated by wma_packet_ok(), so a wrong one cannot be adopted silently --
 * and every transition is logged, which is what makes the next device log an
 * answer rather than another hypothesis.
 *
 * The list is regenerated first, because the frames-per-packet average it is
 * ordered by improves with every packet header seen; regeneration is
 * deterministic and `candidate` is an index into it, so nothing already tried
 * is tried twice. */
static BOOL next_candidate( struct wma_transform *transform,
                            INT64 *bit_rate, int *flags2, const char **why )
{
    if (transform->search_off || transform->search_done || !wma_searchable( transform ))
        return FALSE;

    wma_build_candidates( transform );
    while (transform->candidate < transform->candidate_count)
    {
        struct wma_candidate *cand = &transform->candidates[transform->candidate++];

        if (cand->bit_rate == transform->bit_rate && cand->flags2 == transform->flags2_open)
            continue;
        *bit_rate = cand->bit_rate;
        *flags2 = cand->flags2;
        *why = cand->why;
        return TRUE;
    }
    transform->search_done = TRUE;
    return FALSE;
}

/* Feed one packet and drain whatever frames it produced.  Returns the
 * libavcodec status of the send. */
static int send_one_packet( struct wma_transform *transform, const BYTE *data, size_t size,
                            NTSTATUS *status )
{
    UINT32 frames = 0;
    int err;

    /* The retry path below can leave this NULL if BOTH opens fail; a decoder
     * that is gone must report that, not be called. */
    if (!transform->avctx) return AVERROR(EINVAL);
    transform->frame_rejected = FALSE;
    transform->coded_frames = 0;

    /* av_new_packet zero-fills AV_INPUT_BUFFER_PADDING_SIZE past the end,
     * which every bitstream reader in libavcodec reads past into. */
    if ((err = av_new_packet( transform->packet, size )) < 0) return err;
    memcpy( transform->packet->data, data, size );

    err = avcodec_send_packet( transform->avctx, transform->packet );
    av_packet_unref( transform->packet );
    if (err < 0 && err != AVERROR(EAGAIN)) return err;

    for (;;)
    {
        int ret = avcodec_receive_frame( transform->avctx, transform->frame );
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0)
        {
            WMA_LOG( "avcodec_receive_frame failed (%d)\n", ret );
            break;
        }
        frames += transform->frame->nb_samples;
        /* in CODED frames, which is what the packet's own superframe header
         * declares and what wma_packet_ok() checks it against */
        transform->coded_frames +=
            (UINT32)(transform->frame->nb_samples >> wma_frame_len_bits( transform->codec_id, transform->rate ));
        *status = append_frame( transform, transform->frame );
        av_frame_unref( transform->frame );
        if (*status) return 0;
    }
    if (frames) transform->last_frames = frames;
    /* A frame the sanity check threw out is a decode failure as far as the
     * caller is concerned: it must produce silence and it must not let a
     * candidate be believed. */
    if (transform->frame_rejected) return AVERROR(EILSEQ);
    return 0;
}

/* Decode every whole block_align-sized packet currently staged.  `flush_tail`
 * also submits a trailing partial packet (drain only): mid-stream a short tail
 * is the front of the next push, not a short packet. */
static NTSTATUS decode_staged( struct wma_transform *transform, BOOL flush_tail )
{
    NTSTATUS status = STATUS_SUCCESS;
    size_t offset = 0;

    while (offset < transform->in_len)
    {
        size_t avail = transform->in_len - offset;
        size_t take = transform->block_align;
        const BYTE *data;
        UINT nibble;
        BOOL ok;
        int err;

        if (avail < take)
        {
            /* A tail shorter than block_align is never a packet.  Mid-stream
             * it is the front of the next push and waits; at drain there is no
             * next push, and feeding it short earns a bare
             * "Input packet size too small" AVERROR_INVALIDDATA from wmadec
             * (which is where v95's -1094995529 came from).  Drop it. */
            if (!flush_tail) break;
            transform->short_tail_dropped += (UINT32)avail;
            offset += avail;
            break;
        }
        data = transform->in_buf + offset;

        if (transform->packet_count < 2) dump_packet_head( transform, data, take );
        dump_packet_to_file( transform, data, take );
        transform->packet_count++;

        /* Every packet header widens the evidence the ladder is ordered by,
         * whether or not this packet is the one being searched on.  Only a
         * superframe has such a header; for anything else the "nibble" is
         * bitstream and is neither counted nor judged (wma_packet_ok). */
        nibble = wma_superframes( transform, transform->flags2_open ) ? data[0] & 0xf : 0;
        if (transform->nibble_packets < MADEIRA_WMA_NIBBLE_WINDOW && nibble)
        {
            transform->nibble_sum += nibble;
            transform->nibble_packets++;
        }

        /* Muted: every candidate was tried and none produced audio.  Do not
         * keep calling a decoder that has proved it cannot decode this stream
         * -- just keep the timeline running with silence. */
        if (transform->muted)
        {
            transform->fail_count++;
            if ((status = append_silence_for_packet( transform, take ))) return status;
            offset += take;
            continue;
        }

        err = send_one_packet( transform, data, take, &status );
        if (status) return status;
        ok = wma_packet_ok( transform, err, nibble );

        /* THE PARAMETER SEARCH.  Only until a candidate is ACCEPTED: a stream
         * that has produced the frames its own headers declare, several packets
         * running, has proved its parameters, and reopening under it would
         * throw away the bit reservoir for no reason.  Each candidate is tried
         * on this same packet and kept only if that packet decodes to the right
         * length, so a wrong guess cannot be adopted; the transition is logged
         * either way so the next log names the winner instead of implying it. */
        if (ok) transform->good_packets++;
        else transform->good_packets = 0;
        if (transform->good_packets > transform->best_good)
        {
            transform->best_good = transform->good_packets;
            transform->best_rate = transform->bit_rate;
            transform->best_flags2 = transform->flags2_open;
        }

        while (!ok && !transform->accepted)
        {
            INT64 was_rate = transform->bit_rate;
            int was_flags2 = transform->flags2_open;
            INT64 bit_rate;
            const char *why;
            int flags2;

            if (!next_candidate( transform, &bit_rate, &flags2, &why ))
            {
                /* Out of rungs.  w2 showed the alternative to muting: a
                 * configuration accepted on one packet, then 90 failures and
                 * noise at +19 dB reaching the mixer.  But muting is only
                 * honest when NOTHING ever decoded -- a stream that has
                 * produced real audio and then hits a bad packet must conceal
                 * that packet and carry on, not fall silent for good. */
                if (transform->best_good)
                {
                    /* Something decoded once.  Go back to it and conceal from
                     * there rather than leaving the decoder holding whichever
                     * rung happened to be last.  Already there (no search ran,
                     * or it ended on that rung): nothing to reopen, and a
                     * reopen would only throw the bit reservoir away. */
                    if (transform->best_rate == transform->bit_rate &&
                        transform->best_flags2 == transform->flags2_open)
                        break;
                    WMA_LOG( "transform %p: ladder exhausted after %u rungs; back to "
                             "%d bit/s flags2=%#x, which decoded %u packets running\n",
                             transform, transform->candidate, (int)transform->best_rate,
                             transform->best_flags2, transform->best_good );
                    open_decoder( transform, transform->best_rate, transform->best_flags2 );
                }
                else if (!transform->muted && transform->candidate)
                {
                    /* Only a search that actually ran and found nothing
                     * mutes.  With the search off (MADEIRA_WMA_SEARCH=0), or
                     * for a codec that has no parameters to search, a packet
                     * that fails is concealed on its own and the next one is
                     * decoded as usual. */
                    transform->muted = TRUE;
                    WMA_LOG( "transform %p: no configuration decodes this stream "
                             "(%uHz %uch block=%u flags2=%#x, %u candidates tried, "
                             "%u insane frames rejected) -- MUTING: silence from here on\n",
                             transform, transform->rate, transform->in_channels,
                             transform->block_align,
                             wma_flags2( transform->codec_id, transform->extradata,
                                         transform->extradata_size ),
                             transform->candidate, transform->insane_frames );
                }
                break;
            }

            WMA_LOG( "packet %u did not decode at %d bit/s flags2=%#x; trying %d bit/s "
                     "flags2=%#x -- %s\n", transform->packet_count - 1, (int)was_rate,
                     was_flags2, (int)bit_rate, flags2, why );
            if (open_decoder( transform, bit_rate, flags2 ) < 0)
            {
                /* Put a working context back rather than leaving the transform
                 * holding a NULL decoder. */
                open_decoder( transform, was_rate, was_flags2 );
                continue;
            }
            err = send_one_packet( transform, data, take, &status );
            if (status) return status;
            if ((ok = wma_packet_ok( transform, err, nibble )))
            {
                /* PROVISIONAL, not accepted.  The packet decoded to the length
                 * its header declares, but a single packet is not proof: the
                 * candidate is confirmed only after
                 * MADEIRA_WMA_ACCEPT_PACKETS consecutive such packets, and
                 * until then a relapse moves on to the next rung. */
                transform->good_packets = 1;
                if (!transform->best_good)
                {
                    transform->best_good = 1;
                    transform->best_rate = transform->bit_rate;
                    transform->best_flags2 = transform->flags2_open;
                }
                WMA_LOG( "provisional: %d bit/s flags2=%#x (%s) decoded packet %u "
                         "into %u of the %u frames it declares\n",
                         (int)transform->bit_rate, transform->flags2_open, why,
                         transform->packet_count - 1, transform->coded_frames, nibble );
                break;
            }
        }
        if (transform->good_packets >= MADEIRA_WMA_ACCEPT_PACKETS && !transform->accepted)
        {
            transform->accepted = TRUE;
            WMA_LOG( "accepted: %d bit/s flags2=%#x after %u consecutive sane packets "
                     "(transform %p)\n", (int)transform->bit_rate, transform->flags2_open,
                     MADEIRA_WMA_ACCEPT_PACKETS, transform );
        }

        /* The next packet loses a frame to the bit-reservoir restart that any
         * failure causes; after a good one it must match its header exactly. */
        transform->frame_slack = ok ? 0 : 1;

        offset += take;

        if (!ok)
        {
            transform->fail_count++;
            if (transform->fail_logged < MADEIRA_WMA_MAX_FAIL_LOGS)
            {
                transform->fail_logged++;
                WMA_LOG( "packet %u concealed: send=%d, %u of %u declared frames, "
                         "%zu bytes at %d bit/s flags2=%#x (%uHz %uch block=%u)%s\n",
                         transform->packet_count - 1, err, transform->coded_frames, nibble,
                         take, (int)transform->bit_rate, transform->flags2_open,
                         transform->rate, transform->in_channels, transform->block_align,
                         transform->fail_logged == MADEIRA_WMA_MAX_FAIL_LOGS
                             ? " -- further failures counted only" : "" );
            }
            /* Emit silence for this packet rather than dropping it: the
             * container promised these bytes and FAudio's output buffer is not
             * zeroed (header comment).  Only when the packet produced nothing:
             * a packet that decoded to the wrong LENGTH has already put those
             * samples in the buffer, and padding them would drift the stream. */
            if (!transform->coded_frames &&
                (status = append_silence_for_packet( transform, take ))) return status;
        }
    }

    if (offset)
    {
        memmove( transform->in_buf, transform->in_buf + offset, transform->in_len - offset );
        transform->in_len -= offset;
    }
    return status;
}

static void report_failures( struct wma_transform *transform )
{
    if (!transform->fail_count && !transform->short_tail_dropped) return;
    WMA_LOG( "%u of %u packets failed to decode on transform %p (%llu frames of silence "
             "emitted in their place, %u trailing bytes dropped), %uHz %uch block=%u "
             "at %d bit/s\n",
             transform->fail_count, transform->packet_count, transform,
             (unsigned long long)transform->silence_frames, transform->short_tail_dropped,
             transform->rate, transform->in_channels, transform->block_align,
             (int)transform->bit_rate );
    transform->fail_count = 0;
    transform->fail_logged = 0;
    transform->silence_frames = 0;
    transform->short_tail_dropped = 0;
}

/***********************************************************************
 *           wg_transform_create
 */
static NTSTATUS wma_create( struct wg_transform_create_params *params )
{
    const WAVEFORMATEX *in = audio_format( &params->input_type );
    const WAVEFORMATEX *out = audio_format( &params->output_type );
    struct wma_transform *transform;
    enum AVCodecID codec_id;
    UINT in_tag, out_tag;
    UINT32 extra;
    INT64 open_rate;
    int err;

    params->transform = 0;

    if (!in || !out)
    {
        /* A malformed block, or an output that is not audio: transform_create
         * hands this kind audio inputs only. */
        return STATUS_NOT_SUPPORTED;
    }

    in_tag = format_tag( in, params->input_type.format_size );
    out_tag = format_tag( out, params->output_type.format_size );
    if ((codec_id = codec_id_from_tag( in_tag )) == AV_CODEC_ID_NONE)
    {
        WMA_LOG( "input format tag %#x is not a WMA family stream; refusing\n", in_tag );
        return STATUS_NOT_SUPPORTED;
    }
    if (out_tag != WAVE_FORMAT_PCM && out_tag != WAVE_FORMAT_IEEE_FLOAT)
    {
        WMA_LOG( "output format tag %#x is not PCM or float; refusing\n", out_tag );
        return STATUS_NOT_SUPPORTED;
    }
    if (out->nSamplesPerSec != in->nSamplesPerSec)
    {
        /* See the header comment: resampling is a different transform. */
        WMA_LOG( "refusing %u Hz -> %u Hz: this decoder does not resample\n",
                 (UINT)in->nSamplesPerSec, (UINT)out->nSamplesPerSec );
        return STATUS_NOT_SUPPORTED;
    }
    if (!in->nChannels || !in->nSamplesPerSec || !in->nBlockAlign || !out->nChannels)
        return STATUS_INVALID_PARAMETER;
    if (out_tag == WAVE_FORMAT_PCM && out->wBitsPerSample != 16)
    {
        WMA_LOG( "refusing %u-bit integer PCM output (only 16-bit and float32 are produced)\n",
                 (UINT)out->wBitsPerSample );
        return STATUS_NOT_SUPPORTED;
    }
    if (out_tag == WAVE_FORMAT_IEEE_FLOAT && out->wBitsPerSample != 32)
        return STATUS_NOT_SUPPORTED;

    /* Route libavcodec's own diagnostics through this file's tag (see
     * wma_av_log): they name the field of the bitstream that failed, which is
     * the only thing that distinguishes wrong parameters from wrong bytes. */
    pthread_once( &wma_av_log_once, wma_install_av_log );

    if (!(transform = calloc( 1, sizeof(*transform) ))) return STATUS_NO_MEMORY;
    pthread_mutex_init( &transform->lock, NULL );
    transform->magic = MADEIRA_WG_TRANSFORM_MAGIC;
    transform->dump_fd = -1;
    transform->codec_id = codec_id;
    transform->block_align = in->nBlockAlign;
    transform->rate = in->nSamplesPerSec;
    transform->in_channels = in->nChannels;
    transform->avg_bytes = in->nAvgBytesPerSec;
    transform->depth = in->wBitsPerSample;
    transform->channel_mask = channel_mask( in, params->input_type.format_size );
    transform->out_channels = out->nChannels;
    transform->out_sample_fmt = (out_tag == WAVE_FORMAT_IEEE_FLOAT) ? AV_SAMPLE_FMT_FLT
                                                                    : AV_SAMPLE_FMT_S16;
    transform->out_frame_size = out->nChannels * (out->wBitsPerSample / 8);
    layout_from_mask( &transform->out_layout,
                      channel_mask( out, params->output_type.format_size ), out->nChannels );

    transform->out_format_size = params->output_type.format_size;
    if (!(transform->out_format = malloc( transform->out_format_size )))
        goto nomem;
    memcpy( transform->out_format, out, transform->out_format_size );

    /* The codec private data is the cbSize bytes that follow the WAVEFORMATEX
     * -- for WMA that is the decoder's flags/superframe configuration, and the
     * decoder refuses to open without it.  Kept on the transform because the
     * bit-rate retry has to reopen with it. */
    extra = in->cbSize;
    if (extra > params->input_type.format_size - sizeof(WAVEFORMATEX))
        extra = params->input_type.format_size - sizeof(WAVEFORMATEX);
    if (extra)
    {
        if (!(transform->extradata = malloc( extra ))) goto nomem;
        memcpy( transform->extradata, (const BYTE *)in + sizeof(WAVEFORMATEX), extra );
        transform->extradata_size = extra;
    }

    if (!(transform->codec = avcodec_find_decoder( codec_id )))
    {
        WMA_LOG( "libavcodec has no decoder for codec id %d (tag %#x)\n", codec_id, in_tag );
        goto unsupported;
    }
    if (!(transform->frame = av_frame_alloc())) goto nomem;
    if (!(transform->packet = av_packet_alloc())) goto nomem;

    transform->bit_rate_alt = xwma_true_bit_rate( in->nChannels, in->nSamplesPerSec,
                                                  (INT64)in->nAvgBytesPerSec * 8 );
    transform->header_rate = (INT64)in->nAvgBytesPerSec * 8;
    /* ml1120: MADEIRA_WMA_SEARCH=0 pins the decoder to the rate and flags this
     * file worked out from the media type alone, which is what shipped before
     * the ladder.  A packet it cannot decode is then concealed with silence
     * of that packet's length; the decoder is never muted for good. */
    {
        const char *v = getenv( "MADEIRA_WMA_SEARCH" );
        transform->search_off = v && v[0] == '0';
    }

    open_rate = (INT64)in->nAvgBytesPerSec * 8;
    /* HOST-VERIFIED (real wave-bank streams fed through this same libavcodec,
     * packet by packet): for the combinations in xwma_true_bit_rate() the rate
     * in the header decodes 0 packets in 600 and the table's rate decodes all
     * of them.  The ambiguity that kept this a mere candidate -- the same
     * triple can be an honest ASF stream -- does not exist when the codec
     * private data is the synthetic blob an xWMA caller makes up (all zero
     * but flags2): a real ASF header never looks like that.  So open such a
     * stream at the true rate, and leave the header's rate as the candidate.
     *
     * Only for a bit-reservoir stream (flags2 bit 1): every xWMA stream is one
     * (the synthetic flags2 is 31), while a stream of single-frame packets
     * with zeroed codec data -- FFmpeg's own wmav2 encoder writes exactly
     * that -- is honest about its rate, and a single-frame packet decoded at
     * the wrong one is wrong audio, not a failure the ladder could see. */
    if (transform->bit_rate_alt && codec_id == AV_CODEC_ID_WMAV2 && extra >= 6 &&
        (wma_flags2( codec_id, transform->extradata, extra ) & 0x0002))
    {
        BOOL synthetic = TRUE;
        UINT32 k;
        for (k = 0; k < extra; k++)
            if (k != 4 && k != 5 && transform->extradata[k]) synthetic = FALSE;
        if (synthetic)
        {
            INT64 header_rate = open_rate;
            open_rate = transform->bit_rate_alt;
            transform->bit_rate_alt = header_rate;
        }
    }

    if ((err = open_decoder( transform, open_rate, -1 )) < 0)
    {
        WMA_LOG( "avcodec_open2(%s) failed (%d) at %d bit/s\n", transform->codec->name, err,
                 (int)open_rate );
        goto unsupported;
    }

    dump_open( transform, in_tag );
    params->transform = (wg_transform_t)(UINT_PTR)transform;
    WMA_LOG( "decoder created fmt=%s tag=%#x %uHz %uch block=%u avg=%uB/s bitrate=%d"
             " extradata=%u flags2=%#x -> pcm %s %uHz %uch %ubit (transform %p)%s\n",
             transform->codec->name, in_tag, (UINT)in->nSamplesPerSec, (UINT)in->nChannels,
             (UINT)in->nBlockAlign, (UINT)in->nAvgBytesPerSec, (int)transform->bit_rate,
             extra, wma_flags2( codec_id, transform->extradata, extra ),
             transform->out_sample_fmt == AV_SAMPLE_FMT_FLT ? "float32" : "s16",
             (UINT)out->nSamplesPerSec, (UINT)out->nChannels, (UINT)out->wBitsPerSample,
             transform,
             transform->search_off ? " [ladder off: MADEIRA_WMA_SEARCH=0]"
                                   : " [ladder armed]" );
    return STATUS_SUCCESS;

nomem:
    err = STATUS_NO_MEMORY;
    goto fail;
unsupported:
    err = STATUS_NOT_SUPPORTED;
fail:
    if (transform->avctx) avcodec_free_context( &transform->avctx );
    if (transform->frame) av_frame_free( &transform->frame );
    if (transform->packet) av_packet_free( &transform->packet );
    av_channel_layout_uninit( &transform->out_layout );
    free( transform->extradata );
    free( transform->out_format );
    pthread_mutex_destroy( &transform->lock );
    transform->magic = 0;
    free( transform );
    return (NTSTATUS)err;
}

static NTSTATUS wma_destroy( wg_transform_t handle )
{
    struct wma_transform *transform = get_wma_transform( handle );

    if (!transform) return STATUS_INVALID_HANDLE;

    pthread_mutex_lock( &transform->lock );
    report_failures( transform );
    transform->magic = 0;
    if (transform->dump_fd >= 0) close( transform->dump_fd );
    if (transform->swr) swr_free( &transform->swr );
    if (transform->avctx) avcodec_free_context( &transform->avctx );
    if (transform->frame) av_frame_free( &transform->frame );
    if (transform->packet) av_packet_free( &transform->packet );
    av_channel_layout_uninit( &transform->out_layout );
    free( transform->extradata );
    free( transform->out_format );
    free( transform->in_buf );
    free( transform->pcm_buf );
    pthread_mutex_unlock( &transform->lock );
    pthread_mutex_destroy( &transform->lock );
    free( transform );
    return STATUS_SUCCESS;
}

/***********************************************************************
 *           push / read
 *
 * `data` is passed separately from `sample` because struct wg_sample's `data`
 * member is a GUEST address for a 32-bit caller (it is a UINT64 field holding
 * a PE-side pointer); the wow64 thunk converts it with ios_wow_host_ptr() and
 * the 64-bit entry just widens it.  Everything else in struct wg_sample has
 * the same layout in both builds -- pts/duration are INT64/UINT64 and i386
 * aligns them to 8 like the host does -- so the OUT fields are written through
 * the caller's own struct.
 */
static NTSTATUS wma_push_data( wg_transform_t handle, struct wg_sample *sample,
                             const void *data, HRESULT *result )
{
    struct wma_transform *transform = get_wma_transform( handle );
    NTSTATUS status;

    if (!transform || !sample) return STATUS_INVALID_HANDLE;
    /* No fake success: bytes with nowhere to read
     * them from is a caller bug, and quietly accepting them would look like a
     * decoder that swallows audio. */
    if (sample->size && !data) return STATUS_INVALID_PARAMETER;

    pthread_mutex_lock( &transform->lock );

    /* MFT back-pressure: refuse new input while a decoded buffer is still
     * waiting, so ProcessInput/ProcessOutput alternate the way the caller's
     * loop expects instead of letting pcm_buf grow without bound. */
    if (transform->pcm_len > transform->pcm_pos)
    {
        *result = MF_E_NOTACCEPTING;
        pthread_mutex_unlock( &transform->lock );
        return STATUS_SUCCESS;
    }

    /* v95: PROVE THE PHASE.  The staged FIFO means this file's failure lines
     * always report a block_align-sized cut whatever the caller pushed, so the
     * push size itself has to be logged or a re-phasing caller is invisible.
     * (wma_decoder.c's transform_ProcessInput already drops any sample whose
     * length is not a multiple of block_align -- "WMA transform uses fixed
     * size input samples and ignores samples with invalid sizes" -- so this
     * should always be a multiple; the log is what turns "should" into
     * "does".) */
    /* ml1120: two, not eight.  A cutscene opens a dozen of these decoders at
     * once and eight lines each is most of a device log's WMA section for no
     * diagnosis -- the phase question these lines answer is settled by the
     * first one, and MADEIRA_DIAG=1 still prints every one of them. */
    if (transform->push_count < 2)
        WMA_LOG( "push #%u size=%u fifo=%zu block=%u pkts=%u transform=%p%s\n",
                 transform->push_count, (UINT)sample->size, transform->in_len,
                 transform->block_align, transform->packet_count, transform,
                 (sample->size % transform->block_align) ? "  <-- NOT a multiple of block_align" : "" );
    transform->push_count++;

    if (sample->size && data)
    {
        if (!buffer_reserve( &transform->in_buf, &transform->in_cap,
                             transform->in_len + sample->size ))
        {
            pthread_mutex_unlock( &transform->lock );
            return STATUS_NO_MEMORY;
        }
        memcpy( transform->in_buf + transform->in_len, data, sample->size );
        transform->in_len += sample->size;
    }

    if (!transform->have_pts && (sample->flags & WG_SAMPLE_FLAG_HAS_PTS))
    {
        transform->pts = sample->pts;
        transform->have_pts = TRUE;
    }
    if (sample->flags & WG_SAMPLE_FLAG_DISCONTINUITY) transform->discontinuity = TRUE;

    transform->draining = FALSE;
    pcm_compact( transform );
    status = decode_staged( transform, FALSE );
    pthread_mutex_unlock( &transform->lock );

    *result = status ? E_FAIL : S_OK;
    return status ? status : STATUS_SUCCESS;
}

static NTSTATUS wma_read_data( wg_transform_t handle, struct wg_sample *sample,
                             void *data, HRESULT *result )
{
    struct wma_transform *transform = get_wma_transform( handle );
    size_t avail, copy, frames;

    if (!transform || !sample) return STATUS_INVALID_HANDLE;
    /* Consuming PCM into a buffer that does not exist would lose it silently. */
    if (sample->max_size && !data) return STATUS_INVALID_PARAMETER;

    pthread_mutex_lock( &transform->lock );
    avail = transform->pcm_len - transform->pcm_pos;
    if (!avail)
    {
        sample->size = 0;
        pthread_mutex_unlock( &transform->lock );
        *result = MF_E_TRANSFORM_NEED_MORE_INPUT;
        return STATUS_SUCCESS;
    }

    copy = avail < sample->max_size ? avail : sample->max_size;
    /* Never hand back a partial PCM frame: a caller that treats size/frame
     * size as a sample count would silently shear the channel interleave. */
    copy -= copy % transform->out_frame_size;
    if (!copy)
    {
        sample->size = 0;
        pthread_mutex_unlock( &transform->lock );
        *result = MF_E_TRANSFORM_NEED_MORE_INPUT;
        return STATUS_SUCCESS;
    }

    memcpy( data, transform->pcm_buf + transform->pcm_pos, copy );
    sample->size = copy;
    frames = copy / transform->out_frame_size;

    sample->flags &= ~(WG_SAMPLE_FLAG_INCOMPLETE | WG_SAMPLE_FLAG_HAS_PTS |
                       WG_SAMPLE_FLAG_HAS_DURATION | WG_SAMPLE_FLAG_DISCONTINUITY);
    sample->flags |= WG_SAMPLE_FLAG_SYNC_POINT;
    if (transform->have_pts)
    {
        sample->flags |= WG_SAMPLE_FLAG_HAS_PTS;
        sample->pts = transform->pts;
    }
    sample->flags |= WG_SAMPLE_FLAG_HAS_DURATION;
    sample->duration = (UINT64)frames * 10000000 / transform->rate;
    transform->pts += (INT64)sample->duration;
    if (transform->discontinuity)
    {
        sample->flags |= WG_SAMPLE_FLAG_DISCONTINUITY;
        transform->discontinuity = FALSE;
    }

    transform->pcm_pos += copy;
    if (transform->pcm_pos < transform->pcm_len)
        sample->flags |= WG_SAMPLE_FLAG_INCOMPLETE;
    else
        pcm_compact( transform );

    pthread_mutex_unlock( &transform->lock );
    *result = S_OK;
    return STATUS_SUCCESS;
}

/***********************************************************************
 *           output type
 */
static NTSTATUS wma_get_output_type( wg_transform_t handle, struct wg_media_type *type )
{
    struct wma_transform *transform = get_wma_transform( handle );
    UINT32 size;

    if (!transform) return STATUS_INVALID_HANDLE;

    pthread_mutex_lock( &transform->lock );
    size = transform->out_format_size;
    type->major = madeira_MFMediaType_Audio;

    /* Two-phase, as main.c's wg_transform_get_output_type() expects: the first
     * call carries a NULL format and only learns the size. */
    if (!type->u.format || type->format_size < size)
    {
        type->format_size = size;
        pthread_mutex_unlock( &transform->lock );
        return STATUS_BUFFER_TOO_SMALL;
    }
    memcpy( type->u.format, transform->out_format, size );
    type->format_size = size;
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

static NTSTATUS wma_set_output_type( wg_transform_t handle, const struct wg_media_type *type )
{
    struct wma_transform *transform = get_wma_transform( handle );
    const WAVEFORMATEX *out = audio_format( type );
    enum AVSampleFormat sample_fmt;
    AVChannelLayout layout = {0};
    BYTE *copy;
    UINT tag;

    if (!transform) return STATUS_INVALID_HANDLE;
    if (!out) return STATUS_NOT_SUPPORTED;

    tag = format_tag( out, type->format_size );
    if (tag == WAVE_FORMAT_IEEE_FLOAT && out->wBitsPerSample == 32)
        sample_fmt = AV_SAMPLE_FMT_FLT;
    else if (tag == WAVE_FORMAT_PCM && out->wBitsPerSample == 16)
        sample_fmt = AV_SAMPLE_FMT_S16;
    else
        return STATUS_NOT_SUPPORTED;
    if (out->nSamplesPerSec != transform->rate || !out->nChannels) return STATUS_NOT_SUPPORTED;

    if (!(copy = malloc( type->format_size ))) return STATUS_NO_MEMORY;
    memcpy( copy, out, type->format_size );
    layout_from_mask( &layout, channel_mask( out, type->format_size ), out->nChannels );

    pthread_mutex_lock( &transform->lock );
    /* Anything already converted is in the OLD format; the caller is asking
     * for a different one, so it cannot be delivered. */
    swr_free( &transform->swr );
    transform->pcm_pos = transform->pcm_len = 0;
    av_channel_layout_uninit( &transform->out_layout );
    transform->out_layout = layout;
    transform->out_sample_fmt = sample_fmt;
    transform->out_channels = out->nChannels;
    transform->out_frame_size = out->nChannels * (out->wBitsPerSample / 8);
    free( transform->out_format );
    transform->out_format = copy;
    transform->out_format_size = type->format_size;
    pthread_mutex_unlock( &transform->lock );

    WMA_LOG( "output type set to %s %uHz %uch %ubit (transform %p)\n",
             sample_fmt == AV_SAMPLE_FMT_FLT ? "float32" : "s16",
             (UINT)out->nSamplesPerSec, (UINT)out->nChannels, (UINT)out->wBitsPerSample,
             transform );
    return STATUS_SUCCESS;
}

/***********************************************************************
 *           the WMA kind's remaining entries
 */
static NTSTATUS wma_get_status( wg_transform_t handle, UINT32 *accepts_input )
{
    struct wma_transform *transform = get_wma_transform( handle );

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    *accepts_input = (transform->pcm_len == transform->pcm_pos);
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

static NTSTATUS wma_drain( wg_transform_t handle )
{
    struct wma_transform *transform = get_wma_transform( handle );
    NTSTATUS status;

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    WMA_LOG( "drain: transform=%p after %u packets\n", transform, transform->packet_count );
    transform->draining = TRUE;
    status = decode_staged( transform, TRUE );
    if (!status && transform->avctx)
    {
        /* Flush the decoder's own lookahead, then the converter's. */
        int err;
        avcodec_send_packet( transform->avctx, NULL );
        for (;;)
        {
            err = avcodec_receive_frame( transform->avctx, transform->frame );
            if (err < 0) break;
            status = append_frame( transform, transform->frame );
            av_frame_unref( transform->frame );
            if (status) break;
        }
        avcodec_flush_buffers( transform->avctx );
    }
    report_failures( transform );
    pthread_mutex_unlock( &transform->lock );
    return status;
}

static NTSTATUS wma_flush( wg_transform_t handle )
{
    struct wma_transform *transform = get_wma_transform( handle );

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    report_failures( transform );
    WMA_LOG( "flush: transform=%p after %u packets (%u pushes)\n",
             transform, transform->packet_count, transform->push_count );
    transform->in_len = 0;
    transform->pcm_pos = transform->pcm_len = 0;
    transform->have_pts = FALSE;
    transform->pts = 0;
    transform->draining = FALSE;
    transform->discontinuity = TRUE;
    /* avcodec_flush_buffers empties the bit reservoir and re-arms the decoder
     * priming, so the first packet after a flush is short for the same reasons
     * a freshly opened decoder's is (wma_packet_ok). */
    transform->frame_slack = 3;
    if (transform->avctx) avcodec_flush_buffers( transform->avctx );
    swr_free( &transform->swr );
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

/* Every audio input is this kind's to judge: wma_create refuses, and logs, a
 * format tag that is not a WMA family stream, exactly as it did when it was
 * the only kind. */
static BOOL wma_claims( const struct wg_transform_create_params *params )
{
    return IsEqualGUID( &params->input_type.major, &madeira_MFMediaType_Audio );
}

/***********************************************************************
 *           the WMV decoder   (MADEIRA, 2026-11-20)
 *
 * WHY THIS EXISTS
 * ---------------
 * Sabbat of the Witch, a 32-bit KiriKiri title, plays its cutscenes through
 * krmovie.dll: compressed WMV3 samples from IWMSyncReader
 * (SetReadStreamSamples), decoded by the WMVideo Decoder DMO
 * (CLSID_CWMVDecMediaObject) in a DirectShow DMO-wrapper graph.  In Wine
 * that DMO, and its MFT face, is wmv_decoder_create() in
 * dlls/winegstreamer/video_decoder.c (what upstream once had as
 * wmv_decoder.c), a wg_transform user -- and this file refused every video
 * transform.  The DMO could not even be created (its constructor probes a
 * WMV3 -> I420 transform), so the cutscenes were a white screen.  The
 * compressed ASF output of the parser and the reader's side are separate
 * pieces; this is the decoder.
 *
 * WHAT video_decoder.c DOES WITH ITS wg_transform
 * ------------------------------------------------
 *   create       check_video_transform_support() in wmv_decoder_create():
 *                WMV3 1920x1080 -> I420 with NO codec private data, created
 *                and destroyed at once.  Then for real from the DMO's
 *                SetOutputType (DMO_MEDIA_TYPE -> IMFMediaType ->
 *                MFVIDEOFORMAT, wg_transform_create_quartz) or the MFT's.
 *                The VIDEOINFOHEADER's extra bytes -- the sequence header --
 *                arrive as MF_MT_USER_DATA after the MFVIDEOFORMAT.  attrs:
 *                input_queue_length 15 and preserve_timestamps; never
 *                allow_format_change or output_plane_align.
 *   set_output_type  the MFT's SetOutputType once a transform exists.  The
 *                DMO makes a new transform instead, also when the DMO
 *                wrapper meets a sample with a new media type (qasf
 *                dmowrapper.c get_output_samples), and a new transform is a
 *                new decoder that waits for a keyframe.
 *   push_data    one compressed frame per sample; MF_E_NOTACCEPTING when the
 *                queue is full.
 *   read_data    one whole picture into the caller's buffer: the DMO's
 *                IMediaBuffer (no stride) or the MFT's sample (a 2D buffer's
 *                pitch in wg_sample.stride).  Nothing ready is
 *                MF_E_TRANSFORM_NEED_MORE_INPUT, which the DMO answers with
 *                S_FALSE and dwStatus 0.  WG_SAMPLE_FLAG_INCOMPLETE would
 *                become DMO_OUTPUT_DATA_BUFFERF_INCOMPLETE, for which the DMO
 *                wrapper calls ProcessOutput again, and again: a picture is
 *                never split, so it is never set.
 *   drain, flush the MFT's COMMAND_DRAIN / COMMAND_FLUSH, the DMO's Flush.
 *                The DMO never drains (its Discontinuity is a no-op), so a
 *                picture the decoder holds back comes out only with the next
 *                input, as it does with GStreamer.
 *   get_status, get_output_type, notify_qos  not used for WMV
 *                (get_output_type follows MF_E_TRANSFORM_STREAM_CHANGE, which
 *                needs allow_format_change); implemented all the same.
 *
 * HOW
 * ---
 * The decoder is wg_parser_av_ios.c's libavcodec backend (mav_lavc_video:
 * wmv1, wmv2, wmv3, vc1, one thread), and pictures are written by that
 * file's mav_convert_picture, so the parser and this transform share one
 * decoder setup and one set of conversions.  As in wg_transform.c, push only
 * queues the compressed frame and read decodes until a picture comes out:
 * the queue limit counts compressed frames, and no more pictures are held
 * than the decoder's own delay.
 *
 * Layout: the frame is the output MFVIDEOFORMAT's dwWidth x dwHeight in
 * wg_transform.c's plane layout (wg_format_get_stride(): 4-byte aligned rows,
 * except NV12 at 2), or at the stride of the caller's 2D buffer.
 * MFVideoFlag_BottomUpLinearRep flips it.  A MinimumDisplayAperture smaller
 * than the frame is where the picture goes; the rest is left alone.  A
 * picture is never scaled: one of another size is cropped, or padded with
 * black (GStreamer would fail to negotiate), unless the caller allowed a
 * format change, in which case read_data returns
 * MF_E_TRANSFORM_STREAM_CHANGE once and get_output_type the new size.
 *
 * Timestamps: a picture carries the pts and duration of the sample it was
 * coded in (libavcodec reorders them with the pictures), with
 * WG_SAMPLE_FLAG_PRESERVE_TIMESTAMPS when the caller asked for that, which
 * is what video_decoder.c relies on.  A picture whose sample had no time
 * follows the previous picture (the first at 0) and lasts one frame at the
 * input type's frame rate (0 without one): the native DMO reports time 0
 * for a stream pushed without times.  Every picture is a sync point with a
 * time and a duration, as the native DMO's are.
 *
 * WMV3 / VC-1 WITHOUT A SEQUENCE HEADER.  libavcodec cannot open wmv3 or vc1
 * without codec private data (AVERROR_INVALIDDATA, checked on the host), and
 * wmv_decoder_create()'s probe has none.  Refusing it would make the DMO
 * impossible to create, so create succeeds with the decoder closed when the
 * input type has NO codec private data, and says so; what is pushed into
 * such a transform is dropped, counted and logged, and nothing comes out.
 * A sequence header that is present but refused refuses create.
 *
 * MADEIRA_WG_WMV_TRANSFORM=0 restores the refusal of every video transform.
 * Log tag "[wmv]": one line per create, capped like "[wma]".
 */
#define MADEIRA_WG_WMV_MAGIC 0x574d5644   /* 'WMVD' */

#define MADEIRA_WMV_MAX_LOGS 100
#define MADEIRA_WMV_MAX_ERROR_LOGS 4      /* per transform: rejected frames */
#define MADEIRA_WMV_MAX_CODEC_DATA (1u << 20)

/* MFVideoFormat_RGB32 and its kin keep a D3DFORMAT in Data1; d3d9types.h is
 * not included here. */
#define WMV_D3DFMT_R8G8B8   20
#define WMV_D3DFMT_A8R8G8B8 21
#define WMV_D3DFMT_X8R8G8B8 22
#define WMV_D3DFMT_R5G6B5   23
#define WMV_D3DFMT_X1R5G5B5 24
#define WMV_D3DFMT_A8B8G8R8 32

/* The 32-bit PE layout of MFVIDEOFORMAT is the host's (i686-w64-mingw32 and
 * this build agree, checked with llvm-mingw), so the wow64 thunks hand the
 * guest's block over in place, as they do a WAVEFORMATEX. */
C_ASSERT( sizeof(MFVIDEOFORMAT) == 176 );
C_ASSERT( offsetof(MFVIDEOFORMAT, videoInfo.FramesPerSecond) == 48 );
C_ASSERT( offsetof(MFVIDEOFORMAT, videoInfo.MinimumDisplayAperture) == 76 );
C_ASSERT( offsetof(MFVIDEOFORMAT, videoInfo.VideoFlags) == 112 );
C_ASSERT( offsetof(MFVIDEOFORMAT, guidFormat) == 120 );
C_ASSERT( offsetof(MFVIDEOFORMAT, surfaceInfo.Palette) == 168 );

static const GUID madeira_MFMediaType_Video =
    { 0x73646976, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

static unsigned int wmv_log_count;

#define WMV_LOG( fmt, ... )                                                          \
    do {                                                                             \
        unsigned int _n = __atomic_add_fetch( &wmv_log_count, 1, __ATOMIC_RELAXED ); \
        if (_n <= MADEIRA_WMV_MAX_LOGS)                                              \
            dprintf( 2, "[wmv] " fmt, ## __VA_ARGS__ );                              \
        else if (_n == MADEIRA_WMV_MAX_LOGS + 1)                                     \
            dprintf( 2, "[wmv] further lines suppressed after %u "                    \
                        "(MADEIRA_DIAG=1 removes the cap)\n",                         \
                     (unsigned int)MADEIRA_WMV_MAX_LOGS );                           \
        else if (wma_diag_on())                                                      \
            dprintf( 2, "[wmv] " fmt, ## __VA_ARGS__ );                              \
    } while (0)

struct wmv_packet
{
    BYTE *data;
    UINT32 size;
    UINT32 flags;           /* the sample's WG_SAMPLE_FLAG_* */
    INT64 pts, duration;    /* 100 ns; INT64_MIN: the sample had none */
};

struct wmv_picture
{
    void *frame;            /* mav_lavc_video's copy of the picture */
    INT64 pts, duration;    /* as the decoder hands them back; INT64_MIN: none */
};

struct wmv_transform
{
    UINT32 magic;
    pthread_mutex_t lock;
    struct wg_transform_attrs attrs;

    int codec;              /* MAV_LAVC_* */
    const char *name;       /* the input FourCC, for the log */
    void *dec;              /* the mav_lavc_video decoder; NULL: no sequence header (see above) */
    UINT32 width, height;   /* coded size, from the input type */
    INT64 frame_duration;   /* 100 ns, from the input type's frame rate; 0 without one */
    int bt709;

    /* the output type exactly as it was set, and its pixel format */
    MFVIDEOFORMAT *out_format;
    UINT32 out_format_size;
    enum mav_pixel_format out_fmt;

    struct wmv_packet *packets;     /* compressed, oldest first */
    UINT32 packet_count, packet_cap;
    struct wmv_picture *pictures;   /* decoded, in presentation order */
    UINT32 picture_count, picture_cap;

    BOOL draining;
    BOOL discontinuity;     /* the next picture is delivered with WG_SAMPLE_FLAG_DISCONTINUITY */
    INT64 next_pts;         /* where a picture without a time goes */

    /* for the log */
    UINT32 pushed, delivered, rejected, rejected_logged, dropped, lost;
    BOOL size_logged, stride_logged;
};

/* MADEIRA_WG_WMV_TRANSFORM=0 refuses every video transform again, as before
 * this decoder existed: the WMVideo Decoder DMO and MFT then cannot be
 * created (read once). */
static BOOL wmv_transform_switch_on(void)
{
    static int on = -1;
    int v = __atomic_load_n( &on, __ATOMIC_RELAXED );

    if (v < 0)
    {
        const char *e = getenv( "MADEIRA_WG_WMV_TRANSFORM" );
        v = !(e && e[0] == '0' && !e[1]);
        __atomic_store_n( &on, v, __ATOMIC_RELAXED );
    }
    return v;
}

static struct wmv_transform *get_wmv_transform( wg_transform_t handle )
{
    struct wmv_transform *transform = (struct wmv_transform *)(UINT_PTR)handle;

    if (!transform || transform->magic != MADEIRA_WG_WMV_MAGIC) return NULL;
    return transform;
}

static const MFVIDEOFORMAT *video_format( const struct wg_media_type *type )
{
    if (!IsEqualGUID( &type->major, &madeira_MFMediaType_Video )) return NULL;
    if (!type->u.video || type->format_size < sizeof(MFVIDEOFORMAT)) return NULL;
    return type->u.video;
}

/* For the log: a FourCC, or the subtype's first field. */
static const char *wmv_subtype_name( const GUID *subtype, char buf[16] )
{
    UINT tag;
    int i;

    if (madeira_subtype_tag( subtype, &tag ))
    {
        for (i = 0; i < 4; i++)
        {
            char c = (char)(tag >> (8 * i));
            if (c < 0x20 || c > 0x7e) break;
            buf[i] = c;
        }
        if (i == 4)
        {
            buf[4] = 0;
            return buf;
        }
    }
    snprintf( buf, 16, "%#x", (unsigned int)subtype->Data1 );
    return buf;
}

static int wmv_input_codec( const GUID *subtype, const char **name )
{
    UINT tag;

    if (!madeira_subtype_tag( subtype, &tag )) return 0;
    switch (tag)
    {
    case MAKEFOURCC('W','M','V','1'): *name = "WMV1"; return MAV_LAVC_WMV1;
    case MAKEFOURCC('W','M','V','2'): *name = "WMV2"; return MAV_LAVC_WMV2;
    case MAKEFOURCC('W','M','V','3'): *name = "WMV3"; return MAV_LAVC_WMV3;
    case MAKEFOURCC('W','M','V','A'): *name = "WMVA"; return MAV_LAVC_VC1;
    case MAKEFOURCC('W','V','C','1'): *name = "WVC1"; return MAV_LAVC_VC1;
    default:                          return 0;
    }
}

/* The uncompressed formats video_decoder.c offers for WMV that GStreamer
 * could produce too (wg_media_type.c subtype_to_gst_video_format): NV11 and
 * RGB8 are refused there, and here. */
static enum mav_pixel_format wmv_output_format( const GUID *subtype )
{
    UINT tag;

    if (!madeira_subtype_tag( subtype, &tag )) return MAV_PIX_UNKNOWN;
    switch (tag)
    {
    case MAKEFOURCC('N','V','1','2'): return MAV_PIX_NV12;
    case MAKEFOURCC('Y','V','1','2'): return MAV_PIX_YV12;
    case MAKEFOURCC('I','4','2','0'):
    case MAKEFOURCC('I','Y','U','V'): return MAV_PIX_I420;
    case MAKEFOURCC('Y','U','Y','2'): return MAV_PIX_YUY2;
    case MAKEFOURCC('U','Y','V','Y'): return MAV_PIX_UYVY;
    case MAKEFOURCC('Y','V','Y','U'): return MAV_PIX_YVYU;
    case WMV_D3DFMT_X8R8G8B8:         return MAV_PIX_BGRx;
    case WMV_D3DFMT_A8R8G8B8:         return MAV_PIX_BGRA;
    case WMV_D3DFMT_A8B8G8R8:         return MAV_PIX_RGBA;
    case WMV_D3DFMT_R8G8B8:           return MAV_PIX_BGR;
    case WMV_D3DFMT_R5G6B5:           return MAV_PIX_RGB16;
    case WMV_D3DFMT_X1R5G5B5:         return MAV_PIX_RGB15;
    default:                          return MAV_PIX_UNKNOWN;
    }
}

/* The codec private data: the MF_MT_USER_DATA bytes that
 * MFCreateMFVideoFormatFromMFMediaType appends, after the palette if there
 * is one (mfplat reads them back the same way). */
static const BYTE *video_user_data( const MFVIDEOFORMAT *format, UINT32 format_size, UINT32 *size )
{
    UINT64 start = sizeof(*format);

    if (format->surfaceInfo.PaletteEntries)
        start = offsetof( MFVIDEOFORMAT, surfaceInfo.Palette )
                + ((UINT64)format->surfaceInfo.PaletteEntries + 1) * sizeof(MFPaletteEntry);
    *size = start < format_size ? format_size - (UINT32)start : 0;
    return *size ? (const BYTE *)format + start : NULL;
}

/* Makes `type` the output, keeping a verbatim copy for get_output_type.  A
 * frame size of 0 means the coded size. */
static NTSTATUS wmv_set_output( struct wmv_transform *transform, const struct wg_media_type *type )
{
    const MFVIDEOFORMAT *out = video_format( type );
    enum mav_pixel_format fmt;
    MFVIDEOFORMAT *copy;

    if (!out || (fmt = wmv_output_format( &out->guidFormat )) == MAV_PIX_UNKNOWN) return STATUS_NOT_SUPPORTED;
    if (out->videoInfo.dwWidth > MAV_MAX_DIMENSION || out->videoInfo.dwHeight > MAV_MAX_DIMENSION)
        return STATUS_NOT_SUPPORTED;
    if (!(copy = malloc( type->format_size ))) return STATUS_NO_MEMORY;
    memcpy( copy, out, type->format_size );
    if (!copy->videoInfo.dwWidth || !copy->videoInfo.dwHeight)
    {
        copy->videoInfo.dwWidth = transform->width;
        copy->videoInfo.dwHeight = transform->height;
    }
    free( transform->out_format );
    transform->out_format = copy;
    transform->out_format_size = type->format_size;
    transform->out_fmt = fmt;
    return STATUS_SUCCESS;
}

/* mav_lavc_video hands decoded pictures back through this, in presentation
 * order. */
static void wmv_emit( void *ctx, void *frame, int64_t pts, int64_t duration )
{
    struct wmv_transform *transform = ctx;

    if (transform->picture_count == transform->picture_cap)
    {
        UINT32 cap = transform->picture_cap ? transform->picture_cap * 2 : 4;
        struct wmv_picture *grown = realloc( transform->pictures, cap * sizeof(*grown) );

        if (!grown)
        {
            mav_lavc_release( frame );
            transform->lost++;
            transform->discontinuity = TRUE;
            return;
        }
        transform->pictures = grown;
        transform->picture_cap = cap;
    }
    transform->pictures[transform->picture_count].frame = frame;
    transform->pictures[transform->picture_count].pts = pts;
    transform->pictures[transform->picture_count].duration = duration;
    transform->picture_count++;
}

static void wmv_pop_picture( struct wmv_transform *transform )
{
    mav_lavc_release( transform->pictures[0].frame );
    memmove( transform->pictures, transform->pictures + 1,
             (transform->picture_count - 1) * sizeof(*transform->pictures) );
    transform->picture_count--;
}

static void wmv_decode_packet( struct wmv_transform *transform, const struct wmv_packet *packet )
{
    int err;

    if (packet->flags & WG_SAMPLE_FLAG_DISCONTINUITY) transform->discontinuity = TRUE;
    /* An empty packet would tell libavcodec the stream has ended. */
    if (!packet->size) return;
    if (!transform->dec)
    {
        if (!transform->dropped++)
            WMV_LOG( "transform %p: no %s decoder (the input type had no sequence header); "
                     "dropping what is pushed\n", transform, transform->name );
        return;
    }
    err = mav_lavc_decode( transform->dec, packet->data, packet->size, packet->pts, packet->duration,
                           !!(packet->flags & WG_SAMPLE_FLAG_SYNC_POINT), wmv_emit, transform );
    if (err < 0)
    {
        transform->rejected++;
        transform->discontinuity = TRUE;
        if (transform->rejected_logged < MADEIRA_WMV_MAX_ERROR_LOGS)
        {
            transform->rejected_logged++;
            WMV_LOG( "transform %p: %s frame of %u bytes rejected by the decoder (%u so far)\n",
                     transform, transform->name, packet->size, transform->rejected );
        }
    }
}

/* The end of the stream: what the decoder holds back.  After it the decoder
 * takes frames again only once flushed. */
static void wmv_complete_drain( struct wmv_transform *transform )
{
    transform->draining = FALSE;
    if (!transform->dec) return;
    mav_lavc_drain( transform->dec, wmv_emit, transform );
    mav_lavc_flush( transform->dec );
}

static void wmv_decode_until_picture( struct wmv_transform *transform )
{
    while (!transform->picture_count && transform->packet_count)
    {
        struct wmv_packet packet = transform->packets[0];

        memmove( transform->packets, transform->packets + 1,
                 (transform->packet_count - 1) * sizeof(*transform->packets) );
        transform->packet_count--;
        wmv_decode_packet( transform, &packet );
        free( packet.data );
    }
    /* wg_transform.c sends its end of stream once the last queued input has
     * gone into the decoder. */
    if (transform->draining && !transform->packet_count) wmv_complete_drain( transform );
}

static void wmv_report( struct wmv_transform *transform, const char *when )
{
    if (!transform->pushed && !transform->lost) return;
    WMV_LOG( "%s: transform %p, %s: %u frames in, %u pictures out, %u rejected by the decoder, "
             "%u dropped without a decoder, %u lost to memory\n", when, transform, transform->name,
             transform->pushed, transform->delivered, transform->rejected, transform->dropped, transform->lost );
}

/***********************************************************************
 *           where a picture goes in the caller's buffer
 */
struct wmv_geometry
{
    struct mav_video_output vout;   /* what is written: format, size; height < 0: bottom-up */
    struct mav_layout frame;        /* the whole frame's planes */
    struct mav_layout layout;       /* the same, moved to the picture's region */
    UINT32 region_w, region_h;      /* the region: the aperture, or the whole frame */
    BOOL covers;                    /* the picture fills its region */
};

/* Bytes per pixel of the first plane. */
static UINT32 wmv_pixel_bytes( enum mav_pixel_format fmt )
{
    switch (fmt)
    {
    case MAV_PIX_NV12:
    case MAV_PIX_I420:
    case MAV_PIX_YV12:  return 1;
    case MAV_PIX_YUY2:
    case MAV_PIX_UYVY:
    case MAV_PIX_YVYU:
    case MAV_PIX_RGB15:
    case MAV_PIX_RGB16: return 2;
    case MAV_PIX_BGR:   return 3;
    default:            return 4;
    }
}

static BOOL wmv_geometry( struct wmv_transform *transform, const struct mav_vplanes *picture, UINT32 stride,
                          struct wmv_geometry *g )
{
    const MFVideoInfo *info = &transform->out_format->videoInfo;
    const MFVideoArea *aperture = &info->MinimumDisplayAperture;
    enum mav_pixel_format fmt = transform->out_fmt;
    BOOL planar = fmt == MAV_PIX_NV12 || fmt == MAV_PIX_I420 || fmt == MAV_PIX_YV12;
    BOOL subsampled = planar || fmt == MAV_PIX_YUY2 || fmt == MAV_PIX_UYVY || fmt == MAV_PIX_YVYU;
    BOOL flip = !!(info->VideoFlags & MFVideoFlag_BottomUpLinearRep);
    UINT32 w = info->dwWidth, h = info->dwHeight, bpp = wmv_pixel_bytes( fmt );
    UINT32 rx = 0, ry = 0, rw = w, rh = h, cw, ch, p, planes;
    struct mav_layout *l = &g->frame;

    if (!mav_video_layout( fmt, w, h, l )) return FALSE;
    /* wg_transform.c's exception: NV12 rows are 2-aligned, as on Windows. */
    if (fmt == MAV_PIX_NV12) l->stride[0] = l->stride[1] = (w + 1) & ~1u;
    if (stride)
    {
        /* The caller's 2D buffer: its pitch is the first plane's stride; a
         * planar format's chroma rows are half that (NV12's, interleaved,
         * the same), as mfplat lays out its 2D buffers. */
        UINT32 row = subsampled ? ((w + 1) & ~1u) * bpp : w * bpp;

        if (stride >= row)
        {
            l->stride[0] = stride;
            if (fmt == MAV_PIX_NV12) l->stride[1] = stride;
            else if (planar) l->stride[1] = l->stride[2] = stride / 2;
        }
        else if (!transform->stride_logged)
        {
            transform->stride_logged = TRUE;
            WMV_LOG( "transform %p: a stride of %u is too short for %u pixels of %s; using the default\n",
                     transform, stride, w, mav_pix_name( fmt ) );
        }
    }
    l->offset[0] = l->offset[1] = l->offset[2] = 0;
    if (!planar) l->size = (size_t)l->stride[0] * h;
    else
    {
        l->offset[1] = (size_t)l->stride[0] * h;
        l->offset[2] = l->offset[1] + (size_t)l->stride[1] * l->chroma_height;
        l->size = fmt == MAV_PIX_NV12 ? l->offset[2] : l->offset[2] + (size_t)l->stride[2] * l->chroma_height;
    }

    /* GStreamer's is_mf_video_area_empty(): an aperture is set if any field is. */
    if ((aperture->OffsetX.value || aperture->OffsetY.value || aperture->Area.cx || aperture->Area.cy)
        && aperture->OffsetX.value >= 0 && aperture->OffsetY.value >= 0
        && (UINT32)aperture->OffsetX.value < w && (UINT32)aperture->OffsetY.value < h
        && aperture->Area.cx > 0 && aperture->Area.cy > 0)
    {
        rx = aperture->OffsetX.value;
        ry = aperture->OffsetY.value;
        rw = min( (UINT32)aperture->Area.cx, w - rx );
        rh = min( (UINT32)aperture->Area.cy, h - ry );
        if (subsampled) rx &= ~1u;      /* chroma is shared by pixel pairs */
        if (planar) ry &= ~1u;          /* and, in 4:2:0, by row pairs */
    }
    cw = min( picture->width, rw );
    ch = min( picture->height, rh );
    g->region_w = rw;
    g->region_h = rh;
    g->covers = cw == rw && ch == rh;
    g->vout.fmt = fmt;
    g->vout.width = cw;
    g->vout.height = flip ? -(int32_t)ch : (int32_t)ch;
    g->vout.fps_n = g->vout.fps_d = 0;

    /* Each plane's origin moves to the region, so that mav_convert_picture's
     * rows -- counted over the region, from its last row when flipped --
     * land in it. */
    g->layout = *l;
    planes = fmt == MAV_PIX_NV12 ? 2 : planar ? 3 : 1;
    for (p = 0; p < planes; p++)
    {
        UINT32 rows = p ? l->chroma_height : h, y = p ? ry / 2 : ry, n = p ? (ch + 1) / 2 : ch;
        UINT32 x = p ? (fmt == MAV_PIX_NV12 ? rx : rx / 2) : rx * bpp;

        g->layout.offset[p] += (size_t)l->stride[p] * (flip ? rows - y - n : y) + x;
    }
    g->layout.chroma_height = (ch + 1) / 2;
    return TRUE;
}

/* A picture smaller than its region: the whole frame is black first, in the
 * values mav_convert_picture pads with. */
static void wmv_fill_black( enum mav_pixel_format fmt, const struct mav_layout *l, UINT32 w, UINT32 h, BYTE *dst )
{
    UINT32 x, y;

    switch (fmt)
    {
    case MAV_PIX_NV12:
    case MAV_PIX_I420:
    case MAV_PIX_YV12:
        memset( dst, 16, l->offset[1] );
        memset( dst + l->offset[1], 128, l->size - l->offset[1] );
        break;
    case MAV_PIX_YUY2:
    case MAV_PIX_UYVY:
    case MAV_PIX_YVYU:
        for (y = 0; y < h; y++)
            for (x = 0; x + 4 <= l->stride[0]; x += 4)
                memcpy( dst + (size_t)y * l->stride[0] + x, fmt == MAV_PIX_UYVY ? "\x80\x10\x80\x10" : "\x10\x80\x10\x80", 4 );
        break;
    case MAV_PIX_BGRA:
    case MAV_PIX_BGRx:
    case MAV_PIX_RGBA:
        for (y = 0; y < h; y++)
            for (x = 0; x < w; x++)
                memcpy( dst + (size_t)y * l->stride[0] + x * 4, "\0\0\0\xff", 4 );
        break;
    default:
        memset( dst, 0, l->size );
        break;
    }
}

/***********************************************************************
 *           the WMV kind's entries
 */
static NTSTATUS wmv_create( struct wg_transform_create_params *params )
{
    const MFVIDEOFORMAT *in = video_format( &params->input_type );
    const MFVIDEOFORMAT *out = video_format( &params->output_type );
    struct wmv_transform *transform;
    UINT32 codec_data_size = 0, fps_n, fps_d;
    const BYTE *codec_data;
    const char *name = NULL;
    char why[96] = "", sub[16];
    NTSTATUS status;
    int codec;

    params->transform = 0;
    if (!in) return STATUS_NOT_SUPPORTED;   /* a malformed block */
    if (!(codec = wmv_input_codec( &in->guidFormat, &name )))
    {
        WMV_LOG( "input subtype %s is not a Windows Media video stream (WMV1/WMV2/WMV3/WMVA/WVC1); refusing\n",
                 wmv_subtype_name( &in->guidFormat, sub ) );
        return STATUS_NOT_SUPPORTED;
    }
    if (!out || wmv_output_format( &out->guidFormat ) == MAV_PIX_UNKNOWN)
    {
        WMV_LOG( "%s: output subtype %s is not one this decoder writes "
                 "(NV12 YV12 I420 IYUV YUY2 UYVY YVYU RGB32 ARGB32 ABGR32 RGB24 RGB565 RGB555); refusing\n",
                 name, out ? wmv_subtype_name( &out->guidFormat, sub ) : "(not video)" );
        return STATUS_NOT_SUPPORTED;
    }
    if (!in->videoInfo.dwWidth || !in->videoInfo.dwHeight
        || in->videoInfo.dwWidth > MAV_MAX_DIMENSION || in->videoInfo.dwHeight > MAV_MAX_DIMENSION)
    {
        /* WMV7/8/9 bitstreams do not carry the picture size: the container's is all there is. */
        WMV_LOG( "%s: unusable frame size %ux%u; refusing\n", name,
                 (UINT)in->videoInfo.dwWidth, (UINT)in->videoInfo.dwHeight );
        return STATUS_NOT_SUPPORTED;
    }
    if (!mav_lavc_supports( codec ))
    {
        WMV_LOG( "%s: no decoder for it in this FFmpeg build; refusing\n", name );
        return STATUS_NOT_SUPPORTED;
    }
    codec_data = video_user_data( in, params->input_type.format_size, &codec_data_size );
    if (codec_data_size > MADEIRA_WMV_MAX_CODEC_DATA)
    {
        WMV_LOG( "%s: %u bytes of codec private data; refusing\n", name, codec_data_size );
        return STATUS_NOT_SUPPORTED;
    }

    /* libavcodec's diagnostics, under this file's tags (see wma_av_log). */
    pthread_once( &wma_av_log_once, wma_install_av_log );

    if (!(transform = calloc( 1, sizeof(*transform) ))) return STATUS_NO_MEMORY;
    pthread_mutex_init( &transform->lock, NULL );
    transform->magic = MADEIRA_WG_WMV_MAGIC;
    transform->attrs = params->attrs;
    transform->codec = codec;
    transform->name = name;
    transform->width = in->videoInfo.dwWidth;
    transform->height = in->videoInfo.dwHeight;
    fps_n = in->videoInfo.FramesPerSecond.Numerator;
    fps_d = in->videoInfo.FramesPerSecond.Denominator;
    if (fps_n && fps_d) transform->frame_duration = (INT64)fps_d * 10000000 / fps_n;
    switch (in->videoInfo.TransferMatrix)
    {
    case MFVideoTransferMatrix_BT709:    transform->bt709 = 1; break;
    case MFVideoTransferMatrix_BT601:
    case MFVideoTransferMatrix_SMPTE240M: transform->bt709 = 0; break;
    default: transform->bt709 = transform->height >= 720; break;   /* as the parser assumes */
    }
    if ((status = wmv_set_output( transform, &params->output_type )))
    {
        WMV_LOG( "%s: output type %ux%u refused (%#x)\n", name, (UINT)out->videoInfo.dwWidth,
                 (UINT)out->videoInfo.dwHeight, (UINT)status );
        goto fail;
    }

    transform->dec = mav_lavc_open( codec, codec_data, codec_data_size, transform->width, transform->height,
                                    why, sizeof(why) );
    if (!transform->dec && codec_data_size)
    {
        WMV_LOG( "%s %ux%u: the decoder refused the %u-byte sequence header (%s); refusing\n",
                 name, transform->width, transform->height, codec_data_size, why );
        status = STATUS_NOT_SUPPORTED;
        goto fail;
    }
    if (transform->dec) ((struct mav_lavc_vdec *)transform->dec)->ctx->opaque = WMV_DECODER_MARKER;

    params->transform = (wg_transform_t)(UINT_PTR)transform;
    WMV_LOG( "decoder created fmt=%s %ux%u fps=%u/%u codec_data=%u -> %s %ux%u%s queue=%u%s (transform %p)%s\n",
             name, transform->width, transform->height, fps_n, fps_d, codec_data_size,
             mav_pix_name( transform->out_fmt ), (UINT)transform->out_format->videoInfo.dwWidth,
             (UINT)transform->out_format->videoInfo.dwHeight,
             (transform->out_format->videoInfo.VideoFlags & MFVideoFlag_BottomUpLinearRep) ? " bottom-up" : "",
             transform->attrs.input_queue_length, transform->attrs.preserve_timestamps ? " preserve-ts" : "",
             transform, transform->dec ? "" : " [decoder not open: no sequence header, as in "
                                              "wmv_decoder_create()'s probe; input will be dropped]" );
    return STATUS_SUCCESS;

fail:
    free( transform->out_format );
    pthread_mutex_destroy( &transform->lock );
    transform->magic = 0;
    free( transform );
    return status;
}

static void wmv_clear( struct wmv_transform *transform )
{
    while (transform->packet_count) free( transform->packets[--transform->packet_count].data );
    while (transform->picture_count) wmv_pop_picture( transform );
}

static NTSTATUS wmv_destroy( wg_transform_t handle )
{
    struct wmv_transform *transform = get_wmv_transform( handle );

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    wmv_report( transform, "destroy" );
    transform->magic = 0;
    wmv_clear( transform );
    if (transform->dec) mav_lavc_close( transform->dec );
    free( transform->packets );
    free( transform->pictures );
    free( transform->out_format );
    pthread_mutex_unlock( &transform->lock );
    pthread_mutex_destroy( &transform->lock );
    free( transform );
    return STATUS_SUCCESS;
}

static NTSTATUS wmv_get_output_type( wg_transform_t handle, struct wg_media_type *type )
{
    struct wmv_transform *transform = get_wmv_transform( handle );
    UINT32 size;

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    size = transform->out_format_size;
    type->major = madeira_MFMediaType_Video;
    /* Two-phase, as main.c's wg_transform_get_output_type() expects. */
    if (!type->u.format || type->format_size < size)
    {
        type->format_size = size;
        pthread_mutex_unlock( &transform->lock );
        return STATUS_BUFFER_TOO_SMALL;
    }
    memcpy( type->u.format, transform->out_format, size );
    type->format_size = size;
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

static NTSTATUS wmv_set_output_type( wg_transform_t handle, const struct wg_media_type *type )
{
    struct wmv_transform *transform = get_wmv_transform( handle );
    NTSTATUS status;

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    /* The decoder and the pictures it has made are kept: they are written in
     * the new format when they are read, which is what wg_transform.c says a
     * native transform does and GStreamer could not. */
    if (!(status = wmv_set_output( transform, type )))
        WMV_LOG( "transform %p: output type set to %s %ux%u%s\n", transform, mav_pix_name( transform->out_fmt ),
                 (UINT)transform->out_format->videoInfo.dwWidth, (UINT)transform->out_format->videoInfo.dwHeight,
                 (transform->out_format->videoInfo.VideoFlags & MFVideoFlag_BottomUpLinearRep) ? " bottom-up" : "" );
    pthread_mutex_unlock( &transform->lock );
    return status;
}

static NTSTATUS wmv_push_data( wg_transform_t handle, struct wg_sample *sample, const void *data, HRESULT *result )
{
    struct wmv_transform *transform = get_wmv_transform( handle );
    struct wmv_packet *packet;

    if (!transform || !sample) return STATUS_INVALID_HANDLE;
    if (sample->size && !data) return STATUS_INVALID_PARAMETER;

    pthread_mutex_lock( &transform->lock );
    /* wg_transform.c: no input while a drain is under way, and no more than
     * input_queue_length + 1 frames queued. */
    if (transform->draining || transform->packet_count > transform->attrs.input_queue_length)
    {
        pthread_mutex_unlock( &transform->lock );
        *result = MF_E_NOTACCEPTING;
        return STATUS_SUCCESS;
    }
    if (transform->packet_count == transform->packet_cap)
    {
        UINT32 cap = transform->packet_cap ? transform->packet_cap * 2 : 8;
        struct wmv_packet *grown = realloc( transform->packets, cap * sizeof(*grown) );

        if (!grown)
        {
            pthread_mutex_unlock( &transform->lock );
            return STATUS_NO_MEMORY;
        }
        transform->packets = grown;
        transform->packet_cap = cap;
    }
    packet = &transform->packets[transform->packet_count];
    memset( packet, 0, sizeof(*packet) );
    if (sample->size && !(packet->data = malloc( sample->size )))
    {
        pthread_mutex_unlock( &transform->lock );
        return STATUS_NO_MEMORY;
    }
    if (sample->size) memcpy( packet->data, data, sample->size );
    packet->size = sample->size;
    packet->flags = sample->flags;
    packet->pts = (sample->flags & WG_SAMPLE_FLAG_HAS_PTS) ? sample->pts : INT64_MIN;
    packet->duration = (sample->flags & WG_SAMPLE_FLAG_HAS_DURATION) ? (INT64)sample->duration : INT64_MIN;
    transform->packet_count++;
    transform->pushed++;
    pthread_mutex_unlock( &transform->lock );
    *result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS wmv_read_data( wg_transform_t handle, struct wg_sample *sample, void *data, HRESULT *result )
{
    struct wmv_transform *transform = get_wmv_transform( handle );
    struct wmv_picture *picture;
    struct mav_vplanes planes;
    struct wmv_geometry g;
    BOOL preserve = FALSE;
    INT64 pts, duration;

    if (!transform || !sample) return STATUS_INVALID_HANDLE;
    if (sample->max_size && !data) return STATUS_INVALID_PARAMETER;

    pthread_mutex_lock( &transform->lock );
    wmv_decode_until_picture( transform );
    if (!transform->picture_count)
    {
        sample->size = 0;
        pthread_mutex_unlock( &transform->lock );
        *result = MF_E_TRANSFORM_NEED_MORE_INPUT;
        return STATUS_SUCCESS;
    }
    picture = &transform->pictures[0];
    mav_lavc_map( picture->frame, &planes );

    if (!wmv_geometry( transform, &planes, sample->stride, &g ))
    {
        pthread_mutex_unlock( &transform->lock );
        return STATUS_UNSUCCESSFUL;
    }
    if (transform->attrs.allow_format_change && (planes.width != g.region_w || planes.height != g.region_h))
    {
        /* The caller takes a new size: report it once, deliver nothing. */
        MFVideoInfo *info = &transform->out_format->videoInfo;

        WMV_LOG( "transform %p: picture size %ux%u, was %ux%u: format change\n", transform,
                 planes.width, planes.height, (UINT)info->dwWidth, (UINT)info->dwHeight );
        info->dwWidth = planes.width;
        info->dwHeight = planes.height;
        memset( &info->GeometricAperture, 0, sizeof(info->GeometricAperture) );
        memset( &info->MinimumDisplayAperture, 0, sizeof(info->MinimumDisplayAperture) );
        memset( &info->PanScanAperture, 0, sizeof(info->PanScanAperture) );
        sample->size = 0;
        pthread_mutex_unlock( &transform->lock );
        *result = MF_E_TRANSFORM_STREAM_CHANGE;
        return STATUS_SUCCESS;
    }
    if (g.frame.size > sample->max_size)
    {
        /* As wg_transform.c: an error, and the picture stays for a bigger buffer. */
        if (!transform->size_logged)
        {
            transform->size_logged = TRUE;
            WMV_LOG( "transform %p: a %u-byte buffer cannot hold a %ux%u %s frame (%zu bytes)\n", transform,
                     sample->max_size, (UINT)transform->out_format->videoInfo.dwWidth,
                     (UINT)transform->out_format->videoInfo.dwHeight, mav_pix_name( transform->out_fmt ),
                     g.frame.size );
        }
        sample->size = 0;
        pthread_mutex_unlock( &transform->lock );
        return STATUS_BUFFER_TOO_SMALL;
    }

    if (!g.covers)
        wmv_fill_black( g.vout.fmt, &g.frame, transform->out_format->videoInfo.dwWidth,
                        transform->out_format->videoInfo.dwHeight, data );
    mav_convert_picture( &g.vout, transform->bt709, &planes, data, &g.layout );
    mav_lavc_unmap( picture->frame );

    if (picture->pts != INT64_MIN)
    {
        pts = picture->pts;
        preserve = transform->attrs.preserve_timestamps;
    }
    else pts = transform->next_pts;
    duration = picture->duration != INT64_MIN ? picture->duration : transform->frame_duration;
    transform->next_pts = pts + duration;

    sample->size = (UINT32)g.frame.size;
    sample->flags &= ~(WG_SAMPLE_FLAG_INCOMPLETE | WG_SAMPLE_FLAG_HAS_PTS | WG_SAMPLE_FLAG_HAS_DURATION |
                       WG_SAMPLE_FLAG_SYNC_POINT | WG_SAMPLE_FLAG_DISCONTINUITY |
                       WG_SAMPLE_FLAG_PRESERVE_TIMESTAMPS);
    sample->flags |= WG_SAMPLE_FLAG_SYNC_POINT | WG_SAMPLE_FLAG_HAS_PTS | WG_SAMPLE_FLAG_HAS_DURATION;
    if (preserve) sample->flags |= WG_SAMPLE_FLAG_PRESERVE_TIMESTAMPS;
    if (transform->discontinuity) sample->flags |= WG_SAMPLE_FLAG_DISCONTINUITY;
    transform->discontinuity = FALSE;
    sample->pts = pts;
    sample->duration = duration;

    wmv_pop_picture( transform );
    transform->delivered++;
    pthread_mutex_unlock( &transform->lock );
    *result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS wmv_get_status( wg_transform_t handle, UINT32 *accepts_input )
{
    struct wmv_transform *transform = get_wmv_transform( handle );

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    *accepts_input = transform->packet_count <= transform->attrs.input_queue_length;
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

static NTSTATUS wmv_drain( wg_transform_t handle )
{
    struct wmv_transform *transform = get_wmv_transform( handle );

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    /* With frames still queued the end of stream waits for read_data to
     * have decoded them, and push_data refuses until then. */
    transform->draining = TRUE;
    if (!transform->packet_count) wmv_complete_drain( transform );
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

static NTSTATUS wmv_flush( wg_transform_t handle )
{
    struct wmv_transform *transform = get_wmv_transform( handle );

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    if (transform->rejected || transform->dropped || transform->lost) wmv_report( transform, "flush" );
    wmv_clear( transform );
    if (transform->dec) mav_lavc_flush( transform->dec );
    transform->draining = FALSE;
    transform->next_pts = 0;
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

/* Every video input is this kind's to judge, unless switched off: wmv_create
 * refuses, and logs, what is not Windows Media video. */
static BOOL wmv_claims( const struct wg_transform_create_params *params )
{
    return IsEqualGUID( &params->input_type.major, &madeira_MFMediaType_Video ) && wmv_transform_switch_on();
}

/***********************************************************************
 *           wg_transform: the audio resampler   (MADEIRA)
 *
 * winegstreamer's resampler -- CLSID_CResamplerMediaObject and wg_resampler,
 * the converter Media Foundation's topology loader puts between a source's
 * PCM and the audio renderer, which takes nothing but the device mix format --
 * is a GStreamer audioconvert ! audioresample pipeline upstream.  Here it is
 * libswresample: integer PCM of 8, 16, 24 or 32 bits and float of 32 or 64,
 * WAVEFORMATEX or WAVEFORMATEXTENSIBLE, any rate, 1 to 8 channels, in and out.
 * Without it a movie whose audio is not in the mix format loses its whole
 * topology: no audio branch, no presentation clock, and the video renderer
 * never presents (Senren Banka's WMV movies: 48 kHz S16 from the WMA decoder).
 * MADEIRA_WG_RESAMPLER=0 refuses it again.
 *
 * Same protocol as the WMA decoder: push converts at once, and refuses more
 * input (MF_E_NOTACCEPTING) while converted audio waits to be read.  It is the
 * first row of transform_kinds, so raw audio never reaches the WMA decoder.
 */
#define MADEIRA_WG_RESAMPLER_MAGIC 0x52534d50  /* 'RSMP' */
#define RS_MAX_CHANNELS 8
#define RS_MAX_LOGS 32

static unsigned int rs_log_count;

#define RS_LOG( fmt, ... )                                                           \
    do {                                                                             \
        unsigned int _n = __atomic_add_fetch( &rs_log_count, 1, __ATOMIC_RELAXED );  \
        if (_n <= RS_MAX_LOGS || wma_diag_on())                                      \
            dprintf( 2, "[resampler] " fmt, ## __VA_ARGS__ );                        \
    } while (0)

struct rs_format
{
    enum AVSampleFormat fmt;    /* what libswresample sees: 24-bit PCM goes through S32 */
    UINT32 bits;                /* bits per sample in the caller's buffers */
    UINT32 rate, channels;
    UINT32 frame_size;          /* bytes per frame in the caller's buffers */
    AVChannelLayout layout;
};

struct rs_transform
{
    UINT32 magic;
    pthread_mutex_t lock;
    SwrContext *swr;
    struct rs_format in, out;

    /* the output type as the caller set it, handed back verbatim */
    BYTE *out_format;
    UINT32 out_format_size;

    BYTE *wide;                 /* 24-bit input widened to S32 */
    size_t wide_cap;
    BYTE *pcm_buf;              /* converted audio, consumed by read_data */
    size_t pcm_cap, pcm_pos, pcm_len;

    /* timestamps: the output frame `anchor_frames` before the next one read
     * starts at `anchor`, so that rounding never adds up */
    INT64 anchor;               /* 100 ns */
    UINT64 anchor_frames;
    BOOL have_pts;
    BOOL discontinuity;
    UINT32 partial_logged;
};

/* MADEIRA_WG_RESAMPLER=0 refuses the resampler again: raw audio in fails at
 * create, as before, and a media session with no matching mix format loses its
 * audio branch. */
static BOOL rs_switch_on(void)
{
    const char *v = getenv( "MADEIRA_WG_RESAMPLER" );
    return !(v && v[0] == '0' && !v[1]);
}

static struct rs_transform *get_rs_transform( wg_transform_t handle )
{
    struct rs_transform *transform = (struct rs_transform *)(UINT_PTR)handle;

    if (!transform || transform->magic != MADEIRA_WG_RESAMPLER_MAGIC) return NULL;
    return transform;
}

/* Raw audio in: a resampler's input, not a decoder's. */
static BOOL rs_is_raw_audio( const struct wg_media_type *type )
{
    const WAVEFORMATEX *wfx = audio_format( type );
    UINT tag;

    if (!wfx) return FALSE;
    tag = format_tag( wfx, type->format_size );
    return tag == WAVE_FORMAT_PCM || tag == WAVE_FORMAT_IEEE_FLOAT;
}

static BOOL rs_parse( const struct wg_media_type *type, struct rs_format *f )
{
    const WAVEFORMATEX *wfx = audio_format( type );
    UINT tag;

    memset( f, 0, sizeof(*f) );
    if (!wfx) return FALSE;
    tag = format_tag( wfx, type->format_size );
    if (tag == WAVE_FORMAT_PCM)
    {
        switch (wfx->wBitsPerSample)
        {
        case 8:  f->fmt = AV_SAMPLE_FMT_U8; break;
        case 16: f->fmt = AV_SAMPLE_FMT_S16; break;
        case 24:
        case 32: f->fmt = AV_SAMPLE_FMT_S32; break;
        default: return FALSE;
        }
    }
    else if (tag == WAVE_FORMAT_IEEE_FLOAT)
    {
        switch (wfx->wBitsPerSample)
        {
        case 32: f->fmt = AV_SAMPLE_FMT_FLT; break;
        case 64: f->fmt = AV_SAMPLE_FMT_DBL; break;
        default: return FALSE;
        }
    }
    else return FALSE;
    /* nBlockAlign is not trusted: check_audio_transform_support() leaves it 0 */
    if (!wfx->nChannels || wfx->nChannels > RS_MAX_CHANNELS || !wfx->nSamplesPerSec || wfx->nSamplesPerSec > 768000)
        return FALSE;
    f->bits = wfx->wBitsPerSample;
    f->rate = wfx->nSamplesPerSec;
    f->channels = wfx->nChannels;
    f->frame_size = f->channels * (f->bits / 8);
    layout_from_mask( &f->layout, channel_mask( wfx, type->format_size ), f->channels );
    return TRUE;
}

static const char *rs_format_name( const struct rs_format *f )
{
    switch (f->fmt)
    {
    case AV_SAMPLE_FMT_U8:  return "u8";
    case AV_SAMPLE_FMT_S16: return "s16";
    case AV_SAMPLE_FMT_S32: return f->bits == 24 ? "s24" : "s32";
    case AV_SAMPLE_FMT_FLT: return "f32";
    case AV_SAMPLE_FMT_DBL: return "f64";
    default:                return "?";
    }
}

static int rs_open( struct rs_transform *transform )
{
    int err;

    swr_free( &transform->swr );
    if ((err = swr_alloc_set_opts2( &transform->swr, &transform->out.layout, transform->out.fmt,
                                    transform->out.rate, &transform->in.layout, transform->in.fmt,
                                    transform->in.rate, 0, NULL )) < 0)
        return err;
    if ((err = swr_init( transform->swr )) < 0) swr_free( &transform->swr );
    return err;
}

/* Converts `frames` frames of the caller's input (NULL: what libswresample
 * still holds) onto the end of pcm_buf. */
static NTSTATUS rs_convert( struct rs_transform *transform, const BYTE *data, UINT32 frames )
{
    const uint8_t *in = data;
    uint8_t *out;
    UINT32 swr_frame = transform->out.channels * av_get_bytes_per_sample( transform->out.fmt );
    int max, n, i;

    if (data && transform->in.bits == 24)
    {
        /* little-endian 24-bit to the top of an S32 */
        size_t samples = (size_t)frames * transform->in.channels;
        INT32 *w;
        if (!buffer_reserve( &transform->wide, &transform->wide_cap, samples * 4 )) return STATUS_NO_MEMORY;
        w = (INT32 *)transform->wide;
        for (i = 0; i < (int)samples; i++)
            w[i] = (INT32)((UINT32)data[3 * i] << 8 | (UINT32)data[3 * i + 1] << 16 | (UINT32)data[3 * i + 2] << 24);
        in = transform->wide;
    }
    if ((max = swr_get_out_samples( transform->swr, data ? (int)frames : 0 )) < 0) return STATUS_INTERNAL_ERROR;
    if (!max) return STATUS_SUCCESS;
    if (!buffer_reserve( &transform->pcm_buf, &transform->pcm_cap, transform->pcm_len + (size_t)max * swr_frame ))
        return STATUS_NO_MEMORY;
    out = transform->pcm_buf + transform->pcm_len;
    if ((n = swr_convert( transform->swr, &out, max, data ? &in : NULL, data ? (int)frames : 0 )) < 0)
    {
        RS_LOG( "swr_convert failed (%d) on %u frames (transform %p)\n", n, frames, transform );
        return STATUS_INTERNAL_ERROR;
    }
    if (transform->out.bits == 24)
    {
        /* back down from S32, in place: each 3-byte sample lands at or before its source */
        size_t samples = (size_t)n * transform->out.channels;
        for (i = 0; i < (int)samples; i++)
        {
            UINT32 v = ((UINT32 *)out)[i];
            out[3 * i] = (BYTE)(v >> 8);
            out[3 * i + 1] = (BYTE)(v >> 16);
            out[3 * i + 2] = (BYTE)(v >> 24);
        }
    }
    transform->pcm_len += (size_t)n * transform->out.frame_size;
    return STATUS_SUCCESS;
}

static void rs_compact( struct rs_transform *transform )
{
    if (transform->pcm_pos == transform->pcm_len)
        transform->pcm_pos = transform->pcm_len = 0;
}

static BOOL rs_claims( const struct wg_transform_create_params *params )
{
    return rs_is_raw_audio( &params->input_type );
}

static NTSTATUS rs_create( struct wg_transform_create_params *params )
{
    const WAVEFORMATEX *out = audio_format( &params->output_type );
    struct rs_transform *transform;
    struct rs_format fin, fout;
    int err;

    params->transform = 0;
    if (!rs_switch_on())
    {
        RS_LOG( "disabled by MADEIRA_WG_RESAMPLER=0; refusing\n" );
        return STATUS_NOT_SUPPORTED;
    }
    if (!rs_parse( &params->input_type, &fin ))
    {
        RS_LOG( "input is not 8/16/24/32-bit PCM or 32/64-bit float, 1-%u channels; refusing\n", RS_MAX_CHANNELS );
        return STATUS_NOT_SUPPORTED;
    }
    if (!rs_parse( &params->output_type, &fout ))
    {
        RS_LOG( "output is not 8/16/24/32-bit PCM or 32/64-bit float, 1-%u channels; refusing\n", RS_MAX_CHANNELS );
        av_channel_layout_uninit( &fin.layout );
        return STATUS_NOT_SUPPORTED;
    }
    if (!(transform = calloc( 1, sizeof(*transform) ))
        || !(transform->out_format = malloc( params->output_type.format_size )))
    {
        free( transform );
        av_channel_layout_uninit( &fin.layout );
        av_channel_layout_uninit( &fout.layout );
        return STATUS_NO_MEMORY;
    }
    transform->in = fin;
    transform->out = fout;
    memcpy( transform->out_format, out, params->output_type.format_size );
    transform->out_format_size = params->output_type.format_size;
    if ((err = rs_open( transform )) < 0)
    {
        RS_LOG( "libswresample refused %s %u Hz %uch -> %s %u Hz %uch (%d)\n", rs_format_name( &fin ), fin.rate,
                fin.channels, rs_format_name( &fout ), fout.rate, fout.channels, err );
        av_channel_layout_uninit( &transform->in.layout );
        av_channel_layout_uninit( &transform->out.layout );
        free( transform->out_format );
        free( transform );
        return STATUS_NOT_SUPPORTED;
    }
    pthread_mutex_init( &transform->lock, NULL );
    transform->magic = MADEIRA_WG_RESAMPLER_MAGIC;
    transform->discontinuity = TRUE;
    params->transform = (wg_transform_t)(UINT_PTR)transform;
    RS_LOG( "created %s %u Hz %uch -> %s %u Hz %uch (transform %p)\n", rs_format_name( &fin ), fin.rate,
            fin.channels, rs_format_name( &fout ), fout.rate, fout.channels, transform );
    return STATUS_SUCCESS;
}

static NTSTATUS rs_destroy( wg_transform_t handle )
{
    struct rs_transform *transform = get_rs_transform( handle );

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    transform->magic = 0;
    swr_free( &transform->swr );
    av_channel_layout_uninit( &transform->in.layout );
    av_channel_layout_uninit( &transform->out.layout );
    free( transform->out_format );
    free( transform->wide );
    free( transform->pcm_buf );
    pthread_mutex_unlock( &transform->lock );
    pthread_mutex_destroy( &transform->lock );
    free( transform );
    return STATUS_SUCCESS;
}

static NTSTATUS rs_push_data( wg_transform_t handle, struct wg_sample *sample, const void *data, HRESULT *result )
{
    struct rs_transform *transform = get_rs_transform( handle );
    UINT32 frames;
    NTSTATUS status;

    if (!transform || !sample) return STATUS_INVALID_HANDLE;
    if (sample->size && !data) return STATUS_INVALID_PARAMETER;

    pthread_mutex_lock( &transform->lock );
    if (transform->pcm_len > transform->pcm_pos)
    {
        *result = MF_E_NOTACCEPTING;
        pthread_mutex_unlock( &transform->lock );
        return STATUS_SUCCESS;
    }
    rs_compact( transform );
    frames = sample->size / transform->in.frame_size;
    if (sample->size % transform->in.frame_size && transform->partial_logged++ < 3)
        RS_LOG( "a %u-byte sample is not whole %u-byte frames; the tail is dropped (transform %p)\n",
                (UINT)sample->size, transform->in.frame_size, transform );
    /* The first frame out of this push is what libswresample still holds from
     * earlier ones, so it starts that much before this sample. */
    if (sample->flags & WG_SAMPLE_FLAG_HAS_PTS)
    {
        transform->anchor = sample->pts - swr_get_delay( transform->swr, 10000000 );
        transform->anchor_frames = 0;
        transform->have_pts = TRUE;
    }
    if (sample->flags & WG_SAMPLE_FLAG_DISCONTINUITY) transform->discontinuity = TRUE;
    status = frames ? rs_convert( transform, data, frames ) : STATUS_SUCCESS;
    pthread_mutex_unlock( &transform->lock );

    *result = status ? E_FAIL : S_OK;
    return status;
}

static NTSTATUS rs_read_data( wg_transform_t handle, struct wg_sample *sample, void *data, HRESULT *result )
{
    struct rs_transform *transform = get_rs_transform( handle );
    size_t avail, copy;

    if (!transform || !sample) return STATUS_INVALID_HANDLE;
    if (sample->max_size && !data) return STATUS_INVALID_PARAMETER;

    pthread_mutex_lock( &transform->lock );
    avail = transform->pcm_len - transform->pcm_pos;
    copy = avail < sample->max_size ? avail : sample->max_size;
    copy -= copy % transform->out.frame_size;
    if (!copy)
    {
        sample->size = 0;
        pthread_mutex_unlock( &transform->lock );
        *result = MF_E_TRANSFORM_NEED_MORE_INPUT;
        return STATUS_SUCCESS;
    }
    memcpy( data, transform->pcm_buf + transform->pcm_pos, copy );
    sample->size = copy;
    sample->flags &= ~(WG_SAMPLE_FLAG_INCOMPLETE | WG_SAMPLE_FLAG_HAS_PTS |
                       WG_SAMPLE_FLAG_HAS_DURATION | WG_SAMPLE_FLAG_DISCONTINUITY);
    sample->flags |= WG_SAMPLE_FLAG_SYNC_POINT | WG_SAMPLE_FLAG_HAS_DURATION;
    {
        UINT64 frames = copy / transform->out.frame_size, rate = transform->out.rate;
        INT64 start = transform->anchor + (INT64)((transform->anchor_frames * 10000000 + rate / 2) / rate);
        INT64 end = transform->anchor + (INT64)(((transform->anchor_frames + frames) * 10000000 + rate / 2) / rate);

        sample->duration = end - start;
        if (transform->have_pts)
        {
            sample->flags |= WG_SAMPLE_FLAG_HAS_PTS;
            sample->pts = start;
        }
        transform->anchor_frames += frames;
    }
    if (transform->discontinuity)
    {
        sample->flags |= WG_SAMPLE_FLAG_DISCONTINUITY;
        transform->discontinuity = FALSE;
    }
    transform->pcm_pos += copy;
    if (transform->pcm_pos < transform->pcm_len) sample->flags |= WG_SAMPLE_FLAG_INCOMPLETE;
    else rs_compact( transform );
    pthread_mutex_unlock( &transform->lock );
    *result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS rs_get_output_type( wg_transform_t handle, struct wg_media_type *type )
{
    struct rs_transform *transform = get_rs_transform( handle );
    UINT32 size;

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    size = transform->out_format_size;
    type->major = madeira_MFMediaType_Audio;
    if (!type->u.format || type->format_size < size)
    {
        type->format_size = size;
        pthread_mutex_unlock( &transform->lock );
        return STATUS_BUFFER_TOO_SMALL;
    }
    memcpy( type->u.format, transform->out_format, size );
    type->format_size = size;
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

static NTSTATUS rs_set_output_type( wg_transform_t handle, const struct wg_media_type *type )
{
    struct rs_transform *transform = get_rs_transform( handle );
    struct rs_format fout, old;
    BYTE *copy;
    int err;

    if (!transform) return STATUS_INVALID_HANDLE;
    if (!rs_parse( type, &fout )) return STATUS_NOT_SUPPORTED;
    if (!(copy = malloc( type->format_size )))
    {
        av_channel_layout_uninit( &fout.layout );
        return STATUS_NO_MEMORY;
    }
    memcpy( copy, type->u.format, type->format_size );

    pthread_mutex_lock( &transform->lock );
    old = transform->out;
    transform->out = fout;
    if ((err = rs_open( transform )) < 0)
    {
        transform->out = old;
        rs_open( transform );
        pthread_mutex_unlock( &transform->lock );
        av_channel_layout_uninit( &fout.layout );
        free( copy );
        RS_LOG( "libswresample refused the new output type (%d); keeping the old one\n", err );
        return STATUS_NOT_SUPPORTED;
    }
    av_channel_layout_uninit( &old.layout );
    /* anything converted is in the old format */
    transform->pcm_pos = transform->pcm_len = 0;
    transform->discontinuity = TRUE;
    free( transform->out_format );
    transform->out_format = copy;
    transform->out_format_size = type->format_size;
    pthread_mutex_unlock( &transform->lock );
    RS_LOG( "output type set to %s %u Hz %uch (transform %p)\n", rs_format_name( &fout ), fout.rate,
            fout.channels, transform );
    return STATUS_SUCCESS;
}

static NTSTATUS rs_get_status( wg_transform_t handle, UINT32 *accepts_input )
{
    struct rs_transform *transform = get_rs_transform( handle );

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    *accepts_input = transform->pcm_len == transform->pcm_pos;
    pthread_mutex_unlock( &transform->lock );
    return STATUS_SUCCESS;
}

/* What libswresample still holds comes out, and it starts afresh. */
static NTSTATUS rs_drain( wg_transform_t handle )
{
    struct rs_transform *transform = get_rs_transform( handle );
    NTSTATUS status;

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    status = rs_convert( transform, NULL, 0 );
    if (swr_init( transform->swr ) < 0) status = STATUS_INTERNAL_ERROR;
    pthread_mutex_unlock( &transform->lock );
    return status;
}

static NTSTATUS rs_flush( wg_transform_t handle )
{
    struct rs_transform *transform = get_rs_transform( handle );
    NTSTATUS status = STATUS_SUCCESS;

    if (!transform) return STATUS_INVALID_HANDLE;
    pthread_mutex_lock( &transform->lock );
    transform->pcm_pos = transform->pcm_len = 0;
    transform->have_pts = FALSE;
    transform->anchor = 0;
    transform->anchor_frames = 0;
    transform->discontinuity = TRUE;
    if (swr_init( transform->swr ) < 0) status = STATUS_INTERNAL_ERROR;
    pthread_mutex_unlock( &transform->lock );
    return status;
}

/***********************************************************************
 *           transform kinds
 *
 * wg_transform_create gives the create to the first kind below that claims
 * the INPUT type, and that kind may still refuse the pair (its log says
 * why).  Every later call finds the kind again by the magic that each kind's
 * object starts with, so a handle is only ever read as the kind that made
 * it, and an unknown one is STATUS_INVALID_HANDLE.  Another kind is another
 * row: claims(), the entries, and a UINT32 magic of its own as the first
 * member of its object.
 */
struct wg_transform_ops
{
    const char *name;
    UINT32 magic;
    BOOL (*claims)( const struct wg_transform_create_params *params );
    NTSTATUS (*create)( struct wg_transform_create_params *params );
    NTSTATUS (*destroy)( wg_transform_t handle );
    NTSTATUS (*get_output_type)( wg_transform_t handle, struct wg_media_type *type );
    NTSTATUS (*set_output_type)( wg_transform_t handle, const struct wg_media_type *type );
    NTSTATUS (*push_data)( wg_transform_t handle, struct wg_sample *sample, const void *data, HRESULT *result );
    NTSTATUS (*read_data)( wg_transform_t handle, struct wg_sample *sample, void *data, HRESULT *result );
    NTSTATUS (*get_status)( wg_transform_t handle, UINT32 *accepts_input );
    NTSTATUS (*drain)( wg_transform_t handle );
    NTSTATUS (*flush)( wg_transform_t handle );
};

static const struct wg_transform_ops rs_transform_ops =
{
    "resampler", MADEIRA_WG_RESAMPLER_MAGIC, rs_claims, rs_create, rs_destroy, rs_get_output_type,
    rs_set_output_type, rs_push_data, rs_read_data, rs_get_status, rs_drain, rs_flush,
};

static const struct wg_transform_ops wma_transform_ops =
{
    "wma", MADEIRA_WG_TRANSFORM_MAGIC, wma_claims, wma_create, wma_destroy, wma_get_output_type,
    wma_set_output_type, wma_push_data, wma_read_data, wma_get_status, wma_drain, wma_flush,
};

static const struct wg_transform_ops wmv_transform_ops =
{
    "wmv", MADEIRA_WG_WMV_MAGIC, wmv_claims, wmv_create, wmv_destroy, wmv_get_output_type,
    wmv_set_output_type, wmv_push_data, wmv_read_data, wmv_get_status, wmv_drain, wmv_flush,
};

/* In claim order: raw audio is the resampler's, other audio the WMA decoder's. */
static const struct wg_transform_ops *const transform_kinds[] =
{
    &rs_transform_ops,
    &wma_transform_ops,
    &wmv_transform_ops,
};

static const struct wg_transform_ops *transform_kind( wg_transform_t handle )
{
    const UINT32 *magic = (const UINT32 *)(UINT_PTR)handle;
    unsigned int i;

    if (!magic) return NULL;
    for (i = 0; i < ARRAY_SIZE(transform_kinds); i++)
        if (transform_kinds[i]->magic == *magic) return transform_kinds[i];
    return NULL;
}

/* The unpacked forms, shared by the 64-bit entries and the wow64 thunks. */
static NTSTATUS transform_create( struct wg_transform_create_params *params )
{
    unsigned int i;

    params->transform = 0;
    for (i = 0; i < ARRAY_SIZE(transform_kinds); i++)
        if (transform_kinds[i]->claims( params )) return transform_kinds[i]->create( params );
    /* Unclaimed: video with MADEIRA_WG_WMV_TRANSFORM=0, or neither audio nor video. */
    if (IsEqualGUID( &params->input_type.major, &madeira_MFMediaType_Video ))
        WMV_LOG( "video transform refused: MADEIRA_WG_WMV_TRANSFORM=0\n" );
    return STATUS_NOT_SUPPORTED;
}

static NTSTATUS transform_destroy( wg_transform_t handle )
{
    const struct wg_transform_ops *kind = transform_kind( handle );
    return kind ? kind->destroy( handle ) : STATUS_INVALID_HANDLE;
}

static NTSTATUS transform_get_output_type( wg_transform_t handle, struct wg_media_type *type )
{
    const struct wg_transform_ops *kind = transform_kind( handle );
    return kind ? kind->get_output_type( handle, type ) : STATUS_INVALID_HANDLE;
}

static NTSTATUS transform_set_output_type( wg_transform_t handle, const struct wg_media_type *type )
{
    const struct wg_transform_ops *kind = transform_kind( handle );
    return kind ? kind->set_output_type( handle, type ) : STATUS_INVALID_HANDLE;
}

/* `data` is passed separately from `sample` because struct wg_sample's `data`
 * member is a GUEST address for a 32-bit caller; see the wow64 table. */
static NTSTATUS transform_push_data( wg_transform_t handle, struct wg_sample *sample, const void *data,
                                     HRESULT *result )
{
    const struct wg_transform_ops *kind = transform_kind( handle );
    return kind ? kind->push_data( handle, sample, data, result ) : STATUS_INVALID_HANDLE;
}

static NTSTATUS transform_read_data( wg_transform_t handle, struct wg_sample *sample, void *data,
                                     HRESULT *result )
{
    const struct wg_transform_ops *kind = transform_kind( handle );
    return kind ? kind->read_data( handle, sample, data, result ) : STATUS_INVALID_HANDLE;
}

/***********************************************************************
 *           the unix call entries
 */
static NTSTATUS wma_init( void *args )
{
    struct wg_init_gstreamer_params *params = args;

    /* Benign success: main.c's init_gstreamer_proc() fails the whole DLL if
     * this fails, and everything this port implements is below it. */
    (void)params;
    return STATUS_SUCCESS;
}

static NTSTATUS wma_not_implemented( void *args )
{
    (void)args;
    return STATUS_NOT_IMPLEMENTED;
}

static NTSTATUS wg_transform_create( void *args )
{
    return transform_create( args );
}

static NTSTATUS wg_transform_destroy( void *args )
{
    return transform_destroy( *(wg_transform_t *)args );
}

static NTSTATUS wg_transform_get_output_type( void *args )
{
    struct wg_transform_get_output_type_params *params = args;
    return transform_get_output_type( params->transform, &params->media_type );
}

static NTSTATUS wg_transform_set_output_type( void *args )
{
    struct wg_transform_set_output_type_params *params = args;
    return transform_set_output_type( params->transform, &params->media_type );
}

static NTSTATUS wg_transform_push_data( void *args )
{
    struct wg_transform_push_data_params *params = args;
    struct wg_sample *sample = params->sample;

    if (!sample) return STATUS_INVALID_PARAMETER;
    return transform_push_data( params->transform, sample,
                                (const void *)(UINT_PTR)sample->data, &params->result );
}

static NTSTATUS wg_transform_read_data( void *args )
{
    struct wg_transform_read_data_params *params = args;
    struct wg_sample *sample = params->sample;

    if (!sample) return STATUS_INVALID_PARAMETER;
    return transform_read_data( params->transform, sample,
                                (void *)(UINT_PTR)sample->data, &params->result );
}

static NTSTATUS wg_transform_get_status( void *args )
{
    struct wg_transform_get_status_params *params = args;
    const struct wg_transform_ops *kind = transform_kind( params->transform );

    return kind ? kind->get_status( params->transform, &params->accepts_input ) : STATUS_INVALID_HANDLE;
}

static NTSTATUS wg_transform_drain( void *args )
{
    wg_transform_t handle = *(wg_transform_t *)args;
    const struct wg_transform_ops *kind = transform_kind( handle );

    return kind ? kind->drain( handle ) : STATUS_INVALID_HANDLE;
}

static NTSTATUS wg_transform_flush( void *args )
{
    wg_transform_t handle = *(wg_transform_t *)args;
    const struct wg_transform_ops *kind = transform_kind( handle );

    return kind ? kind->flush( handle ) : STATUS_INVALID_HANDLE;
}

static NTSTATUS wg_transform_notify_qos( void *args )
{
    /* Quality-of-service hints only change which frames a GStreamer pipeline
     * bothers to decode.  Neither kind drops frames (a WMV decoder that
     * skipped one would break the pictures that refer to it until the next
     * keyframe), and the caller ignores the status. */
    (void)args;
    return STATUS_SUCCESS;
}

/***********************************************************************
 *           wg_parser   (MADEIRA ml1980, ml1990)
 *
 * The Wine side of wg_parser_av_ios.c: handle validation, struct wg_format /
 * struct wg_parser_buffer mapping, and the HRESULTs wg_parser.c returns.
 * See that file's header for the protocol and what is accepted.
 *
 * MADEIRA_WG_PARSER=0 restores the pre-ml1980 behaviour: create is refused
 * with STATUS_NOT_IMPLEMENTED, so quartz_parser.c's parser_create() fails
 * exactly as before.
 *
 * ml1990: MP4/MOV (H.264 / HEVC video on VideoToolbox, AAC audio on
 * AudioToolbox, wg_parser_apple_ios.c).  MADEIRA_WG_VIDEO=0 restores the
 * ml1980 MP3/WAV-only behaviour (an MP4 is refused at connect).
 * MADEIRA_WG_VIDEO_FORMAT=nv12|i420|yv12|yuy2|rgb32|argb32|abgr32 picks the
 * native format a video stream reports.  Only the native format and
 * media_source.c's YUV list (NV12, YV12, YUY2, I420, IYUV) become media types.
 *
 * The default is rgb32, not the nv12 the hardware decoder produces.  A media
 * session resolves a source -> renderer branch with the source's current type
 * only, and that is the native one.  With nv12 the EVR accepts it (dxva2's
 * processor service lists NV12 without asking the device), and the session
 * then asks the EVR's sample allocator for NV12 Direct3D 9 surfaces.  This
 * port's d3d9 (DXMT) has no YUV surface format, so the allocator fails, and
 * session.c drops the renderer's output node and every node after it
 * (session_collect_nodes stops at the first failure).  The session still
 * reports itself started.  Nothing is requested from the source, the audio
 * renderer never gets the clock, and the title shows an empty video window
 * until it is killed: Senren Banka's 32-bit CG movie (MP4, H.264 1080p + AAC,
 * through krkrz's MFPlayer: media session, EVR, SAR).  RGB32 surfaces are
 * plain DXMT surfaces, and the YUV list still serves a consumer (a source
 * reader) that asks for NV12.  The cost is the NV12 -> BGRx conversion of
 * each picture on the CPU.  nv12 restores the previous default.
 *
 * A parser has up to MAV_MAX_STREAMS streams.  Each stream handle is a
 * separate object inside the parser so a parser handle passed as a stream
 * (or the reverse) is caught by the magic, not dereferenced.
 */
#define MADEIRA_WG_PARSER_MAGIC 0x57475052  /* 'WGPR' */
#define MADEIRA_WG_STREAM_MAGIC 0x57475354  /* 'WGST' */

struct wgp_parser;

struct wgp_stream
{
    UINT32 magic;
    UINT32 index;
    struct wgp_parser *parser;
};

struct wgp_parser
{
    UINT32 magic;
    struct mav_parser *core;
    struct wgp_stream streams[MAV_MAX_STREAMS];
};

C_ASSERT( (int)MAV_FMT_U8 == (int)WG_AUDIO_FORMAT_U8 && (int)MAV_FMT_S16 == (int)WG_AUDIO_FORMAT_S16LE
          && (int)MAV_FMT_S24 == (int)WG_AUDIO_FORMAT_S24LE && (int)MAV_FMT_S32 == (int)WG_AUDIO_FORMAT_S32LE
          && (int)MAV_FMT_F32 == (int)WG_AUDIO_FORMAT_F32LE && (int)MAV_FMT_F64 == (int)WG_AUDIO_FORMAT_F64LE );
C_ASSERT( (int)MAV_PIX_BGRA == (int)WG_VIDEO_FORMAT_BGRA && (int)MAV_PIX_BGRx == (int)WG_VIDEO_FORMAT_BGRx
          && (int)MAV_PIX_RGBA == (int)WG_VIDEO_FORMAT_RGBA && (int)MAV_PIX_I420 == (int)WG_VIDEO_FORMAT_I420
          && (int)MAV_PIX_NV12 == (int)WG_VIDEO_FORMAT_NV12 && (int)MAV_PIX_YUY2 == (int)WG_VIDEO_FORMAT_YUY2
          && (int)MAV_PIX_YV12 == (int)WG_VIDEO_FORMAT_YV12 && (int)MAV_PIX_BGR == (int)WG_VIDEO_FORMAT_BGR
          && (int)MAV_PIX_RGB15 == (int)WG_VIDEO_FORMAT_RGB15 && (int)MAV_PIX_RGB16 == (int)WG_VIDEO_FORMAT_RGB16
          && (int)MAV_PIX_UYVY == (int)WG_VIDEO_FORMAT_UYVY && (int)MAV_PIX_YVYU == (int)WG_VIDEO_FORMAT_YVYU );

static BOOL wg_parser_switch_on(void)
{
    const char *v = getenv( "MADEIRA_WG_PARSER" );
    return !(v && v[0] == '0' && !v[1]);
}

static BOOL wg_video_switch_on(void)
{
    const char *v = getenv( "MADEIRA_WG_VIDEO" );
    return !(v && v[0] == '0' && !v[1]);
}

/* Each decoded video stream decodes ahead on a thread of its own, so a request
 * for another stream on the same thread is not held up behind a picture
 * (mav_ahead_main).  0 decodes on the requesting thread, as before. */
static BOOL wg_video_ahead_switch_on(void)
{
    const char *v = getenv( "MADEIRA_WG_VIDEO_AHEAD" );
    return !(v && v[0] == '0' && !v[1]);
}

/* The WM reader's compressed samples of an ASF's WMV / WMA streams, for an
 * application's own decoder (KiriKiri's movie plugin and the decoder DMOs).
 * 0 refuses them as before: the reader then keeps its decoded streams. */
static BOOL wg_compressed_switch_on(void)
{
    const char *v = getenv( "MADEIRA_WG_COMPRESSED" );
    return !(v && v[0] == '0' && !v[1]);
}

static enum mav_pixel_format wg_video_native_format(void)
{
    static const struct { const char *name; enum mav_pixel_format fmt; } names[] =
    {
        { "nv12", MAV_PIX_NV12 }, { "i420", MAV_PIX_I420 }, { "iyuv", MAV_PIX_I420 },
        { "yv12", MAV_PIX_YV12 }, { "yuy2", MAV_PIX_YUY2 }, { "rgb32", MAV_PIX_BGRx },
        { "argb32", MAV_PIX_BGRA }, { "abgr32", MAV_PIX_RGBA },
    };
    const char *v = getenv( "MADEIRA_WG_VIDEO_FORMAT" );
    unsigned int i;

    if (!v || !*v) return MAV_PIX_BGRx;   /* rgb32: see above */
    for (i = 0; i < ARRAY_SIZE(names); i++)
        if (!strcasecmp( v, names[i].name )) return names[i].fmt;
    mav_log( "MADEIRA_WG_VIDEO_FORMAT=%.16s is not one of nv12/i420/yv12/yuy2/rgb32/argb32/abgr32; using rgb32", v );
    return MAV_PIX_BGRx;
}

static pthread_once_t wgp_config_once = PTHREAD_ONCE_INIT;

static void wgp_configure(void)
{
    BOOL video = wg_video_switch_on();
    enum mav_pixel_format native = wg_video_native_format();

    mav_allow_compressed_asf( wg_compressed_switch_on() );
    if (!wg_compressed_switch_on())
        mav_log( "compressed ASF output disabled by MADEIRA_WG_COMPRESSED=0" );
    mav_allow_video_ahead( wg_video_ahead_switch_on() );
    if (!wg_video_ahead_switch_on())
        mav_log( "video decode-ahead disabled by MADEIRA_WG_VIDEO_AHEAD=0: video decodes on the requesting thread" );

#ifdef __APPLE__
    mav_configure( video, &mav_apple_video_backend, &mav_apple_audio_backend, native );
    mav_log( "mp4/mov %s (MADEIRA_WG_VIDEO=0 disables): video on %s, aac on %s, native video format %s",
             video ? "enabled" : "disabled", mav_apple_video_backend.name, mav_apple_audio_backend.name,
             mav_pix_name( native ) );
#else
    mav_configure( FALSE, NULL, NULL, native );
#endif
}

static struct wgp_parser *get_wgp_parser( wg_parser_t handle )
{
    struct wgp_parser *parser = (struct wgp_parser *)(UINT_PTR)handle;

    if (!parser || parser->magic != MADEIRA_WG_PARSER_MAGIC) return NULL;
    return parser;
}

static struct wgp_parser *get_wgp_stream( wg_parser_stream_t handle, UINT32 *index )
{
    struct wgp_stream *stream = (struct wgp_stream *)(UINT_PTR)handle;

    if (!stream || stream->magic != MADEIRA_WG_STREAM_MAGIC) return NULL;
    if (!stream->parser || stream->parser->magic != MADEIRA_WG_PARSER_MAGIC) return NULL;
    if (stream->index >= MAV_MAX_STREAMS || &stream->parser->streams[stream->index] != stream) return NULL;
    *index = stream->index;
    return stream->parser;
}

/* The HRESULTs wg_parser.c / quartz_parser.c expect. */
static NTSTATUS wgp_status( int status )
{
    switch (status)
    {
    case MAV_OK:            return S_OK;
    case MAV_NO_BUFFER:     return S_FALSE;
    case MAV_E_STATE:       return VFW_E_WRONG_STATE;
    case MAV_E_UNSUPPORTED: return VFW_E_UNSUPPORTED_STREAM;
    case MAV_E_NOMEM:       return E_OUTOFMEMORY;
    case MAV_E_PARAM:       return STATUS_INVALID_PARAMETER;
    case MAV_E_IO:
    default:                return E_FAIL;
    }
}

static void wgp_format_from_output( struct wg_format *format, const struct mav_output *out )
{
    memset( format, 0, sizeof(*format) );
    format->major_type = WG_MAJOR_TYPE_AUDIO;
    format->u.audio.format = out->fmt;
    format->u.audio.channels = out->channels;
    format->u.audio.channel_mask = out->channel_mask;
    format->u.audio.rate = out->rate;
}

static void wgp_format_from_video( struct wg_format *format, const struct mav_video_output *out )
{
    memset( format, 0, sizeof(*format) );
    format->major_type = WG_MAJOR_TYPE_VIDEO;
    format->u.video.format = out->fmt;
    format->u.video.width = out->width;
    format->u.video.height = out->height;
    format->u.video.fps_n = out->fps_n;
    format->u.video.fps_d = out->fps_d;
}

static NTSTATUS wgp_create( void *args )
{
    struct wg_parser_create_params *params = args;
    struct wgp_parser *parser;
    unsigned int i;

    if (!wg_parser_switch_on())
    {
        static int once;
        if (!__atomic_exchange_n( &once, 1, __ATOMIC_RELAXED ))
            mav_log( "disabled by MADEIRA_WG_PARSER=0; parser creation refused" );
        return STATUS_NOT_IMPLEMENTED;
    }
    pthread_once( &wma_av_log_once, wma_install_av_log );
    pthread_once( &wgp_config_once, wgp_configure );
    if (!(parser = calloc( 1, sizeof(*parser) ))) return E_OUTOFMEMORY;
    if (!(parser->core = mav_create( params->output_compressed )))
    {
        free( parser );
        return E_OUTOFMEMORY;
    }
    parser->magic = MADEIRA_WG_PARSER_MAGIC;
    for (i = 0; i < MAV_MAX_STREAMS; i++)
    {
        parser->streams[i].magic = MADEIRA_WG_STREAM_MAGIC;
        parser->streams[i].index = i;
        parser->streams[i].parser = parser;
    }
    params->parser = (wg_parser_t)(UINT_PTR)parser;
    return S_OK;
}

static NTSTATUS wgp_destroy( void *args )
{
    struct wgp_parser *parser = get_wgp_parser( *(wg_parser_t *)args );
    unsigned int i;

    if (!parser) return STATUS_INVALID_HANDLE;
    mav_destroy( parser->core );
    parser->magic = 0;
    for (i = 0; i < MAV_MAX_STREAMS; i++) parser->streams[i].magic = 0;
    free( parser );
    return S_OK;
}

static NTSTATUS wgp_connect( wg_parser_t handle, UINT64 file_size )
{
    struct wgp_parser *parser = get_wgp_parser( handle );

    if (!parser) return STATUS_INVALID_HANDLE;
    return wgp_status( mav_connect( parser->core, file_size ) );
}

static NTSTATUS wgp_connect64( void *args )
{
    const struct wg_parser_connect_params *params = args;
    /* params->uri is only used by GStreamer's own URI source; data always
     * comes through the read protocol here. */
    return wgp_connect( params->parser, params->file_size );
}

static NTSTATUS wgp_disconnect( void *args )
{
    struct wgp_parser *parser = get_wgp_parser( *(wg_parser_t *)args );

    if (!parser) return STATUS_INVALID_HANDLE;
    mav_disconnect( parser->core );
    return S_OK;
}

static NTSTATUS wgp_get_next_read_offset( void *args )
{
    struct wg_parser_get_next_read_offset_params *params = args;
    struct wgp_parser *parser = get_wgp_parser( params->parser );
    uint64_t offset;
    uint32_t size;
    int status;

    if (!parser) return STATUS_INVALID_HANDLE;
    if ((status = mav_get_next_read_offset( parser->core, &offset, &size ))) return wgp_status( status );
    params->offset = offset;
    params->size = size;
    return S_OK;
}

static NTSTATUS wgp_push_data( wg_parser_t handle, const void *data, UINT32 size )
{
    struct wgp_parser *parser = get_wgp_parser( handle );

    if (!parser) return STATUS_INVALID_HANDLE;
    return wgp_status( mav_push_data( parser->core, data, size ) );
}

static NTSTATUS wgp_push_data64( void *args )
{
    const struct wg_parser_push_data_params *params = args;
    return wgp_push_data( params->parser, params->data, params->size );
}

static NTSTATUS wgp_get_stream_count( void *args )
{
    struct wg_parser_get_stream_count_params *params = args;
    struct wgp_parser *parser = get_wgp_parser( params->parser );

    if (!parser) return STATUS_INVALID_HANDLE;
    params->count = mav_stream_count( parser->core );
    return S_OK;
}

static NTSTATUS wgp_get_stream( void *args )
{
    struct wg_parser_get_stream_params *params = args;
    struct wgp_parser *parser = get_wgp_parser( params->parser );

    if (!parser) return STATUS_INVALID_HANDLE;
    if (params->index >= mav_stream_count( parser->core ) || params->index >= MAV_MAX_STREAMS)
    {
        params->stream = 0;
        return STATUS_INVALID_PARAMETER;
    }
    params->stream = (wg_parser_stream_t)(UINT_PTR)&parser->streams[params->index];
    return S_OK;
}

static NTSTATUS wgp_get_codec_format( wg_parser_stream_t handle, struct wg_format *format );

static NTSTATUS wgp_get_current_format( wg_parser_stream_t handle, struct wg_format *format )
{
    UINT32 index;
    struct wgp_parser *parser = get_wgp_stream( handle, &index );
    struct mav_stream_info info;
    struct mav_video_output vout;
    struct mav_output out;

    if (!parser) return STATUS_INVALID_HANDLE;
    if (!format) return STATUS_INVALID_PARAMETER;
    /* wg_parser.c: a compressed-output parser's pad has the compressed caps
     * (what the WM reader enables a compressed-reading stream with) */
    if (mav_can_pass_compressed( parser->core, index )) return wgp_get_codec_format( handle, format );
    /* wg_parser.c: a stream without caps reports an all-zero format (UNKNOWN) */
    memset( format, 0, sizeof(*format) );
    if (mav_stream_info( parser->core, index, &info )) return S_OK;
    if (info.type == MAV_STREAM_VIDEO)
    {
        if (!mav_current_video( parser->core, index, &vout )) wgp_format_from_video( format, &vout );
    }
    else if (!mav_current_output( parser->core, index, &out ))
        wgp_format_from_output( format, &out );
    return S_OK;
}

static NTSTATUS wgp_get_current_format64( void *args )
{
    const struct wg_parser_stream_get_current_format_params *params = args;
    return wgp_get_current_format( params->stream, params->format );
}

/* The compressed format (what a separate decoder would be given), or the
 * current one for PCM -- wg_parser.c's caps_is_compressed() split.  Only the
 * compressed formats unixlib.h can describe are reported as such. */
static NTSTATUS wgp_get_codec_format( wg_parser_stream_t handle, struct wg_format *format )
{
    UINT32 index;
    struct wgp_parser *parser = get_wgp_stream( handle, &index );
    struct mav_stream_info info;

    if (!parser) return STATUS_INVALID_HANDLE;
    if (!format) return STATUS_INVALID_PARAMETER;
    if (mav_stream_info( parser->core, index, &info ))
    {
        memset( format, 0, sizeof(*format) );
        return S_OK;
    }
    switch (info.kind)
    {
    case MAV_CODEC_MPEG_AUDIO:
        memset( format, 0, sizeof(*format) );
        format->major_type = WG_MAJOR_TYPE_AUDIO_MPEG1;
        format->u.audio.layer = info.layer;
        format->u.audio.channels = info.native.channels;
        format->u.audio.rate = info.native.rate;
        format->u.audio.bitrate = info.bitrate;
        return S_OK;
    case MAV_CODEC_AAC:
        memset( format, 0, sizeof(*format) );
        format->major_type = WG_MAJOR_TYPE_AUDIO_MPEG4;
        format->u.audio.payload_type = 0;   /* raw access units */
        format->u.audio.codec_data_len = info.codec_data_len < sizeof(format->u.audio.codec_data) ? info.codec_data_len : sizeof(format->u.audio.codec_data);
        memcpy( format->u.audio.codec_data, info.codec_data, format->u.audio.codec_data_len );
        format->u.audio.channels = info.native.channels;
        format->u.audio.rate = info.native.rate;
        return S_OK;
    case MAV_CODEC_WMA:
        /* what the WM reader's stream configuration (and a game reading the
         * file's profile) describes the stream by */
        memset( format, 0, sizeof(*format) );
        format->major_type = WG_MAJOR_TYPE_AUDIO_WMA;
        format->u.audio.version = info.version;
        format->u.audio.bitrate = info.bitrate;
        format->u.audio.rate = info.native.rate;
        format->u.audio.depth = info.depth;
        format->u.audio.channels = info.native.channels;
        format->u.audio.block_align = info.block_align;
        format->u.audio.codec_data_len = info.codec_data_len < sizeof(format->u.audio.codec_data) ? info.codec_data_len : sizeof(format->u.audio.codec_data);
        memcpy( format->u.audio.codec_data, info.codec_data, format->u.audio.codec_data_len );
        return S_OK;
    case MAV_CODEC_WMV:
    {
        static const wg_video_format wmv[] =
        {
            [MAV_WMV_WMV1] = WG_VIDEO_FORMAT_WMV1, [MAV_WMV_WMV2] = WG_VIDEO_FORMAT_WMV2,
            [MAV_WMV_WMV3] = WG_VIDEO_FORMAT_WMV3, [MAV_WMV_WMVA] = WG_VIDEO_FORMAT_WMVA,
            [MAV_WMV_WVC1] = WG_VIDEO_FORMAT_WVC1,
        };
        /* the MS-MPEG4 family has no wg_format: its current (decoded) format stands in */
        if (info.wmv == MAV_WMV_NONE || (unsigned)info.wmv >= ARRAY_SIZE(wmv)) return wgp_get_current_format( handle, format );
        memset( format, 0, sizeof(*format) );
        format->major_type = WG_MAJOR_TYPE_VIDEO_WMV;
        format->u.video.format = wmv[info.wmv];
        format->u.video.width = info.vnative.width;
        format->u.video.height = info.vnative.height;
        format->u.video.fps_n = info.vnative.fps_n;
        format->u.video.fps_d = info.vnative.fps_d;
        format->u.video.codec_data_len = info.codec_data_len < sizeof(format->u.video.codec_data) ? info.codec_data_len : sizeof(format->u.video.codec_data);
        memcpy( format->u.video.codec_data, info.codec_data, format->u.video.codec_data_len );
        return S_OK;
    }
    case MAV_CODEC_H264:
        memset( format, 0, sizeof(*format) );
        format->major_type = WG_MAJOR_TYPE_VIDEO_H264;
        format->u.video.width = info.vnative.width;
        format->u.video.height = info.vnative.height;
        format->u.video.fps_n = info.vnative.fps_n;
        format->u.video.fps_d = info.vnative.fps_d;
        format->u.video.profile = info.profile;
        format->u.video.level = info.level;
        /* codec_data stays empty: wg_format's H.264 codec data is an Annex B
         * sequence header, and the container holds avcC -- reporting one as
         * the other would be wrong data, not missing data. */
        return S_OK;
    default:
        return wgp_get_current_format( handle, format );
    }
}

static NTSTATUS wgp_get_codec_format64( void *args )
{
    const struct wg_parser_stream_get_codec_format_params *params = args;
    return wgp_get_codec_format( params->stream, params->format );
}

static NTSTATUS wgp_enable( wg_parser_stream_t handle, const struct wg_format *format )
{
    UINT32 index;
    struct wgp_parser *parser = get_wgp_stream( handle, &index );
    struct mav_stream_info info;
    int status;

    if (!parser) return STATUS_INVALID_HANDLE;
    if (!format) return STATUS_INVALID_PARAMETER;
    if (mav_stream_info( parser->core, index, &info )) return VFW_E_WRONG_STATE;

    if (format->major_type == WG_MAJOR_TYPE_VIDEO_WMV || format->major_type == WG_MAJOR_TYPE_AUDIO_WMA)
    {
        /* the demuxer's packets, as get_current_format describes them */
        if ((format->major_type == WG_MAJOR_TYPE_VIDEO_WMV) != (info.type == MAV_STREAM_VIDEO))
            status = MAV_E_PARAM;
        else
            status = mav_enable_compressed( parser->core, index );
        if (status)
        {
            mav_disable( parser->core, index );
            mav_log( "stream %u: enable refused: compressed output (major type %u) of %s", index,
                     format->major_type, info.codec );
            return wgp_status( status );
        }
        return S_OK;
    }

    if (info.type == MAV_STREAM_VIDEO)
    {
        struct mav_video_output out;

        if (format->major_type != WG_MAJOR_TYPE_VIDEO)
        {
            /* only decoded pictures and Windows Media packets are produced
             * here; the stream stays disabled */
            mav_disable( parser->core, index );
            mav_log( "stream %u: enable refused: major type %u is not raw video", index, format->major_type );
            return STATUS_NOT_SUPPORTED;
        }
        out.fmt = format->u.video.format;
        out.width = format->u.video.width;
        out.height = format->u.video.height;
        out.fps_n = format->u.video.fps_n;
        out.fps_d = format->u.video.fps_d;
        if ((status = mav_enable_video( parser->core, index, &out )))
        {
            mav_log( "stream %u: enable refused: video format %u %dx%d (native %s %dx%d)", index, out.fmt,
                     out.width, out.height, mav_pix_name( info.vnative.fmt ), info.vnative.width,
                     info.vnative.height );
            return wgp_status( status );
        }
        return S_OK;
    }
    else
    {
        struct mav_output out;

        if (format->major_type != WG_MAJOR_TYPE_AUDIO)
        {
            /* only decoded PCM and Windows Media packets are produced here;
             * the stream stays disabled */
            mav_disable( parser->core, index );
            mav_log( "enable refused: major type %u is not PCM audio", format->major_type );
            return STATUS_NOT_SUPPORTED;
        }
        out.fmt = format->u.audio.format;
        out.rate = format->u.audio.rate;
        out.channels = format->u.audio.channels;
        out.channel_mask = format->u.audio.channel_mask;
        if ((status = mav_enable( parser->core, index, &out )))
        {
            mav_log( "enable refused: format %u rate %u channels %u", out.fmt, out.rate, out.channels );
            return wgp_status( status );
        }
        return S_OK;
    }
}

static NTSTATUS wgp_enable64( void *args )
{
    const struct wg_parser_stream_enable_params *params = args;
    return wgp_enable( params->stream, params->format );
}

static NTSTATUS wgp_disable( void *args )
{
    UINT32 index;
    struct wgp_parser *parser = get_wgp_stream( *(wg_parser_stream_t *)args, &index );

    if (!parser) return STATUS_INVALID_HANDLE;
    mav_disable( parser->core, index );
    return S_OK;
}

/* `stream` may be 0 ("the earliest buffer of any stream", used by the WM
 * reader); buffer->stream then says which one it is. */
static NTSTATUS wgp_get_buffer( wg_parser_t parser_handle, wg_parser_stream_t stream_handle,
                                struct wg_parser_buffer *buffer )
{
    struct wgp_parser *parser = get_wgp_parser( parser_handle );
    struct mav_buffer buf;
    UINT32 index = 0;
    int status;

    if (!parser) return STATUS_INVALID_HANDLE;
    if (stream_handle && get_wgp_stream( stream_handle, &index ) != parser) return STATUS_INVALID_HANDLE;
    if (!buffer) return STATUS_INVALID_PARAMETER;
    if ((status = mav_get_buffer( parser->core, stream_handle ? (int)index : -1, &buf )))
        return wgp_status( status );

    memset( buffer, 0, sizeof(*buffer) );
    buffer->pts = buf.pts;
    buffer->duration = buf.duration;
    buffer->size = buf.size;
    buffer->stream = buf.stream;
    buffer->discontinuity = !!buf.discontinuity;
    buffer->delta = !!buf.delta;
    buffer->has_pts = 1;
    buffer->has_duration = 1;
    return S_OK;
}

static NTSTATUS wgp_get_buffer64( void *args )
{
    const struct wg_parser_stream_get_buffer_params *params = args;
    return wgp_get_buffer( params->parser, params->stream, params->buffer );
}

static NTSTATUS wgp_copy_buffer( wg_parser_stream_t handle, void *data, UINT32 offset, UINT32 size )
{
    UINT32 index;
    struct wgp_parser *parser = get_wgp_stream( handle, &index );

    if (!parser) return STATUS_INVALID_HANDLE;
    return wgp_status( mav_copy_buffer( parser->core, index, data, offset, size ) );
}

static NTSTATUS wgp_copy_buffer64( void *args )
{
    const struct wg_parser_stream_copy_buffer_params *params = args;
    return wgp_copy_buffer( params->stream, params->data, params->offset, params->size );
}

static NTSTATUS wgp_release_buffer( void *args )
{
    UINT32 index;
    struct wgp_parser *parser = get_wgp_stream( *(wg_parser_stream_t *)args, &index );

    if (!parser) return STATUS_INVALID_HANDLE;
    mav_release_buffer( parser->core, index );
    return S_OK;
}

static NTSTATUS wgp_notify_qos( void *args )
{
    const struct wg_parser_stream_notify_qos_params *params = args;
    UINT32 index;

    /* QoS only tells a GStreamer pipeline which frames it may drop; this
     * core decodes on demand and drops nothing, so there is nothing to do and
     * nothing to report back (the PE side ignores the status). */
    if (!get_wgp_stream( params->stream, &index )) return STATUS_INVALID_HANDLE;
    return S_OK;
}

static NTSTATUS wgp_get_duration( void *args )
{
    struct wg_parser_stream_get_duration_params *params = args;
    UINT32 index;
    struct wgp_parser *parser = get_wgp_stream( params->stream, &index );
    struct mav_stream_info info;

    if (!parser) return STATUS_INVALID_HANDLE;
    /* wg_parser.c reports 0 when the duration could not be determined */
    params->duration = mav_stream_info( parser->core, index, &info ) ? 0 : info.duration;
    return S_OK;
}

/* No tags are extracted: STATUS_NOT_FOUND is wg_parser.c's "this stream has
 * no such tag", which main.c turns into a NULL string. */
static NTSTATUS wgp_get_tag( wg_parser_stream_t handle, wg_parser_tag tag )
{
    UINT32 index;

    if (!get_wgp_stream( handle, &index )) return STATUS_INVALID_HANDLE;
    if (tag >= WG_PARSER_TAG_COUNT) return STATUS_INVALID_PARAMETER;
    return STATUS_NOT_FOUND;
}

static NTSTATUS wgp_get_tag64( void *args )
{
    const struct wg_parser_stream_get_tag_params *params = args;
    return wgp_get_tag( params->stream, params->tag );
}

static NTSTATUS wgp_seek( void *args )
{
    const struct wg_parser_stream_seek_params *params = args;
    UINT32 index;
    struct wgp_parser *parser = get_wgp_stream( params->stream, &index );
    BOOL set_start, set_stop;

    if (!parser) return STATUS_INVALID_HANDLE;
    set_start = (params->start_flags & AM_SEEKING_PositioningBitsMask) != AM_SEEKING_NoPositioning;
    set_stop = (params->stop_flags & AM_SEEKING_PositioningBitsMask) != AM_SEEKING_NoPositioning;
    /* rate: the PE side scales timestamps itself (send_sample); the streams
     * are decoded the same at any rate.  Seeking one stream seeks all of
     * them, as a GStreamer seek on one pad does. */
    return wgp_status( mav_seek( parser->core, index, set_start, params->start_pos, set_stop, params->stop_pos ) );
}

/* A 64-bit (ARM64EC) caller has this table by default for the WMA decoder
 * (virtual_ios.c, ios_wg_64bit_enabled); its parser is refused as before
 * unless MADEIRA_WG_64BIT=1. */
static NTSTATUS wgp_create64( void *args )
{
    const char *e = getenv( "MADEIRA_WG_64BIT" );
    if (!(e && e[0] == '1')) return STATUS_NOT_IMPLEMENTED;
    return wgp_create( args );
}

/* The index layout below is dlls/winegstreamer/unixlib.h `enum unix_funcs`,
 * entry for entry.  Do not reorder; add new entries only where the header
 * adds them. */
const unixlib_entry_t __wine_unix_call_funcs[] =
{
    wma_init,                           /* unix_wg_init_gstreamer */

    wgp_create64,                       /* unix_wg_parser_create */
    wgp_destroy,                        /* unix_wg_parser_destroy */

    wgp_connect64,                      /* unix_wg_parser_connect */
    wgp_disconnect,                     /* unix_wg_parser_disconnect */

    wgp_get_next_read_offset,           /* unix_wg_parser_get_next_read_offset */
    wgp_push_data64,                    /* unix_wg_parser_push_data */

    wgp_get_stream_count,               /* unix_wg_parser_get_stream_count */
    wgp_get_stream,                     /* unix_wg_parser_get_stream */

    wgp_get_current_format64,           /* unix_wg_parser_stream_get_current_format */
    wgp_get_codec_format64,             /* unix_wg_parser_stream_get_codec_format */
    wgp_enable64,                       /* unix_wg_parser_stream_enable */
    wgp_disable,                        /* unix_wg_parser_stream_disable */

    wgp_get_buffer64,                   /* unix_wg_parser_stream_get_buffer */
    wgp_copy_buffer64,                  /* unix_wg_parser_stream_copy_buffer */
    wgp_release_buffer,                 /* unix_wg_parser_stream_release_buffer */
    wgp_notify_qos,                     /* unix_wg_parser_stream_notify_qos */

    wgp_get_duration,                   /* unix_wg_parser_stream_get_duration */
    wgp_get_tag64,                      /* unix_wg_parser_stream_get_tag */
    wgp_seek,                           /* unix_wg_parser_stream_seek */

    wg_transform_create,                /* unix_wg_transform_create */
    wg_transform_destroy,               /* unix_wg_transform_destroy */
    wg_transform_get_output_type,       /* unix_wg_transform_get_output_type */
    wg_transform_set_output_type,       /* unix_wg_transform_set_output_type */

    wg_transform_push_data,             /* unix_wg_transform_push_data */
    wg_transform_read_data,             /* unix_wg_transform_read_data */
    wg_transform_get_status,            /* unix_wg_transform_get_status */
    wg_transform_drain,                 /* unix_wg_transform_drain */
    wg_transform_flush,                 /* unix_wg_transform_flush */
    wg_transform_notify_qos,            /* unix_wg_transform_notify_qos */

    wma_not_implemented,                /* unix_wg_muxer_create */
    wma_not_implemented,                /* unix_wg_muxer_destroy */
    wma_not_implemented,                /* unix_wg_muxer_add_stream */
    wma_not_implemented,                /* unix_wg_muxer_start */
    wma_not_implemented,                /* unix_wg_muxer_push_sample */
    wma_not_implemented,                /* unix_wg_muxer_read_data */
    wma_not_implemented,                /* unix_wg_muxer_finalize */
};

C_ASSERT( ARRAY_SIZE(__wine_unix_call_funcs) == unix_wg_funcs_count );

/***********************************************************************
 *           the wow64 table
 *
 * dlls/winegstreamer/unixlib.h has NO `#ifdef _WIN64` 32-bit param structs --
 * upstream's unixlib is only ever entered from a matching-bitness PE because
 * wow64.dll thunks winegstreamer through its own table.  So the 32-bit layouts
 * are written out here, the way nsi_unixlib_ios.c writes struct
 * nsi_enumerate_all_ex32.
 *
 * Only three shapes actually differ:
 *
 *   struct wg_media_type   the union is a POINTER, so it sits at +20 with the
 *                          struct 24 bytes long, against +24 / 32 bytes here.
 *   ..._push/read_data     `struct wg_sample *sample` is 4 bytes, moving
 *                          `result` from +16 to +12.
 *   struct wg_sample       identical in both builds -- every member is
 *                          fixed-width and i386 aligns INT64/UINT64 to 8 like
 *                          the host -- but its `data` member holds a GUEST
 *                          address, so only that VALUE is converted.
 *
 * The block a wg_media_type points at is used in place, audio and video
 * alike: a WAVEFORMATEX(-EXTENSIBLE) or an MFVIDEOFORMAT, with its codec
 * data after it, is fixed-width and laid out identically by i686-w64-mingw32
 * and the host (checked with llvm-mingw; the C_ASSERTs at the WMV decoder pin
 * MFVIDEOFORMAT).  The offsets asserted below are the i386 ones, measured the
 * same way.
 *
 * Everything else in the table takes either a bare wg_transform_t (a UINT64,
 * same in both) or a block of fixed-width scalars at identical offsets, so
 * those entries are shared with the 64-bit table rather than re-thunked: a
 * thunk that only copies fields is a second place for the layout to drift.
 */
typedef ULONG PTR32;

struct wg_media_type32
{
    GUID  major;
    UINT32 format_size;
    PTR32 format;
};
C_ASSERT( sizeof(struct wg_media_type32) == 24 );

struct wg_transform_create_params32
{
    wg_transform_t transform;
    struct wg_media_type32 input_type;
    struct wg_media_type32 output_type;
    struct wg_transform_attrs attrs;
};

struct wg_transform_sample_params32
{
    wg_transform_t transform;
    PTR32 sample;
    HRESULT result;
};

struct wg_transform_output_type_params32
{
    wg_transform_t transform;
    struct wg_media_type32 media_type;
};

C_ASSERT( offsetof(struct wg_transform_create_params32, output_type) == 32 );
C_ASSERT( offsetof(struct wg_transform_create_params32, attrs) == 56 );
C_ASSERT( sizeof(struct wg_transform_create_params32) == 80 );
C_ASSERT( offsetof(struct wg_transform_sample_params32, result) == 12 );
C_ASSERT( sizeof(struct wg_transform_output_type_params32) == 32 );
C_ASSERT( sizeof(struct wg_sample) == 48 && offsetof(struct wg_sample, data) == 40 );

static void media_type_from32( struct wg_media_type *type, const struct wg_media_type32 *type32 )
{
    type->major = type32->major;
    type->format_size = type32->format_size;
    type->u.format = ios_wow_host_ptr( type32->format );
}

static NTSTATUS wow64_wg_transform_create( void *args )
{
    struct wg_transform_create_params32 *params32 = args;
    struct wg_transform_create_params params;
    NTSTATUS status;

    if (!params32) return STATUS_INVALID_PARAMETER;

    memset( &params, 0, sizeof(params) );
    media_type_from32( &params.input_type, &params32->input_type );
    media_type_from32( &params.output_type, &params32->output_type );
    params.attrs = params32->attrs;

    status = transform_create( &params );
    params32->transform = params.transform;
    return status;
}

/* `sample` is a guest pointer; the struct it points at has the same layout in
 * both builds, so it is used in place and only sample->data is converted. */
static NTSTATUS wow64_wg_transform_push_data( void *args )
{
    struct wg_transform_sample_params32 *params32 = args;
    struct wg_sample *sample;

    if (!params32) return STATUS_INVALID_PARAMETER;
    if (!(sample = ios_wow_host_ptr( params32->sample ))) return STATUS_INVALID_PARAMETER;
    return transform_push_data( params32->transform, sample,
                                ios_wow_host_ptr( (ULONG)sample->data ), &params32->result );
}

static NTSTATUS wow64_wg_transform_read_data( void *args )
{
    struct wg_transform_sample_params32 *params32 = args;
    struct wg_sample *sample;

    if (!params32) return STATUS_INVALID_PARAMETER;
    if (!(sample = ios_wow_host_ptr( params32->sample ))) return STATUS_INVALID_PARAMETER;
    return transform_read_data( params32->transform, sample,
                                ios_wow_host_ptr( (ULONG)sample->data ), &params32->result );
}

static NTSTATUS wow64_wg_transform_get_output_type( void *args )
{
    struct wg_transform_output_type_params32 *params32 = args;
    struct wg_media_type type;
    NTSTATUS status;

    if (!params32) return STATUS_INVALID_PARAMETER;
    media_type_from32( &type, &params32->media_type );
    status = transform_get_output_type( params32->transform, &type );
    /* OUT: the major type and the size the PE side must allocate.  The format
     * pointer itself is the caller's and is never written back. */
    params32->media_type.major = type.major;
    params32->media_type.format_size = type.format_size;
    return status;
}

static NTSTATUS wow64_wg_transform_set_output_type( void *args )
{
    struct wg_transform_output_type_params32 *params32 = args;
    struct wg_media_type type;

    if (!params32) return STATUS_INVALID_PARAMETER;
    media_type_from32( &type, &params32->media_type );
    return transform_set_output_type( params32->transform, &type );
}

/* ml1980: the wg_parser entries whose argument block holds a pointer -- the
 * same set upstream wg_parser.c thunks with X64() -- converted here.  The rest
 * (create, destroy, disconnect, get_next_read_offset, get_stream_count,
 * get_stream, disable, release_buffer, notify_qos, get_duration, seek) carry
 * only handles and fixed-width scalars, which i386 lays out exactly like the
 * host (INT64/UINT64/DOUBLE are 8-aligned in the PE ABI), so they share the
 * 64-bit entries.  struct wg_format and struct wg_parser_buffer are
 * fixed-width too; only the pointers TO them are guest addresses. */
struct wg_parser_connect_params32
{
    wg_parser_t parser;
    PTR32 uri;
    UINT64 file_size;
};
C_ASSERT( offsetof(struct wg_parser_connect_params32, file_size) == 16 );

struct wg_parser_push_data_params32
{
    wg_parser_t parser;
    PTR32 data;
    UINT32 size;
};
C_ASSERT( sizeof(struct wg_parser_push_data_params32) == 16 );

struct wg_parser_stream_format_params32
{
    wg_parser_stream_t stream;
    PTR32 format;
};

struct wg_parser_stream_get_buffer_params32
{
    wg_parser_t parser;
    wg_parser_stream_t stream;
    PTR32 buffer;
};

struct wg_parser_stream_copy_buffer_params32
{
    wg_parser_stream_t stream;
    PTR32 data;
    UINT32 offset;
    UINT32 size;
};
C_ASSERT( offsetof(struct wg_parser_stream_copy_buffer_params32, size) == 16 );

struct wg_parser_stream_get_tag_params32
{
    wg_parser_stream_t stream;
    wg_parser_tag tag;
    PTR32 buffer;
    PTR32 size;
};

C_ASSERT( sizeof(struct wg_format) == 120 );
C_ASSERT( sizeof(struct wg_parser_buffer) == 32 );
C_ASSERT( offsetof(struct wg_parser_stream_seek_params, stop_flags) == 36 );
C_ASSERT( offsetof(struct wg_parser_stream_notify_qos_params, timestamp) == 32 );
C_ASSERT( offsetof(struct wg_parser_get_next_read_offset_params, offset) == 16 );

static NTSTATUS wow64_wgp_connect( void *args )
{
    const struct wg_parser_connect_params32 *params32 = args;
    return wgp_connect( params32->parser, params32->file_size );
}

static NTSTATUS wow64_wgp_push_data( void *args )
{
    const struct wg_parser_push_data_params32 *params32 = args;
    return wgp_push_data( params32->parser, ios_wow_host_ptr( params32->data ), params32->size );
}

static NTSTATUS wow64_wgp_get_current_format( void *args )
{
    const struct wg_parser_stream_format_params32 *params32 = args;
    return wgp_get_current_format( params32->stream, ios_wow_host_ptr( params32->format ) );
}

static NTSTATUS wow64_wgp_get_codec_format( void *args )
{
    const struct wg_parser_stream_format_params32 *params32 = args;
    return wgp_get_codec_format( params32->stream, ios_wow_host_ptr( params32->format ) );
}

static NTSTATUS wow64_wgp_enable( void *args )
{
    const struct wg_parser_stream_format_params32 *params32 = args;
    return wgp_enable( params32->stream, ios_wow_host_ptr( params32->format ) );
}

static NTSTATUS wow64_wgp_get_buffer( void *args )
{
    const struct wg_parser_stream_get_buffer_params32 *params32 = args;
    return wgp_get_buffer( params32->parser, params32->stream, ios_wow_host_ptr( params32->buffer ) );
}

static NTSTATUS wow64_wgp_copy_buffer( void *args )
{
    const struct wg_parser_stream_copy_buffer_params32 *params32 = args;
    return wgp_copy_buffer( params32->stream, ios_wow_host_ptr( params32->data ),
                            params32->offset, params32->size );
}

static NTSTATUS wow64_wgp_get_tag( void *args )
{
    const struct wg_parser_stream_get_tag_params32 *params32 = args;
    /* buffer / size are never dereferenced: no tag is ever found */
    return wgp_get_tag( params32->stream, params32->tag );
}

const unixlib_entry_t __wine_unix_call_wow64_funcs[] =
{
    wma_init,                             /* unix_wg_init_gstreamer */

    wgp_create,                           /* unix_wg_parser_create */
    wgp_destroy,                          /* unix_wg_parser_destroy */

    wow64_wgp_connect,                    /* unix_wg_parser_connect */
    wgp_disconnect,                       /* unix_wg_parser_disconnect */

    wgp_get_next_read_offset,             /* unix_wg_parser_get_next_read_offset */
    wow64_wgp_push_data,                  /* unix_wg_parser_push_data */

    wgp_get_stream_count,                 /* unix_wg_parser_get_stream_count */
    wgp_get_stream,                       /* unix_wg_parser_get_stream */

    wow64_wgp_get_current_format,         /* unix_wg_parser_stream_get_current_format */
    wow64_wgp_get_codec_format,           /* unix_wg_parser_stream_get_codec_format */
    wow64_wgp_enable,                     /* unix_wg_parser_stream_enable */
    wgp_disable,                          /* unix_wg_parser_stream_disable */

    wow64_wgp_get_buffer,                 /* unix_wg_parser_stream_get_buffer */
    wow64_wgp_copy_buffer,                /* unix_wg_parser_stream_copy_buffer */
    wgp_release_buffer,                   /* unix_wg_parser_stream_release_buffer */
    wgp_notify_qos,                       /* unix_wg_parser_stream_notify_qos */

    wgp_get_duration,                     /* unix_wg_parser_stream_get_duration */
    wow64_wgp_get_tag,                    /* unix_wg_parser_stream_get_tag */
    wgp_seek,                             /* unix_wg_parser_stream_seek */

    wow64_wg_transform_create,            /* unix_wg_transform_create */
    wg_transform_destroy,                 /* unix_wg_transform_destroy */
    wow64_wg_transform_get_output_type,   /* unix_wg_transform_get_output_type */
    wow64_wg_transform_set_output_type,   /* unix_wg_transform_set_output_type */

    wow64_wg_transform_push_data,         /* unix_wg_transform_push_data */
    wow64_wg_transform_read_data,         /* unix_wg_transform_read_data */
    wg_transform_get_status,              /* unix_wg_transform_get_status */
    wg_transform_drain,                   /* unix_wg_transform_drain */
    wg_transform_flush,                   /* unix_wg_transform_flush */
    wg_transform_notify_qos,              /* unix_wg_transform_notify_qos */

    wma_not_implemented,                  /* unix_wg_muxer_create */
    wma_not_implemented,                  /* unix_wg_muxer_destroy */
    wma_not_implemented,                  /* unix_wg_muxer_add_stream */
    wma_not_implemented,                  /* unix_wg_muxer_start */
    wma_not_implemented,                  /* unix_wg_muxer_push_sample */
    wma_not_implemented,                  /* unix_wg_muxer_read_data */
    wma_not_implemented,                  /* unix_wg_muxer_finalize */
};

C_ASSERT( ARRAY_SIZE(__wine_unix_call_wow64_funcs) == unix_wg_funcs_count );
