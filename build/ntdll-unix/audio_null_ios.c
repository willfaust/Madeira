/*
 * audio_null_ios.c — minimal Wine audio "null" driver for iOS Madeira.
 *
 * Wine's mmdevapi loads a `wine<name>.drv` PE plus a unix-side function
 * table (37 entries). On Linux/macOS the unix table is a separate .so.
 * On iOS we statically link the table into Madeira.app — this file is
 * that table for "ios" / "coreaudio".
 *
 * Behaviour: ONE fake render endpoint, accepts buffer submissions and
 * discards, advances IAudioClock at real-time based on
 * mach_absolute_time. Enough to let FMOD's clock-driven timing
 * advance (rhythm games like Thumper gate splash→title on intro
 * music completing — this is what makes that work).
 *
 * 2026-07-05 TIER-2: REAL AUDIO OUTPUT via a RemoteIO AudioUnit.
 * WASAPI render semantics map onto a lock-free ring buffer:
 *   get_render_buffer  -> contiguous scratch pointer
 *   release_render_buffer -> copy scratch into the ring, advance write_pos
 *   RemoteIO render callback (Core Audio real-time thread — touches ONLY
 *   the ring + atomics, never Wine) -> copy ring to hardware, advance
 *   play_pos; underrun plays silence
 *   get_current_padding -> write_pos - play_pos
 *   get_position        -> play_pos (frames actually consumed)
 *   timer_loop          -> Wine thread; signals the client event per period
 * If AudioUnit setup fails (no session, etc.) the driver degrades to the
 * Tier-1 wall-clock null behaviour so game timing never breaks.
 * AVAudioSession activation happens app-side (WineProcessBridge.m).
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <unistd.h>
#include <time.h>
#include <AudioToolbox/AudioToolbox.h>

/* Struct/enum mirrors from wine/dlls/mmdevapi/unixlib.h. Repeating the
 * essential layout here avoids include-path drama with Wine's COM
 * headers, which pull in <objbase.h>/<audioclient.h>. We only need the
 * struct fields the unix-call dispatch touches. */

typedef int NTSTATUS;
typedef uint16_t WCHAR;
typedef int32_t HRESULT;
typedef uint32_t DWORD;
typedef uint32_t UINT32;
typedef uint64_t UINT64;
typedef uint64_t UINT_PTR;
typedef uint32_t UINT;
typedef int BOOL;
typedef uint8_t BYTE;
typedef int64_t REFERENCE_TIME;
typedef void *HANDLE;
typedef uint16_t WORD;
typedef uint64_t stream_handle;
typedef int EDataFlow;

#define STATUS_SUCCESS 0
#define S_OK 0
#define E_OUTOFMEMORY ((HRESULT)0x8007000EL)
#define AUDCLNT_E_NOT_INITIALIZED ((HRESULT)0x88890001L)
#define S_FALSE 1
#define E_FAIL 0x80004005L
#define AUDCLNT_E_NOT_INITIALIZED 0x88890001L

#define eRender 0
#define eCapture 1

enum driver_priority {
    Priority_Unavailable = 0,
    Priority_Low,
    Priority_Neutral,
    Priority_Preferred
};

struct endpoint {
    unsigned int name;
    unsigned int device;
};

struct main_loop_params { HANDLE event; };

struct get_endpoint_ids_params {
    EDataFlow flow;
    struct endpoint *endpoints;
    unsigned int size;
    HRESULT result;
    unsigned int num;
    unsigned int default_idx;
};

struct WAVEFORMATEX_stub {
    WORD wFormatTag;
    WORD nChannels;
    DWORD nSamplesPerSec;
    DWORD nAvgBytesPerSec;
    WORD nBlockAlign;
    WORD wBitsPerSample;
    WORD cbSize;
};

struct create_stream_params {
    const WCHAR *name;
    const char *device;
    EDataFlow flow;
    int share;
    DWORD flags;
    REFERENCE_TIME duration;
    REFERENCE_TIME period;
    const struct WAVEFORMATEX_stub *fmt;
    HRESULT result;
    UINT32 *channel_count;
    stream_handle *stream;
};

struct stream_handle_params { stream_handle stream; HRESULT result; };
struct timer_loop_params { stream_handle stream; };
struct stream_handle_only { stream_handle stream; };

struct release_stream_params {
    stream_handle stream;
    HANDLE timer_thread;
    HRESULT result;
};

struct get_render_buffer_params {
    stream_handle stream;
    UINT32 frames;
    HRESULT result;
    BYTE **data;
};

struct release_render_buffer_params {
    stream_handle stream;
    UINT32 written_frames;
    UINT flags;
    HRESULT result;
};

struct get_capture_buffer_params {
    stream_handle stream;
    HRESULT result;
    BYTE **data;
    UINT32 *frames;
    UINT *flags;
    UINT64 *devpos;
    UINT64 *qpcpos;
};

struct release_capture_buffer_params {
    stream_handle stream;
    UINT32 done;
    HRESULT result;
};

struct is_format_supported_params {
    const char *device;
    EDataFlow flow;
    int share;
    const struct WAVEFORMATEX_stub *fmt_in;
    HRESULT result;
};

struct get_mix_format_params {
    const char *device;
    EDataFlow flow;
    void *fmt;          /* WAVEFORMATEXTENSIBLE */
    HRESULT result;
};

struct get_device_period_params {
    const char *device;
    EDataFlow flow;
    HRESULT result;
    REFERENCE_TIME *def_period;
    REFERENCE_TIME *min_period;
};

struct get_buffer_size_params {
    stream_handle stream;
    HRESULT result;
    UINT32 *frames;
};

struct get_latency_params {
    stream_handle stream;
    HRESULT result;
    REFERENCE_TIME *latency;
};

struct get_current_padding_params {
    stream_handle stream;
    HRESULT result;
    UINT32 *padding;
};

struct get_next_packet_size_params {
    stream_handle stream;
    HRESULT result;
    UINT32 *frames;
};

struct get_frequency_params {
    stream_handle stream;
    HRESULT result;
    UINT64 *freq;
};

struct get_position_params {
    stream_handle stream;
    BOOL device;
    HRESULT result;
    UINT64 *pos;
    UINT64 *qpctime;
};

struct set_volumes_params {
    stream_handle stream;
    float master_volume;
    const float *volumes;
    const float *session_volumes;
};

struct set_event_handle_params {
    stream_handle stream;
    HANDLE event;
    HRESULT result;
};

struct set_sample_rate_params {
    stream_handle stream;
    float rate;
    HRESULT result;
};

struct test_connect_params {
    const WCHAR *name;
    enum driver_priority priority;
};

struct is_started_params {
    stream_handle stream;
    HRESULT result;
};

struct get_prop_value_params {
    const char *device;
    EDataFlow flow;
    const void *guid;
    const void *prop;
    HRESULT result;
    void *value;
    void *buffer;
    unsigned int *buffer_size;
};

/* ------------------- WoW64 guest window ------------------- */

/* A 32-bit pseudo-process owns one
 * reserved host range [B, B+4G) and guest address `a` lives at host B + a.
 * The helpers below are the same ones build/ntdll-unix/ios_wow.h and
 * wine/include/wine/unixlib.h publish; they are respelled here (with matching
 * signatures) because this file deliberately carries no Wine headers -- see
 * the struct-mirror note above.  The guard is the one ios_wow.h uses, so if
 * this file ever does gain those includes the first definition wins. */
extern unsigned long ios_wow_base(void);          /* 0 when not a WoW process */
extern int ios_wow_in_window(const void *addr);

#ifndef __MADEIRA_IOS_WOW_HOST_PTR
#define __MADEIRA_IOS_WOW_HOST_PTR
static inline void *ios_wow_host_ptr(uint32_t addr)
{
    return addr ? (void *)(ios_wow_base() + (uintptr_t)addr) : NULL;
}
static inline uint32_t ios_wow_guest_ptr32(const void *host)
{
    return host ? (uint32_t)((uintptr_t)host - ios_wow_base()) : 0;
}
#endif

/* A 32-bit field holding a guest pointer. */
typedef uint32_t PTR32;

/* Handles are never offset: a 32-bit HANDLE
 * is zero-extended, exactly like upstream's ULongToHandle(). */
#define IOS_WOW_HANDLE(x)  ((HANDLE)(uintptr_t)(uint32_t)(x))

/* Enough of NtAllocateVirtualMemory to put the render scratch inside the
 * guest window.  Both live in the same statically-linked unix ntdll as
 * NtSetEvent above; the signatures match wine/include/winternl.h with
 * ULONG_PTR/SIZE_T spelled as the 64-bit unsigned types they are here. */
extern NTSTATUS NtAllocateVirtualMemory( HANDLE process, void **ret, UINT_PTR zero_bits,
                                         UINT_PTR *size_ptr, DWORD type, DWORD protect );
extern NTSTATUS NtFreeVirtualMemory( HANDLE process, void **addr_ptr,
                                     UINT_PTR *size_ptr, DWORD type );

#define IOS_CURRENT_PROCESS ((HANDLE)(intptr_t)-1)
#define IOS_MEM_COMMIT      0x00001000u
#define IOS_MEM_RESERVE     0x00002000u
#define IOS_MEM_RELEASE     0x00008000u
#define IOS_PAGE_READWRITE  0x00000004u

/* ---------------------------------------------------------------- */

#define IOS_AUDIO_SAMPLE_RATE 48000u
#define IOS_AUDIO_CHANNELS 2u
/* ml1068: the shared-mode MIX FORMAT is 32-bit float, as on every Windows since
 * Vista. We advertised 16-bit PCM. RDR2's own WASAPI client took GetMixFormat at
 * its word, Initialize()d with it, and then rendered what a Windows mix format
 * always is -- float32 -- into a buffer we sized and read as int16: a 4-byte
 * frame holding half a float pair. Interpreting quiet float audio as int16 is
 * full-scale uniform noise (measured mean|x| = 0.500, and the ml1067 dump of the
 * buffer decodes as float32 samples of ~1e-4). That was the white noise. */
#define IOS_AUDIO_BITS 32u
#define IOS_AUDIO_FRAME_BYTES ((IOS_AUDIO_CHANNELS * IOS_AUDIO_BITS) / 8u) /* 4 */
#define IOS_AUDIO_BUFFER_FRAMES 1024u  /* ~21 ms at 48 kHz */
#define IOS_AUDIO_BUFFER_BYTES (IOS_AUDIO_BUFFER_FRAMES * IOS_AUDIO_FRAME_BYTES)

/* The "device" Wine probes by name. mmdevapi stores it on the endpoint
 * struct and passes it back as `const char *device` in many calls. */
static const char IOS_DEVICE_NAME[] = "ios-null";

/* One global stream state — single render endpoint, single stream. FMOD
 * typically creates one shared-mode render stream; if a game opens a
 * second concurrent stream we'd need a table. Not worried about that
 * for the Tier-1 silent driver. */
struct ios_stream {
    int valid;
    int started;
    uint64_t start_mach;        /* mach_absolute_time() at start() (null-mode clock) */
    uint64_t accumulated_frames; /* null-mode: frames "played" before last stop */
    UINT32 sample_rate;
    UINT32 channels;
    UINT32 frame_bytes;          /* nBlockAlign of the stream format */
    UINT32 buffer_frames;        /* ring capacity in frames */
    BYTE *render_scratch;        /* contiguous area handed to GetBuffer */
    UINT32 scratch_frames;       /* scratch capacity */
    int scratch_guest;           /* render_scratch lives in a 32-bit guest window */
    UINT32 pending_frames;       /* frames handed out, awaiting release */
    HANDLE event;
    /* Tier-2 real output. ml1026: the AudioUnit is PROCESS-WIDE, not per
     * stream -- see struct ios_audio_device. A stream only describes how its
     * ring is to be interpreted by the mixer. */
    int is_float;                /* ring holds float32 (else signed integer) */
    int sample_bits;             /* bits per channel in the ring */
    int mixable;                 /* format understood by the mixer */
    UINT32 channel_mask;         /* dwChannelMask, 0 = "use the default layout" */
    /* Per-client-channel gain into the endpoint's stereo bus. Built once from
     * the channel mask at create_stream; this is the 5.1 (and 7.1, quad and
     * mono) downmix. Read-only once the stream is published to the mixer. */
    float mix_gain[12][2];   /* ml1227: up to 7.1.4 */
    BYTE *ring;
    _Atomic uint64_t write_pos;  /* frames produced by the game (monotonic) */
    _Atomic uint64_t play_pos;   /* frames consumed by the RT callback */
    /* ml1230: what the RT callback asked of this stream and could not get.
     * Written by the RT callback only (relaxed), read by the timer loop. */
    _Atomic uint64_t st_short;     /* stream frames the device asked for and the ring did not have */
    _Atomic uint32_t st_cbs;       /* render passes that mixed this stream */
    _Atomic uint32_t st_short_cbs; /* passes that ran short */
    _Atomic uint32_t st_cb_max;    /* largest render pass, device frames */
};

/* ml739: one stream object per client, mirroring Wine's CoreAudio driver.
 *
 * This was a documented singleton -- see the comment on struct ios_stream --
 * and ordinary WASAPI use breaks it: a title that plays a cutscene opens a
 * second concurrent render client (48k/2ch float32) while its main audio
 * client (48k/2ch PCM16) is still live. Both were handed the SAME handle, so
 * creating the second tore down the first's AudioUnit, set_event_handle
 * overwrote the first client's event -- after which it was never signalled
 * again -- and both shared one ring, one padding counter and one play
 * position, with two audio_client_timer threads driving them. The audible
 * result was a silent cutscene; the functional result was a source queue that
 * never drained, so the video never reported completion.
 *
 * The registry exists only for handle validation and process-detach cleanup.
 * It is never touched from the RemoteIO callback, which reaches its stream
 * through inputProcRefCon. */
#define IOS_MAX_STREAMS 16
static struct ios_stream *g_streams[IOS_MAX_STREAMS];
static pthread_mutex_t g_streams_lock;   /* ml739: init at process_attach */

/* ml1026: ONE RemoteIO endpoint per process, with every live client mixed
 * into it.
 *
 * ml739 gave each WASAPI client its own struct ios_stream, which was right,
 * but it also gave each one its own RemoteIO AudioUnit, which is not: on iOS
 * kAudioUnitSubType_RemoteIO IS the hardware I/O unit and a process gets one.
 * A title that opens a second concurrent render client (a cutscene at
 * 48k/2ch float32 over the main client at 48k/2ch PCM16) made us instantiate
 * a second one. The first such episode survived; the second -- after the
 * cutscene client was released and another opened -- trapped inside Apple's
 * own code:
 *
 *   [task-exc] BREAKPOINT pc=0x2b7f2d684 insn=0xd4200020 (brk #1)
 *   TRAP-SYM  caulk.framework`caulk::thread::start+0x1e0
 *
 * which our handler turned into a guest c000001d and the game, having no
 * handler for it, answered with NtTerminateProcess. Byte-identical in two
 * separate runs, and absent from every run that never reached a third
 * stream creation.
 *
 * Windows semantics are a mixer anyway: N shared-mode clients feed ONE
 * endpoint. So: one unit, created once and kept for the process lifetime
 * (which also removes the create/release/create churn that tripped caulk),
 * and a render callback that sums every live ring into it.
 *
 * The callback is real-time: it touches g_mix and the per-stream atomics
 * ONLY. g_streams_lock is never taken there. */
struct ios_audio_device {
    AudioUnit au;                 /* NULL = null-mode fallback for everyone */
    int running;                  /* AudioOutputUnitStart has been called */
    int failed;                   /* setup failed once; do not retry */
    UINT32 rate;                  /* canonical output rate */
    UINT32 channels;              /* canonical output channel count */
    _Atomic uint64_t cb_epoch;    /* ++ at the end of every render pass */
    _Atomic uint64_t clamped;     /* ml1230: output samples clamped to +-1 */
};
static struct ios_audio_device g_dev;
static pthread_mutex_t g_dev_lock = PTHREAD_MUTEX_INITIALIZER;
/* Published to the RT callback. Written with release, read with acquire. */
static _Atomic(struct ios_stream *) g_mix[IOS_MAX_STREAMS];

static struct ios_stream *stream_from_handle(stream_handle h)
{
    struct ios_stream *s = (struct ios_stream *)(uintptr_t)h;
    int i, ok = 0;
    if (!s) return NULL;
    pthread_mutex_lock(&g_streams_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i] == s) { ok = 1; break; }
    pthread_mutex_unlock(&g_streams_lock);
    if (!ok) {
        static int moaned;
        if (moaned++ < 8)
            fprintf(stderr, "[ios-astream] ml739 STALE handle %p -- ignoring\n", (void *)s);
        return NULL;
    }
    return s;
}

static int stream_register(struct ios_stream *s)
{
    int i, n = 0;
    pthread_mutex_lock(&g_streams_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i]) n++;
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (!g_streams[i]) { g_streams[i] = s; break; }
    pthread_mutex_unlock(&g_streams_lock);
    if (i == IOS_MAX_STREAMS) return -1;
    fprintf(stderr, "[ios-astream] ml739 CREATE stream=%p (%d now live)\n", (void *)s, n + 1);
    return 0;
}

static void stream_unregister(struct ios_stream *s)
{
    int i, n = 0;
    pthread_mutex_lock(&g_streams_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i] == s) g_streams[i] = NULL;
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i]) n++;
    pthread_mutex_unlock(&g_streams_lock);
    fprintf(stderr, "[ios-astream] ml739 RELEASE stream=%p (%d still live)\n", (void *)s, n);
}

/* ml738: this driver is a documented singleton -- see the comment on
 * struct ios_stream. One title opens TWO concurrent render streams with
 * different formats (48k/2ch PCM16, then 48k/2ch float32), which is exactly
 * the case the comment says needs a table. Every client is handed the SAME
 * handle (&g_stream), so the driver cannot tell them apart: creating the
 * second tears down the first's AudioUnit, set_event_handle overwrites the
 * first client's event, releasing either invalidates both, and they share one
 * ring, one padding counter and one playback position.
 *
 * Instrument before changing behaviour: generation, the handle handed out, the
 * event handle and the calling thread, so the interleaving is visible rather
 * than inferred. */
static unsigned long long ios_current_tid(void)
{
    uint64_t t = 0;
    pthread_threadid_np(NULL, &t);
    return (unsigned long long)t;
}

static unsigned int g_stream_gen;
static unsigned int g_live_streams;
static mach_timebase_info_data_t g_timebase;

/* NtSetEvent lives in the same statically-linked unix ntdll. timer_loop
 * runs on a real Wine thread (mmdevapi spawns it into this unix call),
 * so calling into ntdll here is legal — unlike from the RT callback. */
extern NTSTATUS NtSetEvent( HANDLE handle, void *prev_state );

/* Per-function call counters. Print every 1000 calls so we can confirm
 * FMOD is actually exercising the driver. Cheap atomic increments. */
#include <stdatomic.h>
#define NULL_AUDIO_FN_COUNT 37
static _Atomic uint32_t g_call_counter[NULL_AUDIO_FN_COUNT];
#define LOG_FN_CALL(idx, name) do { \
    uint32_t n = atomic_fetch_add_explicit(&g_call_counter[idx], 1, memory_order_relaxed) + 1; \
    if (n == 1 || (n % 1000) == 0) { \
        char buf[128]; \
        int len = snprintf(buf, sizeof(buf), "[ios_audio] " name " #%u\n", n); \
        if (len > 0) write(STDERR_FILENO, buf, len); \
    } \
} while (0)

static uint64_t mach_to_ns(uint64_t mach) {
    if (!g_timebase.denom) mach_timebase_info(&g_timebase);
    return mach * g_timebase.numer / g_timebase.denom;
}

static uint64_t elapsed_ns_since(uint64_t mach_start) {
    return mach_to_ns(mach_absolute_time() - mach_start);
}

static uint64_t elapsed_frames(const struct ios_stream *s) {
    if (!s->started) return s->accumulated_frames;
    uint64_t ns = elapsed_ns_since(s->start_mach);
    /* frames = ns * rate / 1e9 */
    return s->accumulated_frames + (ns * s->sample_rate / 1000000000ull);
}

/* ------------------- Channel downmix into the stereo bus ------------------- */

/* SPEAKER_* bits from ksmedia.h, in the order WAVEFORMATEXTENSIBLE requires
 * the channels to appear in the buffer (low bit first). */
#define IOS_SPK_FRONT_LEFT            0x00001
#define IOS_SPK_FRONT_RIGHT           0x00002
#define IOS_SPK_FRONT_CENTER          0x00004
#define IOS_SPK_LOW_FREQUENCY         0x00008
#define IOS_SPK_BACK_LEFT             0x00010
#define IOS_SPK_BACK_RIGHT            0x00020
#define IOS_SPK_FRONT_LEFT_OF_CENTER  0x00040
#define IOS_SPK_FRONT_RIGHT_OF_CENTER 0x00080
#define IOS_SPK_BACK_CENTER           0x00100
#define IOS_SPK_SIDE_LEFT             0x00200
#define IOS_SPK_SIDE_RIGHT            0x00400
#define IOS_SPK_TOP_CENTER            0x00800   /* ml1227: the height speakers of 7.1.4 */
#define IOS_SPK_TOP_FRONT_LEFT        0x01000
#define IOS_SPK_TOP_FRONT_CENTER      0x02000
#define IOS_SPK_TOP_FRONT_RIGHT       0x04000
#define IOS_SPK_TOP_BACK_LEFT         0x08000
#define IOS_SPK_TOP_BACK_CENTER       0x10000
#define IOS_SPK_TOP_BACK_RIGHT        0x20000

#define IOS_GAIN_M3DB  0.70710678f
#define IOS_GAIN_M10DB 0.316f

/* dwChannelMask of a WAVEFORMATEXTENSIBLE, 0 for a plain WAVEFORMATEX. */
static UINT32 ios_fmt_channel_mask(const struct WAVEFORMATEX_stub *fmt)
{
    uint32_t mask;
    if (!fmt || fmt->wFormatTag != 0xFFFE || fmt->cbSize < 22) return 0;
    memcpy(&mask, (const uint8_t *)fmt + 20, sizeof(mask));
    return mask;
}

/* MADEIRA_AUDIO_DOWNMIX=0 restores the old mapping (channel 0 to the left,
 * channel 1 to the right, everything else dropped). Read on the create_stream
 * thread, never from the render callback. */
static int ios_downmix_enabled(void)
{
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("MADEIRA_AUDIO_DOWNMIX");
        cached = !(e && e[0] == '0' && !e[1]);
    }
    return cached;
}

/* Build the per-channel downmix into the stereo bus.
 *
 * The mixer used to take channels 0 and 1 of every client frame and drop the
 * rest. For a 5.1 client that keeps front left/right and loses the centre,
 * LFE and surrounds -- and the centre is where a 5.1 mix puts dialogue, so a
 * 5.1 client played music and effects with its dialogue silent. This folds
 * every channel in with the standard ITU coefficients: centre and the
 * surrounds at -3 dB, LFE at -10 dB (dropping it entirely loses the bass a
 * title puts ONLY there); the render callback already clamps the sum.
 *
 * The layout comes from dwChannelMask when there is one. When there is not
 * -- a plain WAVEFORMATEX -- the channel count implies the standard layout,
 * which is what every other WASAPI implementation assumes too. */
static void ios_build_mix_gains(struct ios_stream *s, UINT32 mask)
{
    static const UINT32 default_mask[9] = {
        0,
        IOS_SPK_FRONT_CENTER,                                            /* 1: mono */
        IOS_SPK_FRONT_LEFT | IOS_SPK_FRONT_RIGHT,                        /* 2 */
        IOS_SPK_FRONT_LEFT | IOS_SPK_FRONT_RIGHT | IOS_SPK_FRONT_CENTER, /* 3 */
        IOS_SPK_FRONT_LEFT | IOS_SPK_FRONT_RIGHT | IOS_SPK_BACK_LEFT | IOS_SPK_BACK_RIGHT,
        IOS_SPK_FRONT_LEFT | IOS_SPK_FRONT_RIGHT | IOS_SPK_FRONT_CENTER |
            IOS_SPK_BACK_LEFT | IOS_SPK_BACK_RIGHT,                      /* 5 */
        IOS_SPK_FRONT_LEFT | IOS_SPK_FRONT_RIGHT | IOS_SPK_FRONT_CENTER |
            IOS_SPK_LOW_FREQUENCY | IOS_SPK_BACK_LEFT | IOS_SPK_BACK_RIGHT, /* 6: 5.1 */
        IOS_SPK_FRONT_LEFT | IOS_SPK_FRONT_RIGHT | IOS_SPK_FRONT_CENTER |
            IOS_SPK_LOW_FREQUENCY | IOS_SPK_BACK_CENTER |
            IOS_SPK_SIDE_LEFT | IOS_SPK_SIDE_RIGHT,                      /* 7: 6.1 */
        IOS_SPK_FRONT_LEFT | IOS_SPK_FRONT_RIGHT | IOS_SPK_FRONT_CENTER |
            IOS_SPK_LOW_FREQUENCY | IOS_SPK_BACK_LEFT | IOS_SPK_BACK_RIGHT |
            IOS_SPK_SIDE_LEFT | IOS_SPK_SIDE_RIGHT                       /* 8: 7.1 */
    };
    UINT32 ch = s->channels > 12 ? 12 : s->channels, c, bit, i;

    memset(s->mix_gain, 0, sizeof(s->mix_gain));
    if (!ch) return;

    /* One channel is mono however it is labelled: it goes to both sides at
     * unity, not at -3 dB, or a mono client is half as loud as a stereo one.
     * This is also what the mixer always did with a mono client. */
    if (ch == 1) {
        s->mix_gain[0][0] = s->mix_gain[0][1] = 1.0f;
        return;
    }

    if (!ios_downmix_enabled()) {
        s->mix_gain[0][0] = 1.0f;
        s->mix_gain[1][1] = 1.0f;
        return;
    }

    /* ml1227: a mask is honoured up to 12 channels (7.1.4: Wine's spatial
     * audio bed); without one, more than 8 channels only get the leftovers */
    if (!mask) mask = ch <= 8 ? default_mask[ch] : default_mask[8];

    /* Walk the mask low bit first; the Nth set bit is the Nth channel in the
     * interleaved frame. */
    c = 0;
    for (i = 0; i < 18 && c < ch; i++) {
        bit = 1u << i;
        if (!(mask & bit)) continue;
        switch (bit) {
        case IOS_SPK_FRONT_LEFT:            s->mix_gain[c][0] = 1.0f; break;
        case IOS_SPK_FRONT_RIGHT:           s->mix_gain[c][1] = 1.0f; break;
        case IOS_SPK_FRONT_CENTER:
        case IOS_SPK_BACK_CENTER:
            s->mix_gain[c][0] = s->mix_gain[c][1] = IOS_GAIN_M3DB; break;
        case IOS_SPK_LOW_FREQUENCY:
            s->mix_gain[c][0] = s->mix_gain[c][1] = IOS_GAIN_M10DB; break;
        case IOS_SPK_BACK_LEFT:
        case IOS_SPK_SIDE_LEFT:
        case IOS_SPK_FRONT_LEFT_OF_CENTER:  s->mix_gain[c][0] = IOS_GAIN_M3DB; break;
        case IOS_SPK_BACK_RIGHT:
        case IOS_SPK_SIDE_RIGHT:
        case IOS_SPK_FRONT_RIGHT_OF_CENTER: s->mix_gain[c][1] = IOS_GAIN_M3DB; break;
        case IOS_SPK_TOP_FRONT_LEFT:
        case IOS_SPK_TOP_BACK_LEFT:         s->mix_gain[c][0] = IOS_GAIN_M3DB; break;
        case IOS_SPK_TOP_FRONT_RIGHT:
        case IOS_SPK_TOP_BACK_RIGHT:        s->mix_gain[c][1] = IOS_GAIN_M3DB; break;
        case IOS_SPK_TOP_CENTER:
        case IOS_SPK_TOP_FRONT_CENTER:
        case IOS_SPK_TOP_BACK_CENTER:
            s->mix_gain[c][0] = s->mix_gain[c][1] = IOS_GAIN_M3DB; break;
        default: break;
        }
        c++;
    }
    /* A mask that names fewer speakers than the stream has channels would
     * silence the rest; fold anything left over into both sides quietly rather
     * than dropping it. */
    for (; c < ch; c++)
        s->mix_gain[c][0] = s->mix_gain[c][1] = 0.5f;
}

/* ------------------- Tier-2: RemoteIO real output ------------------- */

/* Core Audio real-time thread. Ring + atomics ONLY — no Wine calls, no
 * locks, no allocation, no logging. Underrun = silence (WASAPI-correct:
 * padding drains to 0 and the position clock pauses at write_pos). */
/* Mix ONE stream into the device buffer. Real-time context: ring reads and
 * atomics only -- no locks, no allocation, no logging, no Wine calls.
 * Underrun mixes what is there and leaves the rest alone, which is
 * WASAPI-correct: padding drains to 0 and the position clock pauses. */
static void ios_mix_stream(struct ios_stream *s, float *out, UInt32 nframes,
                           UINT32 dev_ch, UINT32 dev_rate)
{
    UINT32 cap = s->buffer_frames, sch = s->channels, fb = s->frame_bytes;
    UINT32 mch = sch > 12 ? 12 : sch;   /* channels with a gain; the rest are dropped (ml1227: 12) */
    uint64_t play, wr, avail, need, want;
    UInt32 f;

    if (!s->started || !s->mixable || !s->ring || !cap || !sch || !fb) return;

    play  = atomic_load_explicit(&s->play_pos, memory_order_relaxed);
    wr    = atomic_load_explicit(&s->write_pos, memory_order_acquire);
    avail = wr - play;

    /* frames of THIS stream that cover nframes of device time */
    if (s->sample_rate == dev_rate) need = nframes;
    else need = ((uint64_t)nframes * s->sample_rate + dev_rate - 1) / dev_rate;
    want = need;
    if (avail < need) need = avail;

    for (f = 0; f < nframes; f++)
    {
        uint64_t sidx = (s->sample_rate == dev_rate)
                        ? (uint64_t)f
                        : ((uint64_t)f * s->sample_rate) / dev_rate;
        const BYTE *fr;
        float l = 0.0f, r = 0.0f;
        UINT32 c;

        if (sidx >= need) break;
        fr = s->ring + (size_t)((play + sidx) % cap) * fb;

        /* Fold every client channel into the stereo bus with the gains
         * ios_build_mix_gains chose at create_stream. */
        for (c = 0; c < mch; c++) {
            float v;
            if (s->is_float) {
                memcpy(&v, fr + (size_t)c * 4, 4);
            } else if (s->sample_bits == 16) {
                int16_t i16;
                memcpy(&i16, fr + (size_t)c * 2, 2);
                v = (float)i16 * (1.0f / 32768.0f);
            } else {   /* 32-bit signed integer */
                int32_t i32;
                memcpy(&i32, fr + (size_t)c * 4, 4);
                v = (float)i32 * (1.0f / 2147483648.0f);
            }
            l += v * s->mix_gain[c][0];
            r += v * s->mix_gain[c][1];
        }

        out[(size_t)f * dev_ch + 0] += l;
        if (dev_ch > 1) out[(size_t)f * dev_ch + 1] += r;
    }

    atomic_store_explicit(&s->play_pos, play + need, memory_order_release);

    /* ml1230: an underrun is heard as a click; count them */
    atomic_fetch_add_explicit(&s->st_cbs, 1, memory_order_relaxed);
    if (need < want) {
        atomic_fetch_add_explicit(&s->st_short, want - need, memory_order_relaxed);
        atomic_fetch_add_explicit(&s->st_short_cbs, 1, memory_order_relaxed);
    }
    if (nframes > atomic_load_explicit(&s->st_cb_max, memory_order_relaxed))
        atomic_store_explicit(&s->st_cb_max, nframes, memory_order_relaxed);
}

/* Core Audio real-time thread. See ios_mix_stream for the constraints. */
static OSStatus ios_audio_render_cb(void *refcon, AudioUnitRenderActionFlags *flags,
                                    const AudioTimeStamp *ts, UInt32 bus,
                                    UInt32 nframes, AudioBufferList *iodata) {
    float *out;
    UINT32 dev_ch = g_dev.channels ? g_dev.channels : 2;
    UINT32 dev_rate = g_dev.rate ? g_dev.rate : 48000;
    size_t total = (size_t)nframes * dev_ch;
    size_t k, cap_floats, clamped = 0;
    int i;
    (void)refcon; (void)flags; (void)ts; (void)bus;

    /* Never write past what Core Audio handed us: the format is packed
     * interleaved, so there is exactly one buffer, but trust its size rather
     * than our own frame arithmetic. */
    if (!iodata || iodata->mNumberBuffers < 1) return noErr;
    out = (float *)iodata->mBuffers[0].mData;
    if (!out) return noErr;
    cap_floats = iodata->mBuffers[0].mDataByteSize / sizeof(float);
    if (total > cap_floats) {
        total = cap_floats;
        nframes = (UInt32)(total / dev_ch);
    }

    memset(out, 0, total * sizeof(float));
    for (i = 0; i < IOS_MAX_STREAMS; i++) {
        struct ios_stream *s = atomic_load_explicit(&g_mix[i], memory_order_acquire);
        if (s) ios_mix_stream(s, out, nframes, dev_ch, dev_rate);
    }
    /* Summing independent clients can exceed full scale; clamp rather than
     * letting it wrap into noise. */
    for (k = 0; k < total; k++) {
        if (out[k] > 1.0f) { out[k] = 1.0f; clamped++; }
        else if (out[k] < -1.0f) { out[k] = -1.0f; clamped++; }
    }
    if (clamped) atomic_fetch_add_explicit(&g_dev.clamped, clamped, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_dev.cb_epoch, 1, memory_order_release);
    return noErr;
}

/* Parse the WASAPI format into "is float?" — tag 3 = IEEE float, tag
 * 0xFFFE = extensible (SubFormat GUID first byte: 1 PCM, 3 float). */
static int ios_fmt_is_float(const struct WAVEFORMATEX_stub *fmt) {
    if (!fmt) return 0;
    if (fmt->wFormatTag == 3) return 1;
    if (fmt->wFormatTag == 0xFFFE && fmt->cbSize >= 22) {
        const uint8_t *sub = (const uint8_t *)fmt + 24;
        return sub[0] == 3;
    }
    return 0;
}

/* Create the ONE process-wide RemoteIO endpoint, at float32 stereo and the
 * rate of whichever client opened it first. Returns 0 if the endpoint exists.
 * Caller holds g_dev_lock. */
static int ios_dev_create_locked(const struct ios_stream *s)
{
    AudioComponentDescription desc = {0};
    AudioComponent comp;
    AudioStreamBasicDescription asbd = {0};
    AURenderCallbackStruct cb;
    OSStatus err;

    if (g_dev.au) return 0;
    if (g_dev.failed) return -1;

    g_dev.rate = s->sample_rate ? s->sample_rate : 48000;
    g_dev.channels = s->channels >= 2 ? 2 : 1;

    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) {
        fprintf(stderr, "[ios_audio] ml1026 RemoteIO component not found\n");
        g_dev.failed = 1; return -1;
    }
    if ((err = AudioComponentInstanceNew(comp, &g_dev.au))) {
        fprintf(stderr, "[ios_audio] ml1026 AudioComponentInstanceNew: %d\n", (int)err);
        g_dev.au = NULL; g_dev.failed = 1; return -1;
    }

    /* The endpoint always runs float32 packed interleaved; per-client formats
     * are converted by the mixer. */
    asbd.mSampleRate = g_dev.rate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mFramesPerPacket = 1;
    asbd.mChannelsPerFrame = g_dev.channels;
    asbd.mBitsPerChannel = 32;
    asbd.mBytesPerFrame = 4 * g_dev.channels;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;

    err = AudioUnitSetProperty(g_dev.au, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
    if (err) {
        fprintf(stderr, "[ios_audio] ml1026 SetProperty(StreamFormat rate=%u ch=%u float32): %d\n",
                g_dev.rate, g_dev.channels, (int)err);
        goto fail;
    }

    cb.inputProc = ios_audio_render_cb;
    cb.inputProcRefCon = NULL;     /* the callback walks g_mix, not one stream */
    err = AudioUnitSetProperty(g_dev.au, kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (err) { fprintf(stderr, "[ios_audio] ml1026 SetRenderCallback: %d\n", (int)err); goto fail; }

    if ((err = AudioUnitInitialize(g_dev.au))) {
        fprintf(stderr, "[ios_audio] ml1026 AudioUnitInitialize: %d\n", (int)err);
        goto fail;
    }
    fprintf(stderr, "[ios_audio] ml1026 RemoteIO ENDPOINT ready: %u Hz, %u ch, float32 "
                    "-- shared by every client\n", g_dev.rate, g_dev.channels);
    return 0;
fail:
    AudioComponentInstanceDispose(g_dev.au);
    g_dev.au = NULL;
    g_dev.failed = 1;
    return -1;
}

/* Describe this stream's ring for the mixer and publish it. Failure leaves the
 * stream unmixed, which is the pre-existing null-mode behaviour: the position
 * clock still runs off the wall clock, so the game keeps making progress. */
static int ios_dev_attach(struct ios_stream *s, const struct WAVEFORMATEX_stub *fmt)
{
    int i, slot = -1, bits;

    s->is_float = ios_fmt_is_float(fmt);
    bits = (s->channels && s->frame_bytes)
           ? (int)(s->frame_bytes / s->channels) * 8 : 0;
    s->sample_bits = bits;
    s->mixable = (s->is_float && bits == 32) || (!s->is_float && (bits == 16 || bits == 32));
    if (!s->mixable) {
        fprintf(stderr, "[ios_audio] ml1026 UNMIXABLE format rate=%u ch=%u fb=%u float=%d "
                        "bits=%d -- this client stays silent (add a converter)\n",
                s->sample_rate, s->channels, s->frame_bytes, s->is_float, bits);
        return -1;
    }

    pthread_mutex_lock(&g_dev_lock);
    if (ios_dev_create_locked(s)) { pthread_mutex_unlock(&g_dev_lock); return -1; }
    for (i = 0; i < IOS_MAX_STREAMS; i++)
        if (!atomic_load_explicit(&g_mix[i], memory_order_relaxed)) { slot = i; break; }
    if (slot >= 0) atomic_store_explicit(&g_mix[slot], s, memory_order_release);
    pthread_mutex_unlock(&g_dev_lock);

    if (slot < 0) {
        fprintf(stderr, "[ios_audio] ml1026 mixer full -- client stays silent\n");
        return -1;
    }
    {   /* the downmix this client gets, one L/R gain pair per channel */
        char gains[160];
        size_t n = 0;
        UINT32 c, mch = s->channels > 12 ? 12 : s->channels;
        gains[0] = 0;
        for (c = 0; c < mch && n < sizeof(gains); c++) {
            int w = snprintf(gains + n, sizeof(gains) - n, "%s%.2f/%.2f", c ? " " : "",
                             s->mix_gain[c][0], s->mix_gain[c][1]);
            if (w < 0) break;
            n += (size_t)w;
        }
        fprintf(stderr, "[ios_audio] ml1026 MIX slot=%d rate=%u ch=%u fb=%u float=%d "
                        "(endpoint %u Hz %u ch) mask=0x%x downmix%s L/R=[%s]\n",
                slot, s->sample_rate, s->channels, s->frame_bytes, s->is_float,
                g_dev.rate, g_dev.channels, s->channel_mask,
                ios_downmix_enabled() ? "" : "(off)", gains);
    }
    return 0;
}

/* Unpublish a stream and wait until the RT callback cannot be inside it.
 *
 * The callback holds no reference across passes, so two completed passes since
 * the slot was cleared is enough. Bounded, because a stopped or never-started
 * endpoint never advances the epoch. The endpoint itself is deliberately NOT
 * disposed: keeping it for the process lifetime is what removes the
 * create/release/create churn that trapped caulk. */
static void ios_dev_detach(struct ios_stream *s)
{
    int i, spins = 0;
    int cleared = 0;
    uint64_t e0;

    for (i = 0; i < IOS_MAX_STREAMS; i++)
        if (atomic_load_explicit(&g_mix[i], memory_order_relaxed) == s) {
            atomic_store_explicit(&g_mix[i], NULL, memory_order_release);
            cleared = 1;
        }
    if (!cleared || !g_dev.running) return;

    e0 = atomic_load_explicit(&g_dev.cb_epoch, memory_order_acquire);
    while (atomic_load_explicit(&g_dev.cb_epoch, memory_order_acquire) - e0 < 2) {
        if (++spins > 500) {
            fprintf(stderr, "[ios_audio] ml1026 detach quiesce TIMED OUT after %d ms "
                            "(endpoint running=%d) -- proceeding\n", spins, g_dev.running);
            break;
        }
        usleep(1000);
    }
}

/* Start/stop the shared endpoint. It runs while at least one client is
 * started; with none it is stopped rather than rendering silence. */
static void ios_dev_start(void)
{
    pthread_mutex_lock(&g_dev_lock);
    if (g_dev.au && !g_dev.running) {
        OSStatus err = AudioOutputUnitStart(g_dev.au);
        if (err) fprintf(stderr, "[ios_audio] ml1026 AudioOutputUnitStart: %d -- null-mode\n", (int)err);
        else g_dev.running = 1;
    }
    pthread_mutex_unlock(&g_dev_lock);
}

static void ios_dev_stop_if_idle(void)
{
    int i, any = 0;

    pthread_mutex_lock(&g_dev_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) {
        struct ios_stream *m = atomic_load_explicit(&g_mix[i], memory_order_relaxed);
        if (m && m->started) { any = 1; break; }
    }
    if (!any && g_dev.au && g_dev.running) {
        AudioOutputUnitStop(g_dev.au);
        g_dev.running = 0;
    }
    pthread_mutex_unlock(&g_dev_lock);
}

/* ml1026: "this client feeds the real endpoint", replacing the old per-stream
 * s->au test. When false the caller falls back to null-mode wall-clock
 * synthesis exactly as before. */
static int ios_stream_is_live(const struct ios_stream *s)
{
    return s->mixable && g_dev.au != NULL;
}

/* ---------------------------------------------------------------- */

/* Render-buffer ownership for 32-bit clients.
 *
 * render_scratch is the one buffer this driver hands to its client:
 * get_render_buffer returns it and the application writes its samples
 * straight into it.  For a 32-bit client that pointer must be a guest address,
 * i.e. inside the calling process's [B, B+4G) window: a calloc() pointer is
 * host memory above 4 GB and would be truncated.  So when the calling process
 * has a window the scratch is allocated with a guest ceiling (zero_bits 1 =
 * limit 0x7fffffff, which the ntdll unix side translates into the window).
 * With no window (every 64-bit caller) this is exactly the calloc() and free()
 * this driver has always used. */
static BYTE *ios_audio_alloc_scratch(UINT32 frames, UINT32 frame_bytes, int *is_guest)
{
    void *addr = NULL;
    UINT_PTR size;
    NTSTATUS st;

    *is_guest = 0;
    if (!ios_wow_base()) return (BYTE *)calloc(frames, frame_bytes);
    if (!frames || !frame_bytes) return NULL;

    size = (UINT_PTR)frames * frame_bytes;
    st = NtAllocateVirtualMemory(IOS_CURRENT_PROCESS, &addr, 1 /* zero_bits */, &size,
                                 IOS_MEM_COMMIT | IOS_MEM_RESERVE, IOS_PAGE_READWRITE);
    if (st || !addr || !ios_wow_in_window(addr)) {
        fprintf(stderr, "[ios_audio] WOW64 render scratch (%u frames x %u B) could not be "
                        "placed in the guest window (status 0x%x, addr %p)\n",
                frames, frame_bytes, (unsigned)st, addr);
        if (!st && addr) {
            UINT_PTR z = 0;
            NtFreeVirtualMemory(IOS_CURRENT_PROCESS, &addr, &z, IOS_MEM_RELEASE);
        }
        return NULL;
    }
    *is_guest = 1;
    return (BYTE *)addr;
}

static void ios_audio_free_scratch(BYTE *scratch, int is_guest)
{
    if (!is_guest) { free(scratch); return; }
    if (scratch) {
        void *addr = scratch;
        UINT_PTR z = 0;
        NtFreeVirtualMemory(IOS_CURRENT_PROCESS, &addr, &z, IOS_MEM_RELEASE);
    }
}

static NTSTATUS ios_process_attach(void *args) {
    LOG_FN_CALL(0, "process_attach");
    (void)args;
    pthread_mutex_init(&g_streams_lock, NULL);
    if (!g_timebase.denom) mach_timebase_info(&g_timebase);
    return STATUS_SUCCESS;
}

static NTSTATUS ios_process_detach(void *args) {
    (void)args;
    /* ml739: tear down whatever is still registered. Previously this freed the
     * singleton's scratch buffer only; with a stream per client anything still
     * live at process detach has to be disposed individually. */
    {
        int i;
        for (i = 0; i < IOS_MAX_STREAMS; i++) {
            struct ios_stream *s;
            pthread_mutex_lock(&g_streams_lock);
            s = g_streams[i];
            g_streams[i] = NULL;
            pthread_mutex_unlock(&g_streams_lock);
            if (!s) continue;
            /* Stop the hardware, but do NOT free. release_stream joins a
             * stream's own timer thread before freeing it; here we have no
             * handle to join, and freeing while that thread may still be
             * looping is a use-after-free. The process is going away, so
             * leaving the memory is the safe trade. */
            s->valid = 0;
            s->started = 0;
            ios_dev_detach(s);
        }
    }
    return STATUS_SUCCESS;
}

static NTSTATUS ios_main_loop(void *args) {
    /* CONTRACT (mmdevapi client.c main_loop_start): the PE side blocks
     * WaitForSingleObject(event, INFINITE) until the driver signals this
     * event. Returning WITHOUT signaling deadlocks whoever triggered
     * driver init — FMOD's IAudioClient path — which held Thumper on the
     * splash screen (2026-07-05; and likely the misread May "FMOD probes
     * then stops" observation). winecoreaudio does exactly this. */
    struct main_loop_params { HANDLE event; } *p = args;
    LOG_FN_CALL(2, "main_loop");
    NtSetEvent(p->event, NULL);
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_endpoint_ids(void *args) {
    LOG_FN_CALL(3, "get_endpoint_ids");
    struct get_endpoint_ids_params *p = args;
    /* Only render endpoints; refuse capture entirely. */
    if (p->flow != eRender) {
        p->num = 0;
        p->default_idx = 0;
        p->result = S_OK;
        return STATUS_SUCCESS;
    }
    /* mmdevapi treats endpoint.name as WCHAR* (wide string, 2 bytes/char)
     * and endpoint.device as char* (single-byte). Both stored as byte
     * offsets from the endpoints buffer base. */
    static const WCHAR dev_name_w[] = { 'i','O','S',' ','N','u','l','l', 0 };
    unsigned int name_bytes = sizeof(dev_name_w);
    unsigned int device_bytes = sizeof(IOS_DEVICE_NAME);
    unsigned int needed = sizeof(struct endpoint) + name_bytes + device_bytes;
    if (p->size < needed) {
        p->num = 1;
        p->default_idx = 0;
        p->result = 0x80070057L; /* E_INVALIDARG style — signal "need more space" */
        return STATUS_SUCCESS;
    }
    /* Layout: [endpoint][wide_name\0\0][device_str\0] */
    unsigned int name_off = sizeof(struct endpoint);
    unsigned int device_off = name_off + name_bytes;
    char *buf = (char *)p->endpoints;
    memcpy(buf + name_off, dev_name_w, name_bytes);
    memcpy(buf + device_off, IOS_DEVICE_NAME, device_bytes);
    p->endpoints[0].name = name_off;
    p->endpoints[0].device = device_off;
    p->num = 1;
    p->default_idx = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_create_stream(void *args) {
    LOG_FN_CALL(4, "create_stream");
    struct create_stream_params *p = args;
    uint64_t dur_frames;
    /* ml739: a stream per client. */
    struct ios_stream *s = calloc(1, sizeof(*s));
    if (!s) { p->result = E_OUTOFMEMORY; return STATUS_SUCCESS; }
    {   /* ml1066: WHO opens each stream. Slot 0 (16-bit stereo) carries full-scale
         * uniform noise (mean|x| 0.50, peak 1.0) from its very first buffer, while
         * the float client carries real, quiet audio. The name mmdevapi passes is
         * the client's executable; the flags/duration/period say which API. */
        char nm[64]; int k = 0;
        if (p->name) while (p->name[k] && k < 63) { nm[k] = (char)(p->name[k] < 127 ? p->name[k] : '?'); k++; }
        nm[k] = 0;
        fprintf(stderr, "[ios_audio] ml1066 create_stream by '%s' flow=%d share=%d flags=%#x duration=%lld period=%lld fmt tag=%#x ch=%u rate=%u bits=%u align=%u\n",
                nm, (int)p->flow, p->share, (unsigned)p->flags, (long long)p->duration, (long long)p->period,
                p->fmt ? (unsigned)p->fmt->wFormatTag : 0u, p->fmt ? (unsigned)p->fmt->nChannels : 0u,
                p->fmt ? (unsigned)p->fmt->nSamplesPerSec : 0u, p->fmt ? (unsigned)p->fmt->wBitsPerSample : 0u,
                p->fmt ? (unsigned)p->fmt->nBlockAlign : 0u);
    }
    s->valid = 1;
    s->started = 0;
    s->start_mach = 0;
    s->accumulated_frames = 0;
    s->sample_rate = p->fmt && p->fmt->nSamplesPerSec ? p->fmt->nSamplesPerSec : IOS_AUDIO_SAMPLE_RATE;
    s->channels = p->fmt && p->fmt->nChannels ? p->fmt->nChannels : IOS_AUDIO_CHANNELS;
    s->frame_bytes = p->fmt && p->fmt->nBlockAlign ? p->fmt->nBlockAlign
                          : (s->channels * IOS_AUDIO_BITS) / 8;
    s->channel_mask = ios_fmt_channel_mask(p->fmt);
    ios_build_mix_gains(s, s->channel_mask);
    /* Ring capacity: the requested buffer duration (100ns units), floor
     * 100ms so a slow FEX-translated mixer has slack. */
    dur_frames = (uint64_t)(p->duration > 0 ? p->duration : 0) * s->sample_rate / 10000000ull;
    if (dur_frames < s->sample_rate / 10) dur_frames = s->sample_rate / 10;
    if (dur_frames > s->sample_rate * 4) dur_frames = s->sample_rate * 4;
    s->buffer_frames = (UINT32)dur_frames;
    free(s->ring);
    s->ring = (BYTE *)calloc(s->buffer_frames, s->frame_bytes);
    ios_audio_free_scratch(s->render_scratch, s->scratch_guest);
    s->scratch_frames = s->buffer_frames;
    s->render_scratch = ios_audio_alloc_scratch(s->scratch_frames, s->frame_bytes, &s->scratch_guest);
    s->pending_frames = 0;
    atomic_store(&s->write_pos, 0);
    atomic_store(&s->play_pos, 0);

    if (p->flow == eRender && s->ring)
        ios_dev_attach(s, p->fmt);   /* failure -> null-mode */

    if (p->channel_count) *p->channel_count = s->channels;
    if (p->stream) *p->stream = (stream_handle)(uintptr_t)s;
    fprintf(stderr, "[ios-astream] ml738 CREATED gen=%u handle=%p rate=%u ch=%u fb=%u\n",
            g_stream_gen, (void *)s, s->sample_rate, s->channels,
            s->frame_bytes);
    if (stream_register(s)) {
        fprintf(stderr, "[ios-astream] ml739 too many streams -- refusing\n");
        ios_dev_detach(s);
        ios_audio_free_scratch(s->render_scratch, s->scratch_guest); free(s->ring); free(s);
        /* the handle was published above; it now points at freed memory */
        if (p->stream) *p->stream = 0;
        p->result = E_OUTOFMEMORY;
        return STATUS_SUCCESS;
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_release_stream(void *args) {
    struct release_stream_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);

    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }

    /* Order matters. Mark this stream dead first so its own timer thread
     * leaves its loop, join that thread, and only then dispose the AudioUnit
     * so the render callback cannot still be running against memory we are
     * about to free. Nothing here touches another client's stream. */
    s->valid = 0;
    s->started = 0;
    if (p->timer_thread) {
        NtWaitForSingleObject(p->timer_thread, FALSE, NULL);
        NtClose(p->timer_thread);
    }
    ios_dev_detach(s);
    ios_dev_stop_if_idle();
    stream_unregister(s);
    ios_audio_free_scratch(s->render_scratch, s->scratch_guest);
    free(s->ring);
    free(s);
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_start(void *args) {
    LOG_FN_CALL(6, "start");
    struct stream_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (!s->started) {
        /* ml1026: started BEFORE the endpoint runs, so the first render pass
         * already sees this client. */
        s->start_mach = mach_absolute_time();
        s->started = 1;
        ios_dev_start();
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_stop(void *args) {
    struct stream_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (s->started) {
        s->accumulated_frames = elapsed_frames(s);
        s->started = 0;
        ios_dev_stop_if_idle();
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_reset(void *args) {
    struct stream_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    s->started = 0;
    s->accumulated_frames = 0;
    s->start_mach = 0;
    /* Drop queued-but-unplayed audio (only legal while stopped). */
    atomic_store(&s->write_pos, 0);
    atomic_store(&s->play_pos, 0);
    s->pending_frames = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

/* ml1230: event pacing by ring fill, not by the clock.
 *
 * The timer loop used to signal the client every usleep(10000). A client that
 * renders exactly one period per wake-up then delivers exactly as much audio as
 * the loop managed wake-ups, and every late wake-up is audio lost for good: the
 * ring underruns and the device plays a gap. Wine's ISpatialAudioObjectRender-
 * Stream is such a client (BeginUpdatingAudioObjects always asks for one
 * period), and so is anything that writes a fixed period per event. Ori and the Will of the Wisps' Wwise
 * renders through it: in gameplay it delivered 212 s of audio in ~230 s, a
 * 10 ms hole every ~120 ms, heard as crackle.
 *
 * Now the loop keeps a lead of audio in the ring (60 ms, env
 * MADEIRA_AUDIO_LEAD_MS = 10..500): while the ring holds less, it wakes the
 * client again as soon as the client has answered the previous wake-up (wrote
 * something), or a period later if it has not. Once the lead is there it sleeps
 * until the lead is used up. A late wake-up now eats into the lead instead of
 * the sound, and the client catches up on the next ones.
 *
 * The thread also runs under the time-constraint policy, as Core Audio's own
 * I/O thread does; it only sleeps and sets an event. */
#define IOS_AUDIO_LEAD_MS_DEFAULT 60
static UINT32 ios_audio_lead_ms(void)
{
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("MADEIRA_AUDIO_LEAD_MS");
        int v = e ? atoi(e) : 0;
        cached = (v >= 10 && v <= 500) ? v : IOS_AUDIO_LEAD_MS_DEFAULT;
    }
    return (UINT32)cached;
}

static uint64_t ns_to_mach(uint64_t ns) {
    if (!g_timebase.denom) mach_timebase_info(&g_timebase);
    return ns * g_timebase.denom / g_timebase.numer;
}

static void ios_audio_timer_thread_rt(void)
{
    thread_time_constraint_policy_data_t pol;
    mach_port_t th = mach_thread_self();
    kern_return_t kr;

    pol.period      = (uint32_t)ns_to_mach(10000000);   /* 10 ms */
    pol.computation = (uint32_t)ns_to_mach(500000);     /* 0.5 ms */
    pol.constraint  = (uint32_t)ns_to_mach(5000000);    /* 5 ms */
    pol.preemptible = 1;
    kr = thread_policy_set(th, THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&pol,
                           THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    mach_port_deallocate(mach_task_self(), th);
    fprintf(stderr, "[ios_audio] ml1230 timer thread: time-constraint policy kr=%d, lead %u ms\n",
            (int)kr, ios_audio_lead_ms());
}

static NTSTATUS ios_timer_loop(void *args) {
    /* Runs on a dedicated Wine thread mmdevapi spawns for event-driven
     * clients. Wake the client whenever the ring needs more (ml1230); exit
     * when the stream dies. */
    struct timer_loop_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    uint64_t sig_wr = 0, sig_ns = 0;
    /* ml1230 report, one line per ~10 s per live stream */
    uint64_t rep_ns = 0, rep_wr = 0, rep_short = 0, rep_clamped = 0;
    uint32_t rep_cbs = 0, rep_short_cbs = 0, wakes = 0;
    uint64_t pad_min = UINT64_MAX, pad_max = 0, late_max_ns = 0;

    if (!s) return STATUS_SUCCESS;
    LOG_FN_CALL(9, "timer_loop");
    ios_audio_timer_thread_rt();
    while (s->valid) {
        UINT32 rate = s->sample_rate ? s->sample_rate : IOS_AUDIO_SAMPLE_RATE;
        uint64_t period = rate / 100, lead, play, wr, pad, now, sleep_ns, deadline, t;

        if (!s->event || !s->started || !ios_stream_is_live(s)) {
            /* null-mode, or nothing to drive yet: the plain 10 ms beat */
            usleep(10000); /* device period, 10 ms */
            if (s->event && s->started)
                NtSetEvent(s->event, NULL);
            continue;
        }

        lead = (uint64_t)rate * ios_audio_lead_ms() / 1000;
        if (lead + period > s->buffer_frames)   /* leave room for one more period */
            lead = s->buffer_frames > 2 * period ? s->buffer_frames - period : period;
        if (lead < period) lead = period;

        now = mach_to_ns(mach_absolute_time());
        /* play_pos first: the RT callback only consumes what it saw written, so
         * a write_pos loaded after it is never behind it. Loaded the other way
         * round, a pass that ran in between made wr - play wrap to ~2^64 and the
         * loop slept 10 ms with the ring nearly empty. A reset can still store
         * the two out of order, hence the clamp. */
        play = atomic_load_explicit(&s->play_pos, memory_order_acquire);
        wr   = atomic_load_explicit(&s->write_pos, memory_order_acquire);
        pad  = wr > play ? wr - play : 0;
        if (pad < pad_min) pad_min = pad;
        if (pad > pad_max) pad_max = pad;

        if (pad < lead) {
            if (wr != sig_wr || now - sig_ns >= 10000000) {
                NtSetEvent(s->event, NULL);
                sig_wr = wr;
                sig_ns = now;
                wakes++;
            }
            sleep_ns = 1000000;   /* look again for the client's answer */
        } else {
            sleep_ns = (pad - lead) * 1000000000ull / rate;   /* until the lead is used up */
            if (sleep_ns < 1000000) sleep_ns = 1000000;
            if (sleep_ns > 10000000) sleep_ns = 10000000;
        }

        if (!rep_ns) {
            rep_ns = now; rep_wr = wr;
            rep_short = atomic_load_explicit(&s->st_short, memory_order_relaxed);
            rep_cbs = atomic_load_explicit(&s->st_cbs, memory_order_relaxed);
            rep_short_cbs = atomic_load_explicit(&s->st_short_cbs, memory_order_relaxed);
            rep_clamped = atomic_load_explicit(&g_dev.clamped, memory_order_relaxed);
        } else if (now - rep_ns >= 10000000000ull) {
            uint64_t shrt = atomic_load_explicit(&s->st_short, memory_order_relaxed);
            uint32_t cbs = atomic_load_explicit(&s->st_cbs, memory_order_relaxed);
            uint32_t scbs = atomic_load_explicit(&s->st_short_cbs, memory_order_relaxed);
            uint64_t clamped = atomic_load_explicit(&g_dev.clamped, memory_order_relaxed);
            double secs = (double)(now - rep_ns) / 1e9;
            double wrote = (double)(wr - rep_wr) / rate;
            fprintf(stderr, "[ios_audio] ml1230 pacing stream=%p lead %u ms: client wrote %.2f s of audio in %.2f s "
                    "(%.1f%%) over %u wakes; device short %.1f ms in %u of %u passes (largest pass %u frames); "
                    "ring %llu..%llu frames; worst late wake %.1f ms; clamped %llu samples\n",
                    (void *)s, ios_audio_lead_ms(), wrote, secs, secs > 0 ? 100.0 * wrote / secs : 0.0, wakes,
                    (double)(shrt - rep_short) * 1000.0 / rate, scbs - rep_short_cbs, cbs - rep_cbs,
                    atomic_load_explicit(&s->st_cb_max, memory_order_relaxed),
                    (unsigned long long)pad_min, (unsigned long long)pad_max, late_max_ns / 1e6,
                    (unsigned long long)(clamped - rep_clamped));
            rep_ns = now; rep_wr = wr; rep_short = shrt; rep_cbs = cbs; rep_short_cbs = scbs;
            rep_clamped = clamped; wakes = 0; pad_min = UINT64_MAX; pad_max = 0; late_max_ns = 0;
        }

        deadline = mach_absolute_time() + ns_to_mach(sleep_ns);
        mach_wait_until(deadline);
        t = mach_absolute_time();
        if (t > deadline && mach_to_ns(t - deadline) > late_max_ns) late_max_ns = mach_to_ns(t - deadline);
    }
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_render_buffer(void *args) {
    LOG_FN_CALL(10, "get_render_buffer");
    struct get_render_buffer_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->data) *p->data = NULL; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (ios_stream_is_live(s)) {
        uint64_t padding = atomic_load(&s->write_pos) - atomic_load(&s->play_pos);
        if (p->frames + padding > s->buffer_frames) {
            p->result = (HRESULT)0x88890006L; /* AUDCLNT_E_BUFFER_TOO_LARGE */
            if (p->data) *p->data = NULL;
            return STATUS_SUCCESS;
        }
    }
    if (p->frames > s->scratch_frames) {
        /* Client asked for more than the ring — grow scratch; the copy in
         * release clamps to ring capacity anyway. */
        BYTE *ns;
        if (s->scratch_guest) {
            /* nothing is pending (GetBuffer hands out a fresh area), so a new
             * guest allocation replaces the old one */
            int guest;
            if (!(ns = ios_audio_alloc_scratch(p->frames, s->frame_bytes, &guest))) {
                p->result = E_FAIL; return STATUS_SUCCESS;
            }
            ios_audio_free_scratch(s->render_scratch, s->scratch_guest);
            s->scratch_guest = guest;
        }
        else {
            ns = (BYTE *)realloc(s->render_scratch, (size_t)p->frames * s->frame_bytes);
            if (!ns) { p->result = E_FAIL; return STATUS_SUCCESS; }
        }
        s->render_scratch = ns;
        s->scratch_frames = p->frames;
    }
    s->pending_frames = p->frames;
    /* ml1227: hand out SILENCE, not the previous period. WASAPI leaves the
     * contents undefined, but Wine's ISpatialAudioObjectRenderStream
     * (mmdevapi/spatialaudio.c) mixes its static objects into this buffer with
     * `*out += *in` and never clears it. Ori and the Will of the Wisps' Wwise renders through that
     * path (a 7.1.4 bed, 12 ch), so every period was added onto the last one:
     * the source level climbed from mean|x| 0.01 to 5 (peaks 36) and the game
     * played only crackle. */
    if (p->frames && s->render_scratch)
        memset(s->render_scratch, 0, (size_t)p->frames * s->frame_bytes);
    if (p->data) *p->data = s->render_scratch;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_release_render_buffer(void *args) {
    struct release_render_buffer_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (ios_stream_is_live(s) && p->written_frames > 0) {
        UINT32 fb = s->frame_bytes;
        UINT32 cap = s->buffer_frames;
        UINT32 n = p->written_frames;
        uint64_t wr = atomic_load_explicit(&s->write_pos, memory_order_relaxed);
        UINT32 i = 0;
        if (n > s->pending_frames) n = s->pending_frames;
        if (p->flags & 0x2 /* AUDCLNT_BUFFERFLAGS_SILENT */)
            memset(s->render_scratch, 0, (size_t)n * fb);
        while (i < n) {
            UINT32 idx = (UINT32)((wr + i) % cap);
            UINT32 chunk = cap - idx;
            if (chunk > n - i) chunk = n - i;
            memcpy(s->ring + (size_t)idx * fb,
                   s->render_scratch + (size_t)i * fb, (size_t)chunk * fb);
            i += chunk;
        }
        /* ml1065: what is the game actually handing us? A run has had constant
         * white noise since audio first worked; this says whether the noise is in
         * the source data (mean level high and flat, peaks saturating) or made
         * later (clean source, noisy output). One line per stream per ~10 s. */
        {
            static struct { uint64_t frames, clip; double sum_abs; float peak; time_t last; } st[IOS_MAX_STREAMS];
            int slot = -1, si;
            for (si = 0; si < IOS_MAX_STREAMS; si++) if (atomic_load_explicit(&g_mix[si], memory_order_relaxed) == s) { slot = si; break; }
            if (slot >= 0 && slot < IOS_MAX_STREAMS && s->channels) {
                UINT32 f2, c2, step = n > 4096 ? n / 4096 : 1;
                for (f2 = 0; f2 < n; f2 += step) {
                    const BYTE *fr = s->render_scratch + (size_t)f2 * fb;
                    /* every channel the mixer reads, not just the first two:
                     * a 5.1 client can carry signal only in its centre */
                    for (c2 = 0; c2 < s->channels && c2 < 12; c2++) {
                        float v = s->is_float ? ((const float *)fr)[c2]
                                : s->sample_bits == 16 ? ((const int16_t *)fr)[c2] * (1.0f / 32768.0f)
                                : ((const int32_t *)fr)[c2] * (1.0f / 2147483648.0f);
                        float a = v < 0 ? -v : v;
                        st[slot].sum_abs += a; if (a > st[slot].peak) st[slot].peak = a; if (a >= 0.99f) st[slot].clip++;
                        st[slot].frames++;
                    }
                }
                if (time(NULL) - st[slot].last >= 10 && st[slot].frames && !s->is_float) {   /* ml1067: what do the bytes look like */
                    const uint16_t *w = (const uint16_t *)s->render_scratch;
                    fprintf(stderr, "[ios_audio] ml1067 slot=%d first 12 words of the last buffer (%u frames asked): "
                            "%04x %04x %04x %04x %04x %04x %04x %04x %04x %04x %04x %04x\n", slot, n,
                            w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11]);
                }
                if (time(NULL) - st[slot].last >= 10 && st[slot].frames) {
                    fprintf(stderr, "[ios_audio] ml1065 slot=%d source: %llu samples, mean|x|=%.4f peak=%.3f clipped=%llu (rate %u ch %u float=%d bits=%d)\n",
                            slot, (unsigned long long)st[slot].frames, st[slot].sum_abs / (double)st[slot].frames, st[slot].peak,
                            (unsigned long long)st[slot].clip, s->sample_rate, s->channels, s->is_float, s->sample_bits);
                    st[slot].frames = 0; st[slot].sum_abs = 0; st[slot].peak = 0; st[slot].clip = 0; st[slot].last = time(NULL);
                }
            }
        }
        /* release-store AFTER the copy so the RT callback never reads
         * frames that aren't fully written */
        atomic_store_explicit(&s->write_pos, wr + n, memory_order_release);
    }
    s->pending_frames = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_capture_buffer(void *args) {
    struct get_capture_buffer_params *p = args;
    if (p->frames) *p->frames = 0;
    if (p->data) *p->data = NULL;
    if (p->flags) *p->flags = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_release_capture_buffer(void *args) {
    struct release_capture_buffer_params *p = args;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_is_format_supported(void *args) {
    struct is_format_supported_params *p = args;
    LOG_FN_CALL(14, "is_format_supported");
    /* Accept anything. */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_loopback_capture_device(void *args) {
    (void)args;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_mix_format(void *args) {
    struct get_mix_format_params *p = args;
    LOG_FN_CALL(16, "get_mix_format");
    /* WAVEFORMATEXTENSIBLE is 40 bytes; first 18 are WAVEFORMATEX */
    if (p->fmt) {
        memset(p->fmt, 0, 40);
        struct WAVEFORMATEX_stub *f = p->fmt;
        f->wFormatTag = 0xFFFE; /* WAVE_FORMAT_EXTENSIBLE */
        f->nChannels = IOS_AUDIO_CHANNELS;
        f->nSamplesPerSec = IOS_AUDIO_SAMPLE_RATE;
        f->wBitsPerSample = IOS_AUDIO_BITS;
        f->nBlockAlign = IOS_AUDIO_FRAME_BYTES;
        f->nAvgBytesPerSec = IOS_AUDIO_SAMPLE_RATE * IOS_AUDIO_FRAME_BYTES;
        f->cbSize = 22; /* extensible body */
        /* Extensible body: Samples (2), ChannelMask (4), SubFormat (16).
         * KSDATAFORMAT_SUBTYPE_PCM = {00000001-0000-0010-8000-00AA00389B71} */
        uint16_t *samples = (uint16_t *)((char *)p->fmt + 18);
        *samples = IOS_AUDIO_BITS;
        uint32_t *mask = (uint32_t *)((char *)p->fmt + 20);
        *mask = 0x3; /* SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT */
        /* SubFormat GUID PCM */
        static const uint8_t pcm_guid[16] = {   /* KSDATAFORMAT_SUBTYPE_IEEE_FLOAT (ml1068; was PCM) */
            0x03,0x00,0x00,0x00, 0x00,0x00, 0x10,0x00,
            0x80,0x00, 0x00,0xAA, 0x00,0x38,0x9B,0x71
        };
        memcpy((char *)p->fmt + 24, pcm_guid, 16);
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_device_period(void *args) {
    struct get_device_period_params *p = args;
    if (p->def_period) *p->def_period = 100000; /* 10 ms in 100ns units */
    if (p->min_period) *p->min_period = 50000;  /* 5 ms */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_buffer_size(void *args) {
    struct get_buffer_size_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->frames) *p->frames = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (p->frames) *p->frames = s->buffer_frames ? s->buffer_frames
                                                       : IOS_AUDIO_BUFFER_FRAMES;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_latency(void *args) {
    struct get_latency_params *p = args;
    if (p->latency) *p->latency = 100000; /* 10 ms */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_current_padding(void *args) {
    LOG_FN_CALL(20, "get_current_padding");
    struct get_current_padding_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->padding) *p->padding = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (p->padding) {
        if (ios_stream_is_live(s)) {
            uint64_t pad = atomic_load(&s->write_pos) - atomic_load(&s->play_pos);
            *p->padding = (UINT32)(pad > s->buffer_frames ? s->buffer_frames : pad);
        } else {
            *p->padding = 0; /* null-mode: always hungry */
        }
    }
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_next_packet_size(void *args) {
    struct get_next_packet_size_params *p = args;
    if (p->frames) *p->frames = 0;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_frequency(void *args) {
    struct get_frequency_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->freq) *p->freq = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    /* Returns the device frequency in Hz — what units IAudioClock uses. */
    if (p->freq) *p->freq = s->sample_rate ? s->sample_rate : IOS_AUDIO_SAMPLE_RATE;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_position(void *args) {
    LOG_FN_CALL(23, "get_position");
    struct get_position_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->pos) *p->pos = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    /* THIS is the function that drives FMOD's clock. Tier-2: frames the
     * RT callback actually consumed — the true hardware clock. Null-mode
     * fallback: wall-clock synthesis as before. */
    if (p->pos) {
        if (ios_stream_is_live(s))
            *p->pos = atomic_load(&s->play_pos);
        else
            *p->pos = elapsed_frames(s);
    }
    if (p->qpctime) *p->qpctime = mach_to_ns(mach_absolute_time()) / 100; /* 100ns ticks */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_set_volumes(void *args) {
    (void)args;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_set_event_handle(void *args) {
    struct set_event_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (s->event && s->event != p->event)
        fprintf(stderr, "[ios-astream] ml738 EVENT OVERWRITE gen=%u old=%p new=%p tid=%llx "
                        "-- the previous client will never be signalled again\n",
                g_stream_gen, s->event, p->event,
                (unsigned long long)ios_current_tid());
    else
        fprintf(stderr, "[ios-astream] ml738 EVENT set gen=%u handle=%p tid=%llx\n",
                g_stream_gen, p->event, (unsigned long long)ios_current_tid());
    s->event = p->event;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_set_sample_rate(void *args) {
    struct set_sample_rate_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (p->rate > 0) s->sample_rate = (UINT32)p->rate;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_test_connect(void *args) {
    LOG_FN_CALL(27, "test_connect");
    struct test_connect_params *p = args;
    p->priority = Priority_Preferred;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_is_started(void *args) {
    struct is_started_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    p->result = s->started ? S_OK : S_FALSE;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_prop_value(void *args) {
    struct get_prop_value_params *p = args;
    p->result = E_FAIL; /* property not supported — mmdevapi falls back */
    return STATUS_SUCCESS;
}

/* ---------------------------- MIDI and aux ----------------------------
 *
 * There is no MIDI backend on this port.  Saying so was NOT what this file
 * used to do: every one of the seven MIDI/aux slots pointed at one stub that
 * returned STATUS_SUCCESS and wrote nothing at all, which is not "no MIDI",
 * it is "success, and the answer is whatever was already on the caller's
 * stack".  That cost a whole core.
 *
 * mmdevapi's DriverProc (wine/dlls/mmdevapi/main.c, DRV_LOAD) starts a
 * notify_thread whenever midi_init leaves its *err at DRV_SUCCESS, and that
 * thread is `while (1) { midi_notify_wait; if (quit) break; ... }`.
 * midi_notify_wait is defined to BLOCK until a notification arrives or the
 * driver is released -- winecoreaudio.drv and winealsa.drv both sit on a
 * condition variable in it.  A stub that returns instantly without setting
 * *quit turns that loop into a spin on an uninitialised `quit` and an
 * uninitialised `notify.send_notify`: on the device the thread named
 * "mmdevapi_midi_notify" held a whole core inside the dispatcher with a
 * garbage guest RIP, and the program it belonged to never left "starting".
 *
 * So each entry point now answers for itself:
 *   midi_init        -> DRV_FAILURE, so DRV_LOAD fails and the thread is
 *                       never created (winmm then reports no MIDI devices,
 *                       which is the truth; waveOut does not come through
 *                       here -- mmdevapi exports no wodMessage).
 *   midi_notify_wait -> quit = TRUE, so even a thread that does exist leaves
 *                       its loop on the first turn instead of spinning.
 *   mid/mod/aux msg  -> MMSYSERR_NOTSUPPORTED and send_notify = FALSE.
 */
#define IOS_DRV_FAILURE           0   /* mmsystem.h DRV_FAILURE */
#define IOS_MMSYSERR_NOTSUPPORTED 8   /* mmsystem.h MMSYSERR_NOTSUPPORTED */

struct ios_midi_init_params { UINT *err; };
struct ios_midi_notify_wait_params { BOOL *quit; void *notify; };
struct ios_midi_message_params {
    UINT dev_id;
    UINT msg;
    UINT_PTR user;
    UINT_PTR param_1;
    UINT_PTR param_2;
    UINT *err;
    void *notify;
};
struct ios_aux_message_params {
    UINT dev_id;
    UINT msg;
    UINT_PTR user;
    UINT_PTR param_1;
    UINT_PTR param_2;
    UINT *err;
};

/* notify_context's first field is `BOOL send_notify` at offset 0 in both the
 * 64-bit and the 32-bit layout, so clearing it needs no other knowledge of
 * the struct and the same helper serves both tables. */
static void ios_midi_clear_notify(void *notify)
{
    if (notify) *(BOOL *)notify = 0;
}

static NTSTATUS ios_midi_stub(void *args) {
    /* midi_get_driver and midi_release: nothing to report, nothing to free. */
    (void)args;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_midi_init(void *args) {
    struct ios_midi_init_params *p = args;
    static int said;
    if (p && p->err) *p->err = IOS_DRV_FAILURE;
    if (!said++)
        fprintf(stderr, "[audio] midi_init -> DRV_FAILURE (no MIDI backend on this "
                        "port; mmdevapi will not start its notify thread)\n");
    return STATUS_SUCCESS;
}

static NTSTATUS ios_midi_notify_wait(void *args) {
    struct ios_midi_notify_wait_params *p = args;
    static int said;
    if (p) {
        if (p->quit) *p->quit = 1;
        ios_midi_clear_notify(p->notify);
    }
    if (!said++)
        fprintf(stderr, "[audio] midi_notify_wait -> quit=TRUE (there is nothing to "
                        "wait for; returning without this is a busy loop)\n");
    return STATUS_SUCCESS;
}

static NTSTATUS ios_midi_message(void *args) {
    struct ios_midi_message_params *p = args;
    static unsigned said;
    if (p) {
        if (p->err) *p->err = IOS_MMSYSERR_NOTSUPPORTED;
        ios_midi_clear_notify(p->notify);
    }
    if (said++ < 8)
        fprintf(stderr, "[audio] midi message msg=%u -> MMSYSERR_NOTSUPPORTED\n",
                p ? p->msg : 0);
    return STATUS_SUCCESS;
}

static NTSTATUS ios_aux_message(void *args) {
    struct ios_aux_message_params *p = args;
    static unsigned said;
    if (p && p->err) *p->err = IOS_MMSYSERR_NOTSUPPORTED;
    if (said++ < 8)
        fprintf(stderr, "[audio] aux message msg=%u -> MMSYSERR_NOTSUPPORTED\n",
                p ? p->msg : 0);
    return STATUS_SUCCESS;
}

/* Table indexed by enum unix_funcs in mmdevapi's unixlib.h (37 entries).
 * Order MUST match the enum exactly. */
const void *audio_null_ios_unix_call_funcs[] = {
    ios_process_attach,                /* process_attach */
    ios_process_detach,                /* process_detach */
    ios_main_loop,                     /* main_loop */
    ios_get_endpoint_ids,              /* get_endpoint_ids */
    ios_create_stream,                 /* create_stream */
    ios_release_stream,                /* release_stream */
    ios_start,                         /* start */
    ios_stop,                          /* stop */
    ios_reset,                         /* reset */
    ios_timer_loop,                    /* timer_loop */
    ios_get_render_buffer,             /* get_render_buffer */
    ios_release_render_buffer,         /* release_render_buffer */
    ios_get_capture_buffer,            /* get_capture_buffer */
    ios_release_capture_buffer,        /* release_capture_buffer */
    ios_is_format_supported,           /* is_format_supported */
    ios_get_loopback_capture_device,   /* get_loopback_capture_device */
    ios_get_mix_format,                /* get_mix_format */
    ios_get_device_period,             /* get_device_period */
    ios_get_buffer_size,               /* get_buffer_size */
    ios_get_latency,                   /* get_latency */
    ios_get_current_padding,           /* get_current_padding */
    ios_get_next_packet_size,          /* get_next_packet_size */
    ios_get_frequency,                 /* get_frequency */
    ios_get_position,                  /* get_position */
    ios_set_volumes,                   /* set_volumes */
    ios_set_event_handle,              /* set_event_handle */
    ios_set_sample_rate,               /* set_sample_rate */
    ios_test_connect,                  /* test_connect */
    ios_is_started,                    /* is_started */
    ios_get_prop_value,                /* get_prop_value */
    ios_midi_stub,                     /* midi_get_driver */
    ios_midi_init,                     /* midi_init */
    ios_midi_stub,                     /* midi_release   (args == NULL) */
    ios_midi_message,                  /* midi_out_message */
    ios_midi_message,                  /* midi_in_message */
    ios_midi_notify_wait,              /* midi_notify_wait */
    ios_aux_message,                   /* aux_message */
};

/* The MIDI/aux blocks carry pointers too, and a 32-bit mmdevapi builds them
 * with 4-byte UINT_PTRs, so the 64-bit entries above would write *err and
 * *quit at the wrong offsets -- and *quit not landing where notify_thread
 * reads it is precisely the spin this file is fixing. */
static NTSTATUS ios_wow64_midi_init(void *args)
{
    struct { PTR32 err; } *params32 = args;
    struct ios_midi_init_params params = {
        .err = ios_wow_host_ptr(params32->err),
    };
    return ios_midi_init(&params);
}

static NTSTATUS ios_wow64_midi_notify_wait(void *args)
{
    struct { PTR32 quit; PTR32 notify; } *params32 = args;
    struct ios_midi_notify_wait_params params = {
        .quit = ios_wow_host_ptr(params32->quit),
        .notify = ios_wow_host_ptr(params32->notify),
    };
    return ios_midi_notify_wait(&params);
}

static NTSTATUS ios_wow64_midi_message(void *args)
{
    struct {
        UINT dev_id;
        UINT msg;
        PTR32 user;
        PTR32 param_1;
        PTR32 param_2;
        PTR32 err;
        PTR32 notify;
    } *params32 = args;
    struct ios_midi_message_params params = {
        .dev_id = params32->dev_id,
        .msg = params32->msg,
        .user = params32->user,
        .param_1 = params32->param_1,
        .param_2 = params32->param_2,
        .err = ios_wow_host_ptr(params32->err),
        .notify = ios_wow_host_ptr(params32->notify),
    };
    return ios_midi_message(&params);
}

static NTSTATUS ios_wow64_aux_message(void *args)
{
    struct {
        UINT dev_id;
        UINT msg;
        PTR32 user;
        PTR32 param_1;
        PTR32 param_2;
        PTR32 err;
    } *params32 = args;
    struct ios_aux_message_params params = {
        .dev_id = params32->dev_id,
        .msg = params32->msg,
        .user = params32->user,
        .param_1 = params32->param_1,
        .param_2 = params32->param_2,
        .err = ios_wow_host_ptr(params32->err),
    };
    return ios_aux_message(&params);
}

/* ================= the 32-bit (WoW64) table =================
 *
 * and 7.10 item 1.  A 32-bit mmdevapi.dll
 * builds its argument blocks with 4-byte pointers and 4-byte HANDLEs, so the
 * table above would read every field after the first pointer at the wrong
 * offset.  `args` itself is already a HOST pointer -- the WoW64 module
 * converts that one outer pointer -- but every pointer EMBEDDED in the block
 * is still a GUEST address and needs + B before it is dereferenced, which is
 * what ios_wow_host_ptr() does (NULL-preserving); ios_wow_guest_ptr32()
 * writes one back.  Handles, stream handles, sizes, flags and enums are
 * never offset (invariant 4).
 *
 * Shape mirrors upstream's drivers (dlls/winecoreaudio.drv/coreaudio.c,
 * dlls/winealsa.drv/alsa.c): one thunk per call that carries a pointer, and
 * the 64-bit entry shared directly wherever the two layouts are identical
 * (a stream_handle is UINT64 and 8-byte aligned on i386 too) or the entry
 * ignores `args` entirely.  The ORDER is enum unix_funcs from
 * wine/dlls/mmdevapi/unixlib.h, the same order as the table above.
 *
 * Buffer contract: get_render_buffer is the only call that hands the client a
 * pointer, and its buffer is allocated inside the guest window by
 * ios_audio_alloc_scratch(); the thunk refuses to publish anything that is
 * not in the window.
 */

static NTSTATUS ios_wow64_main_loop(void *args)
{
    struct {
        PTR32 event;
    } *params32 = args;
    struct main_loop_params params = { .event = IOS_WOW_HANDLE(params32->event) };
    return ios_main_loop(&params);
}

static NTSTATUS ios_wow64_get_endpoint_ids(void *args)
{
    struct {
        EDataFlow flow;
        PTR32 endpoints;
        unsigned int size;
        HRESULT result;
        unsigned int num;
        unsigned int default_idx;
    } *params32 = args;
    struct get_endpoint_ids_params params = {
        .flow = params32->flow,
        /* the buffer mmdevapi allocated; endpoint.name/.device inside it are
         * byte OFFSETS, not pointers, so they need no conversion */
        .endpoints = ios_wow_host_ptr(params32->endpoints),
        .size = params32->size,
    };
    NTSTATUS status = ios_get_endpoint_ids(&params);
    params32->size = params.size;
    params32->result = params.result;
    params32->num = params.num;
    params32->default_idx = params.default_idx;
    return status;
}

static NTSTATUS ios_wow64_create_stream(void *args)
{
    struct {
        PTR32 name;
        PTR32 device;
        EDataFlow flow;
        int share;
        DWORD flags;
        REFERENCE_TIME duration;
        REFERENCE_TIME period;
        PTR32 fmt;
        HRESULT result;
        PTR32 channel_count;
        PTR32 stream;
    } *params32 = args;
    struct create_stream_params params = {
        .name = ios_wow_host_ptr(params32->name),
        .device = ios_wow_host_ptr(params32->device),
        .flow = params32->flow,
        .share = params32->share,
        .flags = params32->flags,
        .duration = params32->duration,
        .period = params32->period,
        .fmt = ios_wow_host_ptr(params32->fmt),
        .channel_count = ios_wow_host_ptr(params32->channel_count),
        /* *stream is a stream_handle (UINT64 in BOTH layouts) holding an
         * opaque driver handle -- never offset, never truncated */
        .stream = ios_wow_host_ptr(params32->stream),
    };
    NTSTATUS status = ios_create_stream(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_release_stream(void *args)
{
    struct {
        stream_handle stream;
        PTR32 timer_thread;
        HRESULT result;
    } *params32 = args;
    struct release_stream_params params = {
        .stream = params32->stream,
        .timer_thread = IOS_WOW_HANDLE(params32->timer_thread),
    };
    NTSTATUS status = ios_release_stream(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_render_buffer(void *args)
{
    struct {
        stream_handle stream;
        UINT32 frames;
        HRESULT result;
        PTR32 data;
    } *params32 = args;
    BYTE *data = NULL;
    struct get_render_buffer_params params = {
        .stream = params32->stream,
        .frames = params32->frames,
        .data = &data,
    };
    uint32_t *slot;
    NTSTATUS status = ios_get_render_buffer(&params);

    params32->result = params.result;
    if (!(slot = ios_wow_host_ptr(params32->data))) return status;
    /* invariant 1: the client writes its samples straight
     * into this pointer, so it must be a guest address.  Anything else is a
     * bug in ios_audio_alloc_scratch(), not something to truncate and hope. */
    if (data && !ios_wow_in_window(data)) {
        static int moaned;
        if (moaned++ < 8)
            fprintf(stderr, "[ios_audio] WOW64 get_render_buffer: scratch %p is OUTSIDE the "
                            "guest window [%p, +4G) -- refusing to publish it to 32-bit code\n",
                    (void *)data, (void *)ios_wow_base());
        *slot = 0;
        params32->result = E_FAIL;
        return status;
    }
    *slot = ios_wow_guest_ptr32(data);
    return status;
}

static NTSTATUS ios_wow64_get_capture_buffer(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 data;
        PTR32 frames;
        PTR32 flags;
        PTR32 devpos;
        PTR32 qpcpos;
    } *params32 = args;
    BYTE *data = NULL;
    struct get_capture_buffer_params params = {
        .stream = params32->stream,
        .data = &data,
        .frames = ios_wow_host_ptr(params32->frames),
        .flags = ios_wow_host_ptr(params32->flags),
        .devpos = ios_wow_host_ptr(params32->devpos),
        .qpcpos = ios_wow_host_ptr(params32->qpcpos),
    };
    uint32_t *slot;
    NTSTATUS status = ios_get_capture_buffer(&params);

    params32->result = params.result;
    /* this driver has no capture endpoint, so `data` is always NULL and
     * ios_wow_guest_ptr32() keeps it 0; the window check is the same
     * contract get_render_buffer enforces, should that ever change */
    if (!(slot = ios_wow_host_ptr(params32->data))) return status;
    if (data && !ios_wow_in_window(data)) {
        fprintf(stderr, "[ios_audio] WOW64 get_capture_buffer: buffer %p is OUTSIDE the "
                        "guest window -- refusing to publish it to 32-bit code\n", (void *)data);
        *slot = 0;
        params32->result = E_FAIL;
        return status;
    }
    *slot = ios_wow_guest_ptr32(data);
    return status;
}

static NTSTATUS ios_wow64_is_format_supported(void *args)
{
    struct {
        PTR32 device;
        EDataFlow flow;
        int share;
        PTR32 fmt_in;
        HRESULT result;
    } *params32 = args;
    struct is_format_supported_params params = {
        .device = ios_wow_host_ptr(params32->device),
        .flow = params32->flow,
        .share = params32->share,
        .fmt_in = ios_wow_host_ptr(params32->fmt_in),
    };
    NTSTATUS status = ios_is_format_supported(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_mix_format(void *args)
{
    struct {
        PTR32 device;
        EDataFlow flow;
        PTR32 fmt;
        HRESULT result;
    } *params32 = args;
    struct get_mix_format_params params = {
        .device = ios_wow_host_ptr(params32->device),
        .flow = params32->flow,
        /* WAVEFORMATEXTENSIBLE is fixed-width in both layouts */
        .fmt = ios_wow_host_ptr(params32->fmt),
    };
    NTSTATUS status = ios_get_mix_format(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_device_period(void *args)
{
    struct {
        PTR32 device;
        EDataFlow flow;
        HRESULT result;
        PTR32 def_period;
        PTR32 min_period;
    } *params32 = args;
    struct get_device_period_params params = {
        .device = ios_wow_host_ptr(params32->device),
        .flow = params32->flow,
        .def_period = ios_wow_host_ptr(params32->def_period),
        .min_period = ios_wow_host_ptr(params32->min_period),
    };
    NTSTATUS status = ios_get_device_period(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_buffer_size(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 frames;
    } *params32 = args;
    struct get_buffer_size_params params = {
        .stream = params32->stream,
        .frames = ios_wow_host_ptr(params32->frames),
    };
    NTSTATUS status = ios_get_buffer_size(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_latency(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 latency;
    } *params32 = args;
    struct get_latency_params params = {
        .stream = params32->stream,
        .latency = ios_wow_host_ptr(params32->latency),
    };
    NTSTATUS status = ios_get_latency(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_current_padding(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 padding;
    } *params32 = args;
    struct get_current_padding_params params = {
        .stream = params32->stream,
        .padding = ios_wow_host_ptr(params32->padding),
    };
    NTSTATUS status = ios_get_current_padding(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_next_packet_size(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 frames;
    } *params32 = args;
    struct get_next_packet_size_params params = {
        .stream = params32->stream,
        .frames = ios_wow_host_ptr(params32->frames),
    };
    NTSTATUS status = ios_get_next_packet_size(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_frequency(void *args)
{
    struct {
        stream_handle stream;
        HRESULT result;
        PTR32 freq;
    } *params32 = args;
    struct get_frequency_params params = {
        .stream = params32->stream,
        .freq = ios_wow_host_ptr(params32->freq),
    };
    NTSTATUS status = ios_get_frequency(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_get_position(void *args)
{
    struct {
        stream_handle stream;
        BOOL device;
        HRESULT result;
        PTR32 pos;
        PTR32 qpctime;
    } *params32 = args;
    struct get_position_params params = {
        .stream = params32->stream,
        .device = params32->device,
        .pos = ios_wow_host_ptr(params32->pos),
        .qpctime = ios_wow_host_ptr(params32->qpctime),
    };
    NTSTATUS status = ios_get_position(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_set_volumes(void *args)
{
    struct {
        stream_handle stream;
        float master_volume;
        PTR32 volumes;
        PTR32 session_volumes;
    } *params32 = args;
    struct set_volumes_params params = {
        .stream = params32->stream,
        .master_volume = params32->master_volume,
        .volumes = ios_wow_host_ptr(params32->volumes),
        .session_volumes = ios_wow_host_ptr(params32->session_volumes),
    };
    return ios_set_volumes(&params);
}

static NTSTATUS ios_wow64_set_event_handle(void *args)
{
    struct {
        stream_handle stream;
        PTR32 event;
        HRESULT result;
    } *params32 = args;
    struct set_event_handle_params params = {
        .stream = params32->stream,
        .event = IOS_WOW_HANDLE(params32->event),
    };
    NTSTATUS status = ios_set_event_handle(&params);
    params32->result = params.result;
    return status;
}

static NTSTATUS ios_wow64_test_connect(void *args)
{
    struct {
        PTR32 name;
        enum driver_priority priority;
    } *params32 = args;
    struct test_connect_params params = {
        .name = ios_wow_host_ptr(params32->name),
        .priority = params32->priority,
    };
    NTSTATUS status = ios_test_connect(&params);
    params32->priority = params.priority;
    return status;
}

static NTSTATUS ios_wow64_get_prop_value(void *args)
{
    struct {
        PTR32 device;
        EDataFlow flow;
        PTR32 guid;
        PTR32 prop;
        HRESULT result;
        PTR32 value;      /* PROPVARIANT, 32-bit layout */
        PTR32 buffer;
        PTR32 buffer_size;
    } *params32 = args;
    /* `value` is deliberately NOT forwarded: a 64-bit PROPVARIANT written into
     * the 32-bit slot would corrupt it, and this driver's get_prop_value is an
     * unconditional E_FAIL (mmdevapi falls back), so none is ever produced.
     * If that ever changes, say so instead of publishing a wrong struct. */
    struct get_prop_value_params params = {
        .device = ios_wow_host_ptr(params32->device),
        .flow = params32->flow,
        .guid = ios_wow_host_ptr(params32->guid),
        .prop = ios_wow_host_ptr(params32->prop),
        .value = NULL,
        .buffer = ios_wow_host_ptr(params32->buffer),
        .buffer_size = ios_wow_host_ptr(params32->buffer_size),
    };
    NTSTATUS status = ios_get_prop_value(&params);

    if (params.result >= 0) {
        fprintf(stderr, "[ios_audio] WOW64 get_prop_value succeeded but the 32-bit "
                        "PROPVARIANT copy-back is not implemented -- reporting E_FAIL\n");
        params32->result = (HRESULT)E_FAIL;
    }
    else params32->result = params.result;
    return status;
}

/* The MIDI/aux blocks carry pointers too, and a 32-bit mmdevapi builds them
 * with 4-byte UINT_PTRs, so the 64-bit entries above would write *err and
 * *quit at the wrong offsets -- and *quit not landing where notify_thread
 * reads it is precisely the spin this file is fixing. */
/* Table indexed by enum unix_funcs, same 37 slots and same order as
 * audio_null_ios_unix_call_funcs above.  Entries shared with the 64-bit table
 * either ignore `args` entirely or have a struct whose 32-bit and 64-bit
 * layouts are identical (stream_handle is UINT64 and 8-byte aligned in the
 * i386 MS ABI too, so { stream, UINT32..., HRESULT } lays out the same). */
const void *audio_null_ios_unix_call_wow64_funcs[] = {
    ios_process_attach,                /* process_attach  (args == NULL) */
    ios_process_detach,                /* process_detach  (args == NULL) */
    ios_wow64_main_loop,               /* main_loop */
    ios_wow64_get_endpoint_ids,        /* get_endpoint_ids */
    ios_wow64_create_stream,           /* create_stream */
    ios_wow64_release_stream,          /* release_stream */
    ios_start,                         /* start           { stream, result } */
    ios_stop,                          /* stop            { stream, result } */
    ios_reset,                         /* reset           { stream, result } */
    ios_timer_loop,                    /* timer_loop      { stream } */
    ios_wow64_get_render_buffer,       /* get_render_buffer */
    ios_release_render_buffer,         /* release_render_buffer (no pointers) */
    ios_wow64_get_capture_buffer,      /* get_capture_buffer */
    ios_release_capture_buffer,        /* release_capture_buffer (no pointers) */
    ios_wow64_is_format_supported,     /* is_format_supported */
    ios_get_loopback_capture_device,   /* get_loopback_capture_device (ignores args) */
    ios_wow64_get_mix_format,          /* get_mix_format */
    ios_wow64_get_device_period,       /* get_device_period */
    ios_wow64_get_buffer_size,         /* get_buffer_size */
    ios_wow64_get_latency,             /* get_latency */
    ios_wow64_get_current_padding,     /* get_current_padding */
    ios_wow64_get_next_packet_size,    /* get_next_packet_size */
    ios_wow64_get_frequency,           /* get_frequency */
    ios_wow64_get_position,            /* get_position */
    ios_wow64_set_volumes,             /* set_volumes */
    ios_wow64_set_event_handle,        /* set_event_handle */
    ios_set_sample_rate,               /* set_sample_rate { stream, float, result } */
    ios_wow64_test_connect,            /* test_connect */
    ios_is_started,                    /* is_started      { stream, result } */
    ios_wow64_get_prop_value,          /* get_prop_value */
    ios_midi_stub,                     /* midi_get_driver (ignores args) */
    ios_wow64_midi_init,               /* midi_init */
    ios_midi_stub,                     /* midi_release    (args == NULL) */
    ios_wow64_midi_message,            /* midi_out_message */
    ios_wow64_midi_message,            /* midi_in_message */
    ios_wow64_midi_notify_wait,        /* midi_notify_wait */
    ios_wow64_aux_message,             /* aux_message */
};
