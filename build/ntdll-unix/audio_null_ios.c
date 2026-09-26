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
#include <unistd.h>
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
#define E_NOTIMPL 0x80004001L
#define AUDCLNT_E_UNSUPPORTED_FORMAT ((HRESULT)0x88890008L)
#define AUDCLNT_E_BUFFER_TOO_LARGE ((HRESULT)0x88890006L)

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

struct get_loopback_capture_device_params {
    const WCHAR *name;
    const char *device;
    char *ret_device;
    UINT32 ret_device_len;
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

/* ------------------- MADEIRA: WoW64 guest window ------------------- */

/* WOW64_DESIGN.md 2 "shifted guest window": a 32-bit pseudo-process owns one
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

/* Handles are never offset (WOW64_DESIGN.md 3, invariant 4): a 32-bit HANDLE
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
#define IOS_AUDIO_BITS 16u
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
/* How one sample is stored in the client's buffer.  Derived from the format's
 * SubFormat GUID when it is EXTENSIBLE, never from the bit depth alone: 32-bit
 * is IEEE float OR PCM int32 and those two decode to completely different
 * audio.  Reading the bit depth and guessing is what "isn't playing the right
 * audio" sounds like. */
enum ios_sample_kind {
    IOS_SK_U8,      /* WAVE 8-bit PCM is UNSIGNED */
    IOS_SK_S16,
    IOS_SK_S24,     /* packed 3-byte container */
    IOS_SK_S32,
    IOS_SK_F32
};

struct ios_stream {
    int valid;
    int started;
    uint64_t start_mach;        /* mach_absolute_time() at start() (null-mode clock) */
    uint64_t accumulated_frames; /* null-mode: frames "played" before last stop */
    UINT32 sample_rate;
    UINT32 channels;
    UINT32 frame_bytes;          /* nBlockAlign of the stream format */
    enum ios_sample_kind kind;
    UINT32 valid_bits;           /* wValidBitsPerSample, for the log line */
    UINT32 channel_mask;         /* dwChannelMask, 0 = "use the default layout" */
    /* Per-client-channel gain into the engine's stereo bus.  Built once from
     * the channel mask at create_stream; this is the 5.1 (and 7.1, and quad,
     * and mono) downmix. */
    float mix_gain[8][2];
    UINT32 buffer_frames;        /* ring capacity in frames */
    BYTE *render_scratch;        /* contiguous area handed to GetBuffer */
    UINT32 scratch_frames;       /* scratch capacity */
    /* MADEIRA: how render_scratch was obtained.  A 32-bit client can only
     * address memory inside its guest window, so for a WoW process the
     * scratch is an NtAllocateVirtualMemory reservation under a guest
     * ceiling instead of a calloc(); scratch_guest says which free() to
     * use.  See ios_audio_alloc_scratch(). */
    int scratch_guest;
    UINT_PTR scratch_bytes;      /* reservation size (scratch_guest only) */
    UINT32 pending_frames;       /* frames handed out, awaiting release */
    HANDLE event;
    /* The ring is ALWAYS engine-side stereo float32 -- 2 floats per client
     * frame -- not the client's own format.  release_render_buffer converts
     * and downmixes into it on the game's own thread, so the Core Audio
     * render thread only has to resample and sum. */
    float *ring;
    _Atomic uint64_t write_pos;  /* client frames produced by the game (monotonic) */
    _Atomic uint64_t play_pos;   /* client frames consumed by the mixer */
    /* 16.16 step from one engine frame to client frames, and the current
     * fractional position inside play_pos.  Both are owned by the render
     * thread.  A stream at the engine's own rate has step == 0x10000 and the
     * interpolation below degenerates to a copy. */
    uint32_t resample_step;
    uint32_t resample_frac;
    /* Diagnostics for the 10 s line. */
    _Atomic uint64_t stat_frames_written;
    _Atomic uint32_t stat_underruns;
    _Atomic uint32_t stat_peak_q16;
    _Atomic uint32_t stat_event_signals;
    _Atomic uint32_t stat_max_gap_us;   /* longest silence between two
                                         * release_render_buffer calls: the
                                         * one number that says whether a
                                         * dropout was the client stalling or
                                         * us failing to drain */
    uint64_t last_release_mach;
    /* ml1100: THE LATENCY ITSELF, which no counter here has ever reported.
     *
     * "A stutter every few seconds, after which the audio stays slightly
     * delayed" is a claim about write_pos - play_pos, and nothing measured it.
     * It matters because the ring's latency can only ever GROW on its own: an
     * underrun freezes play_pos (ios_mix_stream stops advancing when the ring
     * is dry) while the client keeps queueing, so the frames that should have
     * played during the gap are not dropped -- they are played late, and every
     * subsequent frame inherits that offset for the rest of the session.
     * pad_min over a whole window is the number that proves or disproves it:
     * a stable pad_min is a stable latency, a pad_min that steps up and stays
     * up is exactly the reported symptom. Owned by the render thread. */
    _Atomic uint32_t stat_pad_min;
    _Atomic uint32_t stat_pad_max;
    _Atomic uint32_t stat_resyncs;
    int underrun_pending;               /* render thread only: re-centre next callback */
    unsigned int resync_holdoff;        /* render thread only: callbacks until another re-centre is allowed */
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
/* Declared here rather than beside the engine below because the registry
 * helpers need them; see the comment on stream_register. */
static pthread_mutex_t g_mix_lock;
static void ios_engine_stop_if_idle(void);

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

/* The registry is read by TWO readers with very different rules: ordinary Wine
 * threads validating a handle (often, cheaply, under g_streams_lock) and the
 * Core Audio render thread walking it to mix (under g_mix_lock, which it only
 * ever try-locks).  Mutating it therefore takes both, mix lock first, so the
 * render callback can never walk a half-written slot -- and so that a stream
 * about to be freed cannot be picked up by a pass already in flight.  Handle
 * validation keeps taking the cheap lock only. */
static int stream_register(struct ios_stream *s)
{
    int i, n = 0;
    pthread_mutex_lock(&g_mix_lock);
    pthread_mutex_lock(&g_streams_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i]) n++;
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (!g_streams[i]) { g_streams[i] = s; break; }
    pthread_mutex_unlock(&g_streams_lock);
    pthread_mutex_unlock(&g_mix_lock);
    if (i == IOS_MAX_STREAMS) return -1;
    fprintf(stderr, "[ios-astream] ml739 CREATE stream=%p (%d now live)\n", (void *)s, n + 1);
    return 0;
}

static void stream_unregister(struct ios_stream *s)
{
    int i, n = 0;
    pthread_mutex_lock(&g_mix_lock);
    pthread_mutex_lock(&g_streams_lock);
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i] == s) g_streams[i] = NULL;
    for (i = 0; i < IOS_MAX_STREAMS; i++) if (g_streams[i]) n++;
    pthread_mutex_unlock(&g_streams_lock);
    /* Still holding the mix lock: the caller frees the stream the moment this
     * returns, and taking the lock here has waited out any render pass that
     * was already reading it. */
    ios_engine_stop_if_idle();
    pthread_mutex_unlock(&g_mix_lock);
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

/* One line per DISTINCT outcome.  The per-function counters above say how
 * often an entry point was reached; they say nothing about what it answered,
 * and a negotiation that ends in a loop or in silence is a sequence of
 * ANSWERS.  Printing every answer would drown the log (get_current_padding
 * alone runs at the device period), so each caller derives a small key from
 * the arguments and the HRESULT it is about to return, and the line is
 * printed the first time that exact key is seen.  A fixed 64-slot table, no
 * eviction: once it is full the port is answering more than 64 distinct ways
 * and the log has already shown the interesting ones. */
#define IOS_LOG_KEYS 64
static _Atomic uint32_t g_log_keys[IOS_LOG_KEYS];
static _Atomic uint32_t g_log_key_n;

static int ios_outcome_is_new(uint32_t key)
{
    uint32_t n, i;
    if (!key) key = 1;                    /* 0 marks an empty slot */
    n = atomic_load_explicit(&g_log_key_n, memory_order_acquire);
    for (i = 0; i < n && i < IOS_LOG_KEYS; i++)
        if (atomic_load_explicit(&g_log_keys[i], memory_order_relaxed) == key) return 0;
    n = atomic_fetch_add_explicit(&g_log_key_n, 1, memory_order_acq_rel);
    if (n >= IOS_LOG_KEYS) return 0;
    atomic_store_explicit(&g_log_keys[n], key, memory_order_release);
    return 1;
}

/* Fold a WAVEFORMATEX and an HRESULT into one key.  Different formats and
 * different answers for the same format both produce a new line; a repeat of
 * either does not. */
static uint32_t ios_fmt_key(const struct WAVEFORMATEX_stub *fmt, int share, HRESULT hr)
{
    uint32_t k = 0x9e3779b9u ^ (uint32_t)hr ^ ((uint32_t)share << 28);
    if (fmt) {
        k = k * 31u + fmt->wFormatTag;
        k = k * 31u + fmt->nChannels;
        k = k * 31u + fmt->nSamplesPerSec;
        k = k * 31u + fmt->wBitsPerSample;
        k = k * 31u + fmt->nBlockAlign;
    }
    return k;
}

static void ios_log_fmt(const char *what, const struct WAVEFORMATEX_stub *fmt,
                        int share, HRESULT hr)
{
    if (!ios_outcome_is_new(ios_fmt_key(fmt, share, hr))) return;
    if (!fmt) {
        fprintf(stderr, "[audio] %s fmt=(null) share=%d -> 0x%08x\n",
                what, share, (unsigned)hr);
        return;
    }
    fprintf(stderr, "[audio] %s fmt=tag%u/%uch/%uHz/%ubit/align%u share=%s -> 0x%08x\n",
            what, fmt->wFormatTag, fmt->nChannels, fmt->nSamplesPerSec,
            fmt->wBitsPerSample, fmt->nBlockAlign,
            share == 0 ? "shared" : "exclusive", (unsigned)hr);
}

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

/* ------------------- format decoding ------------------- */

/* WAVEFORMATEXTENSIBLE body, at the byte offsets the struct has on every
 * Windows ABI: [0..17] WAVEFORMATEX, [18] Samples (union, wValidBitsPerSample),
 * [20] dwChannelMask, [24] SubFormat GUID (16 bytes).  This file carries no
 * Wine headers (see the struct-mirror note at the top), so the body is read by
 * offset rather than through a struct. */
static int ios_fmt_is_extensible(const struct WAVEFORMATEX_stub *fmt) {
    return fmt && fmt->wFormatTag == 0xFFFE && fmt->cbSize >= 22;
}

/* The format tag that actually decides the sample layout: for EXTENSIBLE that
 * is the first DWORD of the SubFormat GUID (KSDATAFORMAT_SUBTYPE_PCM is
 * {00000001-...}, _IEEE_FLOAT is {00000003-...}), not wFormatTag and not the
 * bit depth. */
static UINT32 ios_fmt_tag(const struct WAVEFORMATEX_stub *fmt) {
    if (!fmt) return 0;
    if (!ios_fmt_is_extensible(fmt)) return fmt->wFormatTag;
    {
        const uint8_t *sub = (const uint8_t *)fmt + 24;
        return (UINT32)sub[0] | ((UINT32)sub[1] << 8) |
               ((UINT32)sub[2] << 16) | ((UINT32)sub[3] << 24);
    }
}

static int ios_fmt_is_float(const struct WAVEFORMATEX_stub *fmt) {
    return ios_fmt_tag(fmt) == 3;
}

static UINT32 ios_fmt_valid_bits(const struct WAVEFORMATEX_stub *fmt) {
    UINT32 v;
    if (!fmt) return 0;
    if (!ios_fmt_is_extensible(fmt)) return fmt->wBitsPerSample;
    v = *(const uint16_t *)((const char *)fmt + 18);
    /* 0 means "same as the container"; anything larger is a broken header. */
    if (!v || v > fmt->wBitsPerSample) v = fmt->wBitsPerSample;
    return v;
}

static UINT32 ios_fmt_channel_mask(const struct WAVEFORMATEX_stub *fmt) {
    if (!ios_fmt_is_extensible(fmt)) return 0;
    return *(const uint32_t *)((const char *)fmt + 20);
}

/* Container size -> how to read one sample.  wValidBitsPerSample smaller than
 * the container (24-in-32) needs no rescaling: WAVEFORMATEXTENSIBLE stores
 * those samples MSB-justified inside the container, so reading the container
 * as a full-range integer is already correct.  The valid-bits count is kept
 * only so the 10 s line can show it, because a producer that right-justifies
 * instead would show up as audio ~48 dB too quiet and nothing else would say
 * why. */
static enum ios_sample_kind ios_fmt_kind(const struct WAVEFORMATEX_stub *fmt) {
    if (ios_fmt_is_float(fmt)) return IOS_SK_F32;
    switch (fmt->wBitsPerSample) {
    case 8:  return IOS_SK_U8;
    case 24: return IOS_SK_S24;
    case 32: return IOS_SK_S32;
    default: return IOS_SK_S16;
    }
}

/* One sample of channel `c` of one frame, as a float in [-1, 1]. */
static float ios_sample_to_float(enum ios_sample_kind kind, const BYTE *frame, UINT32 c) {
    switch (kind) {
    case IOS_SK_F32: { float v; memcpy(&v, frame + (size_t)c * 4, 4); return v; }
    case IOS_SK_U8:  return ((int)frame[c] - 128) * (1.0f / 128.0f);
    case IOS_SK_S24: {
        const BYTE *p = frame + (size_t)c * 3;
        /* little-endian 24-bit, promoted to the top of an int32 so one scale
         * factor serves every integer width */
        int32_t v = (int32_t)(((uint32_t)p[0] << 8) | ((uint32_t)p[1] << 16) |
                              ((uint32_t)p[2] << 24));
        return v * (1.0f / 2147483648.0f);
    }
    case IOS_SK_S32: { int32_t v; memcpy(&v, frame + (size_t)c * 4, 4); return v * (1.0f / 2147483648.0f); }
    case IOS_SK_S16: default: { int16_t v; memcpy(&v, frame + (size_t)c * 2, 2); return v * (1.0f / 32768.0f); }
    }
}

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

#define IOS_GAIN_M3DB 0.70710678f

/* Build the per-channel downmix into the stereo bus.
 *
 * THIS IS THE BUG THE DEVICE HEARD.  A 5.1 stream used to be handed to a
 * 6-channel RemoteIO unit on a device whose route is stereo: the hardware
 * takes the interleaved 24-byte frames as if they were its own, so playback
 * runs three times too fast with every third sample from a different speaker
 * -- static that has the shape of the real audio in it.  Nothing downmixes
 * for us, so this does, with the standard ITU coefficients: centre and the
 * surrounds fold in at -3 dB, LFE at -10 dB (dropping it entirely loses the
 * bass a game puts ONLY there), and the mixer saturates at the end.
 *
 * The layout comes from dwChannelMask when there is one.  When there is not
 * -- a plain WAVEFORMATEX, which is most of DirectSound and all of waveOut --
 * the channel count implies the standard layout, which is what every other
 * WASAPI implementation assumes too. */
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
    UINT32 ch = s->channels, c, bit, i;

    memset(s->mix_gain, 0, sizeof(s->mix_gain));
    if (ch > 8) ch = 8;

    /* One channel is mono however it is labelled: it goes to both sides at
     * unity, not at -3 dB, or a mono game is half as loud as a stereo one. */
    if (ch == 1) {
        s->mix_gain[0][0] = s->mix_gain[0][1] = 1.0f;
        return;
    }

    if (!mask || ch > 8) mask = default_mask[ch <= 8 ? ch : 8];

    /* Walk the mask low bit first; the Nth set bit is the Nth channel in the
     * interleaved frame.  A mask with fewer bits than there are channels
     * leaves the extra channels at zero rather than guessing. */
    c = 0;
    for (i = 0; i < 11 && c < ch; i++) {
        bit = 1u << i;
        if (!(mask & bit)) continue;
        switch (bit) {
        case IOS_SPK_FRONT_LEFT:            s->mix_gain[c][0] = 1.0f; break;
        case IOS_SPK_FRONT_RIGHT:           s->mix_gain[c][1] = 1.0f; break;
        case IOS_SPK_FRONT_CENTER:
        case IOS_SPK_BACK_CENTER:
            s->mix_gain[c][0] = s->mix_gain[c][1] = IOS_GAIN_M3DB; break;
        case IOS_SPK_LOW_FREQUENCY:
            s->mix_gain[c][0] = s->mix_gain[c][1] = 0.316f; /* -10 dB */ break;
        case IOS_SPK_BACK_LEFT:
        case IOS_SPK_SIDE_LEFT:
        case IOS_SPK_FRONT_LEFT_OF_CENTER:  s->mix_gain[c][0] = IOS_GAIN_M3DB; break;
        case IOS_SPK_BACK_RIGHT:
        case IOS_SPK_SIDE_RIGHT:
        case IOS_SPK_FRONT_RIGHT_OF_CENTER: s->mix_gain[c][1] = IOS_GAIN_M3DB; break;
        default: break;
        }
        c++;
    }
    /* A mask that named fewer speakers than the stream has channels (or named
     * none we know) would silence the rest; fold anything left over into both
     * sides quietly rather than dropping it. */
    for (; c < ch; c++)
        s->mix_gain[c][0] = s->mix_gain[c][1] = 0.5f;
}

/* ------------------- Tier-2: one RemoteIO engine, N streams -------------
 *
 * There used to be one AudioUnit PER STREAM.  A title that opens three
 * concurrent clients -- an XAudio2 mastering voice, a 5.1 cue bank and a
 * stereo one is an ordinary shape -- then had three RemoteIO instances all
 * rendering into the same route with nothing arbitrating between them.  The
 * hardware picks one, or interleaves them, and the result is the static the
 * device reported.  WASAPI shared mode is by definition a mixer: one engine,
 * one output format, every client summed into it.  So: ONE unit, owned by the
 * driver rather than by any stream, running stereo float32 at the hardware's
 * own sample rate, and a software mixer in the render callback. */
static AudioUnit g_engine_au;
static int g_engine_running;
static UINT32 g_engine_rate = IOS_AUDIO_SAMPLE_RATE;
/* g_mix_lock (declared with the registry above) guards the stream registry
 * against the render callback.  The callback only ever TRY-locks it (blocking
 * a Core Audio render thread is never allowed); the rare miss, while a stream
 * is being created or freed, costs one buffer of silence and is counted. */
static _Atomic uint32_t g_mix_lock_misses;

static uint32_t ios_resample_step(UINT32 stream_rate)
{
    uint64_t step;
    if (!stream_rate || !g_engine_rate) return 0x10000u;
    /* client frames per engine frame, 16.16 */
    step = ((uint64_t)stream_rate << 16) / g_engine_rate;
    if (!step) step = 1;
    return (uint32_t)step;
}

/* ml1100: see the re-centre note in ios_mix_stream.  Read once; the render
 * thread must not call getenv. */
static int ios_audio_resync_on(void)
{
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("MADEIRA_AUDIO_RESYNC");
        cached = !(e && e[0] == '0');
    }
    return cached;
}

/* Sum ONE stream into the engine's stereo bus.  Core Audio real-time thread:
 * ring + atomics only, no Wine calls, no allocation, no logging.  An underrun
 * simply contributes nothing further -- WASAPI-correct, since padding drains
 * to zero and the position clock pauses at write_pos. */
static void ios_mix_stream(struct ios_stream *s, float *out, UInt32 nframes)
{
    uint64_t play = atomic_load_explicit(&s->play_pos, memory_order_relaxed);
    uint64_t wr = atomic_load_explicit(&s->write_pos, memory_order_acquire);
    uint64_t avail = wr - play;
    uint32_t cap = s->buffer_frames;
    uint32_t step = s->resample_step ? s->resample_step : 0x10000u;
    uint32_t frac = s->resample_frac;
    UInt32 i;

    if (!cap || !s->ring) return;

    /* ml1100: RE-CENTRE AFTER AN UNDERRUN, AND ONLY AFTER ONE.
     *
     * This is the one place latency is permanently added: the loop below stops
     * advancing play_pos when the ring is dry, so the wall time spent dry is
     * time the client's queued audio is simply shifted by.  Dropping a client's
     * audio is otherwise WRONG -- the padding a healthy WASAPI client carries is
     * its own choice and its own buffering -- so the correction fires only on
     * the callback after a dry spell, and only when the refill overshot, and it
     * leaves exactly one period queued.  With no underrun this branch is a
     * single predictable test per callback and never runs.
     *
     * MADEIRA_AUDIO_RESYNC=0 disables it; the [audio] line reports resyncs=N
     * either way, so a session that never underruns is visibly a session where
     * this made no difference. */
    if (s->resync_holdoff) s->resync_holdoff--;
    if (s->underrun_pending) {
        uint32_t period = s->sample_rate ? s->sample_rate / 100u : 480u;
        /* ml1130: WHAT IS KEPT MUST OUTLAST THE NEXT CALLBACK.
         *
         * ml1100 kept exactly one 10 ms period.  The device takes a whole
         * callback at once -- 1024 frames, 21.3 ms, on the hardware in every
         * log -- so the very next callback found 10 ms queued, ran dry, armed
         * this branch again, and the client's refill was trimmed to 10 ms
         * again: one underrun and one resync per callback for the rest of the
         * session (a device log: underruns=1630 resyncs=1628, pad_ms=10..10).
         * A single start-up hiccup turned into permanently broken audio.
         *
         * Keep two callbacks' worth of CLIENT frames plus a period, correct
         * only when the queue is more than twice that, and never twice within
         * ~2 s of callbacks, so this can only ever shorten a queue that is
         * genuinely long and can never feed itself. */
        uint64_t per_cb = ((uint64_t)nframes * step + 0xffffu) >> 16;
        uint64_t keep;
        if (!period) period = 1;
        keep = 2ull * per_cb + period;
        if (avail > 2ull * keep && !s->resync_holdoff && ios_audio_resync_on()) {
            play += avail - keep;
            avail = keep;
            atomic_fetch_add_explicit(&s->stat_resyncs, 1, memory_order_relaxed);
            s->underrun_pending = 0;
            s->resync_holdoff = 100;
        } else if (avail >= 1) {
            /* Refilled without overshooting, or the knob is off: either way the
             * dry spell is over and there is nothing left to correct. */
            s->underrun_pending = 0;
        }
    }

    /* The latency census.  One min/max update per callback, not per frame. */
    {
        uint32_t pad = (uint32_t)(avail > 0xffffffffull ? 0xffffffffull : avail);
        uint32_t old = atomic_load_explicit(&s->stat_pad_max, memory_order_relaxed);
        if (pad > old) atomic_store_explicit(&s->stat_pad_max, pad, memory_order_relaxed);
        old = atomic_load_explicit(&s->stat_pad_min, memory_order_relaxed);
        if (!old || pad < old) atomic_store_explicit(&s->stat_pad_min, pad, memory_order_relaxed);
    }

    for (i = 0; i < nframes; i++) {
        uint32_t idx, adv;
        float l, r;
        /* Interpolation needs the next frame too, but only when we are
         * actually between frames -- at the engine's own rate frac is always
         * zero and one available frame is enough. */
        if (avail < (frac ? 2u : 1u)) {
            atomic_fetch_add_explicit(&s->stat_underruns, 1, memory_order_relaxed);
            /* ml1100: arm the re-centre. play_pos stops here, so from this
             * moment the client's queue is running late by however long the
             * ring stays dry. */
            s->underrun_pending = 1;
            break;
        }
        idx = (uint32_t)(play % cap);
        l = s->ring[(size_t)idx * 2];
        r = s->ring[(size_t)idx * 2 + 1];
        if (frac) {
            uint32_t idx2 = (idx + 1) % cap;
            float t = (float)frac * (1.0f / 65536.0f);
            l += (s->ring[(size_t)idx2 * 2] - l) * t;
            r += (s->ring[(size_t)idx2 * 2 + 1] - r) * t;
        }
        out[(size_t)i * 2] += l;
        out[(size_t)i * 2 + 1] += r;
        frac += step;
        adv = frac >> 16;
        frac &= 0xffffu;
        if (adv > avail) adv = (uint32_t)avail;
        play += adv;
        avail -= adv;
    }
    s->resample_frac = frac;
    atomic_store_explicit(&s->play_pos, play, memory_order_release);
}

/* ---------------------------- the bus limiter ----------------------------
 *
 * A float WASAPI client is NOT required to keep its samples inside [-1, 1].
 * XAudio2 says so explicitly: voices sum without clamping and it is the
 * endpoint's job to cope.  The device census caught a title's mastering voice
 * running at a peak of 7.99 -- +18 dB over full scale -- and this driver was
 * hard-clipping every one of those samples to 1.0.  Clipping a signal that is
 * eight times too big does not make it quieter, it replaces it with a square
 * wave: that is the "horrible static" the device reported, and it appeared in
 * gameplay and cutscenes (many voices summed) while the menu (one quiet
 * voice) sounded fine.
 *
 * Windows does not clip here either; its shared-mode engine runs a limiter
 * that rides the gain down.  So does this.  Per block: find the block's peak
 * BEFORE applying anything, move an envelope follower (instant attack, ~250 ms
 * release), derive gain = min(1, 0.98/envelope), and ramp linearly from the
 * previous block's gain to this one's across the block so the gain changes do
 * not themselves become zipper noise.  The hard clamp stays as a safety net
 * for the one block a transient can outrun, where it now trims a fraction of
 * a dB instead of 18.
 *
 * Cost: one max-scan and one multiply per sample, on a buffer that is already
 * being walked.  All three variables are owned by the render thread alone. */
#define IOS_LIMITER_CEILING 0.98f
#define IOS_LIMITER_RELEASE_FRAMES 12000u   /* ~250 ms at 48 kHz */

static float g_lim_env;          /* peak envelope, RT-owned */
static float g_lim_gain = 1.0f;  /* gain applied at the end of the last block */
static _Atomic uint32_t g_lim_min_gain_q16;  /* census: worst gain this window */
static _Atomic uint32_t g_lim_active;        /* census: blocks that needed < 1 */

static void ios_limit_block(float *out, size_t samples, UInt32 nframes)
{
    float peak = 0.0f, target, gain, dg;
    size_t j;

    for (j = 0; j < samples; j++) {
        float a = out[j] < 0.0f ? -out[j] : out[j];
        if (a > peak) peak = a;
    }

    /* Instant attack, one-pole release.  The release coefficient is derived
     * from this block's length so the time constant is the same whatever
     * buffer size Core Audio hands us. */
    if (peak > g_lim_env) g_lim_env = peak;
    else {
        float k = (float)nframes / (float)IOS_LIMITER_RELEASE_FRAMES;
        if (k > 1.0f) k = 1.0f;
        g_lim_env += (peak - g_lim_env) * k;
    }

    target = g_lim_env > IOS_LIMITER_CEILING ? IOS_LIMITER_CEILING / g_lim_env : 1.0f;

    if (target < 1.0f || g_lim_gain < 1.0f) {
        /* Ducking is done inside 1 ms, so a transient is caught in the block
         * that contains it rather than over the whole block; coming back up
         * takes the whole block, because that is where zipper noise lives and
         * the envelope's release is already slow. */
        UInt32 ramp = nframes, f = 0;
        if (target < g_lim_gain) {
            ramp = g_engine_rate / 1000;
            if (!ramp || ramp > nframes) ramp = nframes;
        }
        gain = g_lim_gain;
        dg = ramp ? (target - g_lim_gain) / (float)ramp : 0.0f;
        for (j = 0; j < samples; j += 2, f++) {
            out[j] *= gain;
            out[j + 1] *= gain;
            if (f < ramp) gain += dg; else gain = target;
        }
        {
            uint32_t q = (uint32_t)(target * 65536.0f);
            uint32_t old = atomic_load_explicit(&g_lim_min_gain_q16, memory_order_relaxed);
            /* 0 is "nothing recorded yet", so the first sample always wins */
            while ((!old || q < old) &&
                   !atomic_compare_exchange_weak_explicit(&g_lim_min_gain_q16, &old, q,
                                                          memory_order_relaxed,
                                                          memory_order_relaxed))
                ;
        }
        atomic_fetch_add_explicit(&g_lim_active, 1, memory_order_relaxed);
    }
    g_lim_gain = target;

    /* Safety net only: after the limiter this trims a transient's first block,
     * not a whole signal. */
    for (j = 0; j < samples; j++) {
        float v = out[j];
        out[j] = v > 1.0f ? 1.0f : (v < -1.0f ? -1.0f : v);
    }
}

static OSStatus ios_engine_render_cb(void *refcon, AudioUnitRenderActionFlags *flags,
                                     const AudioTimeStamp *ts, UInt32 bus,
                                     UInt32 nframes, AudioBufferList *iodata) {
    float *out = (float *)iodata->mBuffers[0].mData;
    size_t samples = (size_t)nframes * 2;
    int i;
    (void)refcon; (void)flags; (void)ts; (void)bus;

    memset(out, 0, samples * sizeof(float));
    if (pthread_mutex_trylock(&g_mix_lock)) {
        atomic_fetch_add_explicit(&g_mix_lock_misses, 1, memory_order_relaxed);
        return noErr;
    }
    for (i = 0; i < IOS_MAX_STREAMS; i++) {
        struct ios_stream *s = g_streams[i];
        if (s && s->valid && s->started) ios_mix_stream(s, out, nframes);
    }
    pthread_mutex_unlock(&g_mix_lock);
    ios_limit_block(out, samples, nframes);
    return noErr;
}

/* Is this a PCM or float format this driver can actually open?  The RemoteIO
 * unit is built from the client's own format in create_stream, so "supported"
 * means "an AudioStreamBasicDescription can be spelled for it": packed linear
 * PCM, one to eight channels, a sane rate, and a block alignment that matches
 * the container size.  Anything else gets the closest-match treatment rather
 * than a lie -- mmdevapi's client.c turns S_FALSE into GetMixFormat() for a
 * shared-mode caller and into AUDCLNT_E_UNSUPPORTED_FORMAT for an exclusive
 * one, which is exactly the WASAPI contract. */
static int ios_fmt_openable(const struct WAVEFORMATEX_stub *fmt)
{
    UINT32 container;

    if (!fmt) return 0;
    /* 1 = WAVE_FORMAT_PCM, 3 = IEEE_FLOAT, 0xFFFE = EXTENSIBLE */
    if (fmt->wFormatTag != 1 && fmt->wFormatTag != 3 && fmt->wFormatTag != 0xFFFE)
        return 0;
    if (fmt->nChannels < 1 || fmt->nChannels > 8) return 0;
    if (fmt->nSamplesPerSec < 4000 || fmt->nSamplesPerSec > 192000) return 0;
    if (fmt->wBitsPerSample != 8 && fmt->wBitsPerSample != 16 &&
        fmt->wBitsPerSample != 24 && fmt->wBitsPerSample != 32) return 0;
    if (ios_fmt_is_float(fmt) && fmt->wBitsPerSample != 32) return 0;
    if (!fmt->nBlockAlign) return 0;
    container = fmt->nBlockAlign / fmt->nChannels;
    if (container * fmt->nChannels != fmt->nBlockAlign) return 0;
    if (container * 8 != fmt->wBitsPerSample) return 0;
    return 1;
}

/* Build the ONE output unit, once, at the hardware's own sample rate.  Any
 * failure leaves g_engine_au NULL, which is the null-mode fallback: streams
 * still keep time off the wall clock so a game's audio-driven logic advances
 * even with no audible output.  Called with g_mix_lock held. */
static int ios_engine_ensure(void) {
    AudioComponentDescription desc = {0};
    AudioStreamBasicDescription asbd = {0};
    AudioStreamBasicDescription hw = {0};
    AURenderCallbackStruct cb;
    AudioComponent comp;
    UInt32 sz = sizeof(hw);
    AudioUnit au = NULL;
    OSStatus err;

    if (g_engine_au) return 0;

    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) { fprintf(stderr, "[audio] RemoteIO component not found\n"); return -1; }
    if ((err = AudioComponentInstanceNew(comp, &au))) {
        fprintf(stderr, "[audio] AudioComponentInstanceNew: %d\n", (int)err);
        return -1;
    }

    /* Ask the unit what the route is actually running at rather than assuming
     * 48 kHz.  A headset or a Bluetooth route can put the session at 44.1 or
     * 16 kHz, and a client format that disagrees with the hardware either
     * makes RemoteIO resample behind our back or plays at the wrong speed.
     * Matching it here means the only resampling is ours, per stream, and it
     * is visible in the log. */
    g_engine_rate = IOS_AUDIO_SAMPLE_RATE;
    if (!AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Output, 0, &hw, &sz) &&
        hw.mSampleRate >= 4000.0 && hw.mSampleRate <= 192000.0)
        g_engine_rate = (UINT32)hw.mSampleRate;

    /* Stereo float32, interleaved: the engine's mix bus.  Everything a client
     * opens is converted and downmixed into this one shape. */
    asbd.mSampleRate = g_engine_rate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mChannelsPerFrame = 2;
    asbd.mBitsPerChannel = 32;
    asbd.mBytesPerFrame = 2 * 4;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;

    err = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
    if (err) {
        fprintf(stderr, "[audio] SetProperty(StreamFormat %u Hz stereo float32): %d\n",
                g_engine_rate, (int)err);
        goto fail;
    }

    cb.inputProc = ios_engine_render_cb;
    cb.inputProcRefCon = NULL;
    err = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (err) { fprintf(stderr, "[audio] SetRenderCallback: %d\n", (int)err); goto fail; }

    if ((err = AudioUnitInitialize(au))) {
        fprintf(stderr, "[audio] AudioUnitInitialize: %d\n", (int)err);
        goto fail;
    }
    g_engine_au = au;
    fprintf(stderr, "[audio] engine ready: one RemoteIO, %u Hz stereo float32, "
                    "up to %d clients mixed\n", g_engine_rate, IOS_MAX_STREAMS);
    return 0;
fail:
    AudioComponentInstanceDispose(au);
    return -1;
}

/* Called with g_mix_lock held. */
/* App side (WineProcessBridge.m): puts the AVAudioSession in the Playback
 * category, activates it, and writes category/route/volume into the exported
 * log.  Re-asserted here because the unit can be started long after session
 * start, by which time another framework or an interruption may have changed
 * the session -- and a session that is not Playback is muted by the tablet's
 * Silent Mode with no error anywhere, while this engine happily renders. */
extern void madeira_audio_session_ensure(const char *why) __attribute__((weak));

static void ios_engine_start(void) {
    OSStatus err;
    if (!g_engine_au || g_engine_running) return;
    if (madeira_audio_session_ensure) madeira_audio_session_ensure("engine-start");
    if ((err = AudioOutputUnitStart(g_engine_au))) {
        fprintf(stderr, "[audio] AudioOutputUnitStart: %d -- null-mode\n", (int)err);
        AudioUnitUninitialize(g_engine_au);
        AudioComponentInstanceDispose(g_engine_au);
        g_engine_au = NULL;
        return;
    }
    g_engine_running = 1;
}

/* Stop the hardware once no client is playing.  Called with g_mix_lock held. */
static void ios_engine_stop_if_idle(void) {
    int i;
    if (!g_engine_au || !g_engine_running) return;
    for (i = 0; i < IOS_MAX_STREAMS; i++)
        if (g_streams[i] && g_streams[i]->valid && g_streams[i]->started) return;
    AudioOutputUnitStop(g_engine_au);
    g_engine_running = 0;
}

static void ios_engine_teardown(void) {
    if (!g_engine_au) return;
    if (g_engine_running) AudioOutputUnitStop(g_engine_au);
    AudioUnitUninitialize(g_engine_au);
    AudioComponentInstanceDispose(g_engine_au);
    g_engine_au = NULL;
    g_engine_running = 0;
}

/* The 10 s census.  Called from ordinary Wine threads only (get_current_padding
 * is the one entry point every active client hits at its device period), never
 * from the render callback.  One line per live stream, because "which of the
 * three clients is the broken one" is the first question every one of these
 * reports raises and the per-call counters cannot answer it. */
static void ios_report_streams(void) {
    static uint64_t last_mach;
    static const char *kind_name[] = { "u8", "s16", "s24", "s32", "f32" };
    uint64_t now = mach_absolute_time();
    int i, k = 0;

    if (last_mach && mach_to_ns(now - last_mach) < 10000000000ull) return;
    if (pthread_mutex_trylock(&g_mix_lock)) return;   /* next period will do */
    last_mach = now;
    for (i = 0; i < IOS_MAX_STREAMS; i++) {
        struct ios_stream *s = g_streams[i];
        uint32_t peak, gap_us, pad_min, pad_max, rate_hz;
        if (!s) continue;
        peak = atomic_load_explicit(&s->stat_peak_q16, memory_order_relaxed);
        atomic_store_explicit(&s->stat_peak_q16, 0, memory_order_relaxed);
        gap_us = atomic_load_explicit(&s->stat_max_gap_us, memory_order_relaxed);
        atomic_store_explicit(&s->stat_max_gap_us, 0, memory_order_relaxed);
        /* ml1100: pad_min is the latency floor for the window — a stable number
         * is a stable latency, a number that steps up and stays up is the
         * "slightly delayed ever after" the reports describe.  Both are reset
         * each window so the next one measures itself. */
        pad_min = atomic_exchange_explicit(&s->stat_pad_min, 0, memory_order_relaxed);
        pad_max = atomic_exchange_explicit(&s->stat_pad_max, 0, memory_order_relaxed);
        rate_hz = s->sample_rate ? s->sample_rate : 1;
        fprintf(stderr, "[audio] stream %d: fmt=%s/%uch/%uHz/%ubit(valid %u)/mask0x%x "
                        "ring=%ums frames_written=%llu underruns=%u peak=%u.%03u "
                        "event_signals=%u max_gap_ms=%u.%u pad_ms=%u..%u resyncs=%u %s\n",
                k, kind_name[s->kind], s->channels, s->sample_rate,
                s->frame_bytes && s->channels ? (s->frame_bytes / s->channels) * 8 : 0,
                s->valid_bits, s->channel_mask,
                s->sample_rate ? s->buffer_frames * 1000 / s->sample_rate : 0,
                (unsigned long long)atomic_load_explicit(&s->stat_frames_written,
                                                         memory_order_relaxed),
                atomic_load_explicit(&s->stat_underruns, memory_order_relaxed),
                peak >> 16, ((peak & 0xffff) * 1000) >> 16,
                atomic_load_explicit(&s->stat_event_signals, memory_order_relaxed),
                gap_us / 1000, (gap_us % 1000) / 100,
                pad_min * 1000u / rate_hz, pad_max * 1000u / rate_hz,
                atomic_load_explicit(&s->stat_resyncs, memory_order_relaxed),
                s->started ? "playing" : "stopped");
        atomic_store_explicit(&s->stat_event_signals, 0, memory_order_relaxed);
        k++;
    }
    if (k) {
        uint32_t g = atomic_load_explicit(&g_lim_min_gain_q16, memory_order_relaxed);
        atomic_store_explicit(&g_lim_min_gain_q16, 0, memory_order_relaxed);
        fprintf(stderr, "[audio] engine: %u Hz, %s, %d client(s), mix-lock misses=%u, "
                        "limiter_min_gain=%u.%03u (%u blocks limited)\n",
                g_engine_rate, g_engine_au ? (g_engine_running ? "running" : "idle")
                                           : "NULL (null-mode, no audible output)",
                k, atomic_load_explicit(&g_mix_lock_misses, memory_order_relaxed),
                g ? (g >> 16) : 1, g ? (((g & 0xffff) * 1000) >> 16) : 0,
                atomic_load_explicit(&g_lim_active, memory_order_relaxed));
        atomic_store_explicit(&g_lim_active, 0, memory_order_relaxed);
    }
    pthread_mutex_unlock(&g_mix_lock);
}

/* ---------------------------------------------------------------- */

/* MADEIRA (WOW64_DESIGN.md 3, invariants 1 and 2): render-buffer ownership.
 *
 * render_scratch is the ONE buffer this driver hands back to its client:
 * get_render_buffer returns it and the application writes its samples
 * straight into it (release_render_buffer then copies it into the ring).
 * Invariant 1 says any pointer guest code can observe is a guest address, so
 * for a 32-bit client that buffer MUST live inside that process's
 * [B, B+4G) window.  A calloc() pointer is ordinary host furniture far above
 * 4 GB: publishing it would truncate to an unrelated low address and the
 * first sample the game wrote would land somewhere random in the window.
 *
 * So when the calling process has a window, reserve the scratch with a GUEST
 * ceiling -- zero_bits = 1 gives limit 0x7fffffff, which virtual_ios.c's
 * ios_wow_translate_limits() turns into [B+floor, B+0x7fffffff] -- and refuse
 * loudly if the result somehow lands outside the window.  With no window
 * (every 64-bit caller) this is byte-for-byte the calloc() path that has
 * always been here.
 *
 * The ring and the AudioUnit are untouched: they are only ever read by the
 * unix side and the Core Audio RT thread, which speak host addresses.
 */
static BYTE *ios_audio_alloc_scratch(UINT32 frames, UINT32 frame_bytes,
                                     int *is_guest, UINT_PTR *alloc_bytes)
{
    void *addr = NULL;
    UINT_PTR size;
    NTSTATUS st;

    *is_guest = 0;
    *alloc_bytes = 0;
    if (!frames || !frame_bytes) return NULL;

    if (!ios_wow_base())
        return (BYTE *)calloc(frames, frame_bytes);

    size = (UINT_PTR)frames * frame_bytes;
    st = NtAllocateVirtualMemory(IOS_CURRENT_PROCESS, &addr, 1 /* zero_bits */, &size,
                                 IOS_MEM_COMMIT | IOS_MEM_RESERVE, IOS_PAGE_READWRITE);
    if (st || !addr || !ios_wow_in_window(addr)) {
        fprintf(stderr, "[ios_audio] WOW64 render scratch (%u frames x %u B) could not be "
                        "placed in the guest window (status 0x%x, addr %p) -- refusing, "
                        "rather than handing a host-only pointer to 32-bit code\n",
                frames, frame_bytes, (unsigned)st, addr);
        if (!st && addr) {
            UINT_PTR z = 0;
            NtFreeVirtualMemory(IOS_CURRENT_PROCESS, &addr, &z, IOS_MEM_RELEASE);
        }
        return NULL;
    }
    *is_guest = 1;
    *alloc_bytes = size;
    return (BYTE *)addr;
}

static void ios_audio_free_scratch(BYTE *scratch, int is_guest)
{
    if (!scratch) return;
    if (is_guest) {
        void *addr = scratch;
        UINT_PTR z = 0;
        NtFreeVirtualMemory(IOS_CURRENT_PROCESS, &addr, &z, IOS_MEM_RELEASE);
    }
    else free(scratch);
}

static NTSTATUS ios_process_attach(void *args) {
    LOG_FN_CALL(0, "process_attach");
    (void)args;
    pthread_mutex_init(&g_streams_lock, NULL);
    pthread_mutex_init(&g_mix_lock, NULL);
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
        /* The engine goes first and under the same lock the render callback
         * uses, so no pass can be in flight over the registry we are about to
         * empty. */
        pthread_mutex_lock(&g_mix_lock);
        ios_engine_teardown();
        for (i = 0; i < IOS_MAX_STREAMS; i++) {
            struct ios_stream *s = g_streams[i];
            g_streams[i] = NULL;
            if (!s) continue;
            /* Mark dead, but do NOT free. release_stream joins a stream's own
             * timer thread before freeing it; here we have no handle to join,
             * and freeing while that thread may still be looping is a
             * use-after-free. The process is going away, so leaving the memory
             * is the safe trade. */
            s->valid = 0;
            s->started = 0;
        }
        pthread_mutex_unlock(&g_mix_lock);
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
    struct ios_stream *s;

    /* Refuse exactly what is_format_supported refuses, and nothing more.  The
     * two answers have to agree: a caller that was told a format is fine and
     * then gets a stream which silently plays nothing has no way to recover,
     * whereas AUDCLNT_E_UNSUPPORTED_FORMAT sends it back to GetMixFormat.
     * This is NOT the null-mode fallback below -- that one is for the unit
     * failing to build (no audio session yet, device busy), where the format
     * is fine and only the environment is not, and where silent-but-ticking
     * keeps a game's timing alive. */
    if (!ios_fmt_openable(p->fmt)) {
        p->result = AUDCLNT_E_UNSUPPORTED_FORMAT;
        ios_log_fmt("create_stream", p->fmt, p->share, p->result);
        return STATUS_SUCCESS;
    }

    /* ml739: a stream per client. */
    s = calloc(1, sizeof(*s));
    if (!s) {
        p->result = E_OUTOFMEMORY;
        ios_log_fmt("create_stream", p->fmt, p->share, p->result);
        return STATUS_SUCCESS;
    }
    s->valid = 1;
    s->started = 0;
    s->start_mach = 0;
    s->accumulated_frames = 0;
    s->sample_rate = p->fmt && p->fmt->nSamplesPerSec ? p->fmt->nSamplesPerSec : IOS_AUDIO_SAMPLE_RATE;
    s->channels = p->fmt && p->fmt->nChannels ? p->fmt->nChannels : IOS_AUDIO_CHANNELS;
    s->frame_bytes = p->fmt && p->fmt->nBlockAlign ? p->fmt->nBlockAlign
                          : (s->channels * IOS_AUDIO_BITS) / 8;
    s->kind = ios_fmt_kind(p->fmt);
    s->valid_bits = ios_fmt_valid_bits(p->fmt);
    s->channel_mask = ios_fmt_channel_mask(p->fmt);
    ios_build_mix_gains(s, s->channel_mask);
    /* Ring capacity: the requested buffer duration (100ns units), floor 200 ms.
     *
     * The floor is what lets a game thread stall without it being audible.
     * Under FEX translation a 60-80 ms stall -- a shader compile, a level
     * chunk loading, the JIT meeting new code -- is ordinary, and at the old
     * 100 ms floor a client that keeps only one period of headroom has
     * nothing left after one of those.  This changes how much the client is
     * ALLOWED to queue, not the latency the endpoint reports: get_latency and
     * get_device_period still describe the engine's 10 ms period, which is
     * what they are supposed to describe. */
    dur_frames = (uint64_t)(p->duration > 0 ? p->duration : 0) * s->sample_rate / 10000000ull;
    if (dur_frames < s->sample_rate / 5) dur_frames = s->sample_rate / 5;
    if (dur_frames > s->sample_rate * 4) dur_frames = s->sample_rate * 4;
    s->buffer_frames = (UINT32)dur_frames;
    /* The ring is the ENGINE's shape (stereo float32), not the client's: two
     * floats per client frame however many channels and whatever sample type
     * the client writes.  Sizing it off the client's frame_bytes is what made
     * a 24-byte 5.1 frame and an 8-byte stereo frame index the same buffer
     * differently. */
    s->ring = (float *)calloc((size_t)s->buffer_frames * 2, sizeof(float));
    /* MADEIRA: guest-visible for a WoW client, plain calloc otherwise.  The
     * scratch IS in the client's format -- it is the buffer the game writes
     * its own samples into. */
    s->render_scratch = ios_audio_alloc_scratch(s->buffer_frames, s->frame_bytes,
                                                &s->scratch_guest, &s->scratch_bytes);
    s->scratch_frames = s->render_scratch ? s->buffer_frames : 0;
    s->pending_frames = 0;
    atomic_store(&s->write_pos, 0);
    atomic_store(&s->play_pos, 0);
    atomic_store(&s->stat_frames_written, 0);
    atomic_store(&s->stat_underruns, 0);
    atomic_store(&s->stat_peak_q16, 0);

    pthread_mutex_lock(&g_mix_lock);
    if (p->flow == eRender && s->ring)
        ios_engine_ensure();               /* failure -> null-mode */
    s->resample_step = ios_resample_step(s->sample_rate);
    s->resample_frac = 0;
    pthread_mutex_unlock(&g_mix_lock);

    if (p->channel_count) *p->channel_count = s->channels;
    if (p->stream) *p->stream = (stream_handle)(uintptr_t)s;
    fprintf(stderr, "[ios-astream] ml738 CREATED gen=%u handle=%p rate=%u ch=%u fb=%u "
                    "asked=%ums ring=%ums flags=0x%x "
                    "mask=0x%x downmix L=[%.2f %.2f %.2f %.2f %.2f %.2f] "
                    "R=[%.2f %.2f %.2f %.2f %.2f %.2f] step=0x%x\n",
            g_stream_gen, (void *)s, s->sample_rate, s->channels, s->frame_bytes,
            (unsigned)(p->duration > 0 ? p->duration / 10000 : 0),
            s->sample_rate ? s->buffer_frames * 1000 / s->sample_rate : 0,
            (unsigned)p->flags,
            s->channel_mask,
            s->mix_gain[0][0], s->mix_gain[1][0], s->mix_gain[2][0],
            s->mix_gain[3][0], s->mix_gain[4][0], s->mix_gain[5][0],
            s->mix_gain[0][1], s->mix_gain[1][1], s->mix_gain[2][1],
            s->mix_gain[3][1], s->mix_gain[4][1], s->mix_gain[5][1],
            s->resample_step);
    if (stream_register(s)) {
        fprintf(stderr, "[ios-astream] ml739 too many streams -- refusing\n");
        ios_audio_free_scratch(s->render_scratch, s->scratch_guest);
        free(s->ring); free(s);
        /* the handle was published above; it now points at freed memory */
        if (p->stream) *p->stream = 0;
        p->result = E_OUTOFMEMORY;
        ios_log_fmt("create_stream", p->fmt, p->share, p->result);
        return STATUS_SUCCESS;
    }
    p->result = S_OK;
    ios_log_fmt("create_stream", p->fmt, p->share, p->result);
    return STATUS_SUCCESS;
}

static NTSTATUS ios_release_stream(void *args) {
    struct release_stream_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);

    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }

    /* Order matters. Mark this stream dead first so its own timer thread
     * leaves its loop and the mixer stops picking it up, join that thread, and
     * only then unregister -- which takes the render callback's own lock, so
     * no pass can still be reading this stream's ring when we free it below.
     * Nothing here touches another client's stream, and the engine keeps
     * running for them (it stops itself once none are playing). */
    s->valid = 0;
    s->started = 0;
    if (p->timer_thread) {
        NtWaitForSingleObject(p->timer_thread, FALSE, NULL);
        NtClose(p->timer_thread);
    }
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
    /* Under the mixer's lock: `started` is what the render callback reads to
     * decide whether to pull from this stream, and the engine must be running
     * before it can. */
    pthread_mutex_lock(&g_mix_lock);
    if (!s->started) {
        ios_engine_ensure();
        /* Recomputed here, not only at create_stream: a stream created while
         * the engine did not yet exist got its step from the default rate, and
         * the engine may have since come up on a route running at another. */
        s->resample_step = ios_resample_step(s->sample_rate);
        ios_engine_start();
        s->start_mach = mach_absolute_time();
        s->started = 1;
    }
    pthread_mutex_unlock(&g_mix_lock);
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_stop(void *args) {
    struct stream_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    pthread_mutex_lock(&g_mix_lock);
    if (s->started) {
        s->accumulated_frames = elapsed_frames(s);
        s->started = 0;
        /* The hardware only stops when the LAST client stops; the others are
         * still playing through the same unit. */
        ios_engine_stop_if_idle();
    }
    pthread_mutex_unlock(&g_mix_lock);
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_reset(void *args) {
    struct stream_handle_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    pthread_mutex_lock(&g_mix_lock);
    s->started = 0;
    s->accumulated_frames = 0;
    s->start_mach = 0;
    /* Drop queued-but-unplayed audio (only legal while stopped).  The
     * resampler's sub-frame position is part of that state: leaving it set
     * would make the first frame after the reset interpolate against the
     * stale one. */
    atomic_store(&s->write_pos, 0);
    atomic_store(&s->play_pos, 0);
    s->resample_frac = 0;
    s->pending_frames = 0;
    ios_engine_stop_if_idle();
    pthread_mutex_unlock(&g_mix_lock);
    p->result = S_OK;
    return STATUS_SUCCESS;
}

/* The client's period event, driven by the HARDWARE CLOCK.
 *
 * This used to be `usleep(10000); NtSetEvent();` -- a free-running wall-clock
 * timer, which is a clock SOURCE.  On a loaded device, with the game's mixer
 * thread running under FEX translation, a 10 ms sleep is 10 ms plus whatever
 * the scheduler adds, so the wakeups drift against the audio device and then
 * bunch when the backlog clears: the client mixes nothing for a while and then
 * mixes several periods at once.  The ring never runs dry -- the device log
 * showed one or two underruns in a whole session -- and it still stutters,
 * because what a game hears is the RATE its buffers are consumed at, not
 * whether the mixer starved.
 *
 * So this thread is now a clock FOLLOWER: it signals when the engine has
 * actually consumed another period's worth of frames, and it sleeps for
 * roughly as long as the remaining frames will take.  A late wakeup signals
 * immediately and the next target is computed from the clock, so lateness
 * never accumulates.  NtSetEvent stays on this Wine thread and is never called
 * from the Core Audio render thread, which must not enter Wine at all.
 *
 * With no engine -- null-mode -- it falls back to the old wall-clock tick,
 * which is the only clock there is in that case. */
static NTSTATUS ios_timer_loop(void *args) {
    struct timer_loop_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    uint64_t next = 0, last_signal = 0;
    if (!s) return STATUS_SUCCESS;
    LOG_FN_CALL(9, "timer_loop");
    /* ml1100: resolve the resync knob HERE, on a Wine thread, so the Core Audio
     * render thread never reaches a getenv on its first callback. */
    ios_audio_resync_on();
    while (s->valid) {
        UINT32 rate = s->sample_rate ? s->sample_rate : IOS_AUDIO_SAMPLE_RATE;
        UINT32 period = rate / 100;            /* 10 ms in client frames */
        int signal_now = 0;
        if (!period) period = 1;

        if (g_engine_au && g_engine_running && s->started) {
            uint64_t play = atomic_load_explicit(&s->play_pos, memory_order_acquire);
            /* A reset rewinds play_pos; resync rather than wait forever. */
            if (next > play + 4ull * period) next = play;
            if (play >= next) {
                /* ml1100: ADVANCE BY ONE PERIOD, DO NOT SNAP TO `play'.
                 *
                 * `next = play + period' threw away however far play_pos had
                 * already run past the target, and play_pos does not advance
                 * smoothly -- it advances in whole Core Audio callbacks. With a
                 * 1024-frame device buffer it jumps 21.3 ms at a time, so this
                 * loop could only ever observe ONE crossing per callback and
                 * emitted ONE signal for TWO elapsed 10 ms periods. The device
                 * census says exactly that: event_signals=470 per ten seconds
                 * (47/s, one per callback) where a 10 ms period wants ~100/s,
                 * frames_written/event_signals = 1021 frames = 21.3 ms per
                 * wakeup, and max_gap_ms pinned at 22.6 -- the client's period
                 * was silently the DEVICE's buffer, not the 10 ms this driver
                 * advertises through get_device_period.
                 *
                 * Keeping the phase makes the next iteration find the second
                 * crossing immediately and signal again, so a client that mixes
                 * on its period event is woken at the rate it was promised and
                 * has two periods of margin instead of one. */
                next += period;
                /* ... but never bank an unbounded debt: if this loop was itself
                 * descheduled for a long time, catch up rather than emit a burst
                 * of signals for periods nobody can still use. */
                if (play >= next + 4ull * period) next = play + period;
                signal_now = 1;
            }
            /* LIVENESS.  play_pos stops advancing the moment the ring is
             * empty, and the thing that refills the ring is the event this
             * loop sends -- so pacing purely off the clock would let one
             * underrun wedge the client into permanent silence.  Two periods
             * of wall time with no signal is the backstop, and it also covers
             * the moment before the first frame is ever played. */
            if (!signal_now && last_signal &&
                mach_to_ns(mach_absolute_time() - last_signal) > 20000000ull) {
                next = play + period;
                signal_now = 1;
            }
            if (signal_now) {
                if (s->event) {
                    NtSetEvent(s->event, NULL);
                    atomic_fetch_add_explicit(&s->stat_event_signals, 1,
                                              memory_order_relaxed);
                }
                last_signal = mach_absolute_time();
                usleep(500);
            } else {
                /* Sleep for about as long as the frames still queued will
                 * take.  A late wakeup signals at once and recomputes the
                 * target from the clock, so lateness never accumulates. */
                uint64_t us = (next - play) * 1000000ull / rate;
                if (us < 500) us = 500;
                if (us > 10000) us = 10000;
                usleep((useconds_t)us);
            }
        } else {
            usleep(10000); /* null-mode / stopped: wall clock is all there is */
            next = atomic_load_explicit(&s->play_pos, memory_order_acquire);
            if (s->event && s->started) {
                NtSetEvent(s->event, NULL);
                atomic_fetch_add_explicit(&s->stat_event_signals, 1,
                                          memory_order_relaxed);
                last_signal = mach_absolute_time();
            }
        }
    }
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_render_buffer(void *args) {
    LOG_FN_CALL(10, "get_render_buffer");
    struct get_render_buffer_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->data) *p->data = NULL; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (g_engine_au) {
        uint64_t padding = atomic_load(&s->write_pos) - atomic_load(&s->play_pos);
        if (p->frames + padding > s->buffer_frames) {
            p->result = AUDCLNT_E_BUFFER_TOO_LARGE;
            if (p->data) *p->data = NULL;
            return STATUS_SUCCESS;
        }
    }
    if (p->frames > s->scratch_frames) {
        /* Client asked for more than the ring — grow scratch; the copy in
         * release clamps to ring capacity anyway.
         *
         * MADEIRA: this used to be a realloc().  A WoW client's scratch is a
         * guest-window reservation, not heap, so the grow is allocate-then-
         * free — new first, so an allocation failure leaves the old buffer
         * intact exactly as realloc() did.  Nothing written into the scratch
         * before this point is live (the client has not called GetBuffer
         * yet), so not preserving the contents is not observable. */
        int guest = 0;
        UINT_PTR bytes = 0;
        BYTE *ns = ios_audio_alloc_scratch(p->frames, s->frame_bytes, &guest, &bytes);
        if (!ns) { if (p->data) *p->data = NULL; p->result = E_FAIL; return STATUS_SUCCESS; }
        ios_audio_free_scratch(s->render_scratch, s->scratch_guest);
        s->render_scratch = ns;
        s->scratch_guest = guest;
        s->scratch_bytes = bytes;
        s->scratch_frames = p->frames;
    }
    if (!s->render_scratch) { if (p->data) *p->data = NULL; p->result = E_FAIL; return STATUS_SUCCESS; }
    s->pending_frames = p->frames;
    if (p->data) *p->data = s->render_scratch;
    p->result = S_OK;
    return STATUS_SUCCESS;
}

/* Convert and downmix the frames the client just wrote into the stream's
 * stereo-float ring.  This runs on the GAME's thread, not the render thread:
 * the per-sample work (decode, N-channel fold-down, peak) belongs where a
 * long buffer costs the game and not the audio device.  What the render
 * thread is left with is a resample and an add. */
static void ios_ingest_frames(struct ios_stream *s, UINT32 n, uint64_t wr, int silent)
{
    UINT32 cap = s->buffer_frames;
    UINT32 ch = s->channels > 8 ? 8 : s->channels;
    UINT32 i, c;
    float peak = 0.0f;

    for (i = 0; i < n; i++) {
        size_t o = (size_t)((wr + i) % cap) * 2;
        float l = 0.0f, r = 0.0f;
        if (!silent) {
            const BYTE *frame = s->render_scratch + (size_t)i * s->frame_bytes;
            for (c = 0; c < ch; c++) {
                float v = ios_sample_to_float(s->kind, frame, c);
                l += v * s->mix_gain[c][0];
                r += v * s->mix_gain[c][1];
            }
        }
        s->ring[o] = l;
        s->ring[o + 1] = r;
        if (l > peak) peak = l; else if (-l > peak) peak = -l;
        if (r > peak) peak = r; else if (-r > peak) peak = -r;
    }

    if (peak > 0.0f) {
        uint32_t q = peak >= 16.0f ? 0xffffffffu : (uint32_t)(peak * 65536.0f);
        uint32_t old = atomic_load_explicit(&s->stat_peak_q16, memory_order_relaxed);
        while (q > old &&
               !atomic_compare_exchange_weak_explicit(&s->stat_peak_q16, &old, q,
                                                      memory_order_relaxed,
                                                      memory_order_relaxed))
            ;
    }
}

static NTSTATUS ios_release_render_buffer(void *args) {
    struct release_render_buffer_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    /* How long the client left us waiting since its last submission.  With
     * underruns at zero this is the number that separates "the game thread
     * stalled" from "we failed to drain the ring": a gap far above the device
     * period, with no underrun, means the client bunched its work. */
    {
        uint64_t now = mach_absolute_time();
        if (s->last_release_mach) {
            uint32_t gap_us = (uint32_t)(mach_to_ns(now - s->last_release_mach) / 1000);
            uint32_t old = atomic_load_explicit(&s->stat_max_gap_us, memory_order_relaxed);
            while (gap_us > old &&
                   !atomic_compare_exchange_weak_explicit(&s->stat_max_gap_us, &old, gap_us,
                                                          memory_order_relaxed,
                                                          memory_order_relaxed))
                ;
        }
        s->last_release_mach = now;
    }
    if (s->ring && p->written_frames > 0) {
        UINT32 cap = s->buffer_frames;
        UINT32 n = p->written_frames;
        uint64_t wr = atomic_load_explicit(&s->write_pos, memory_order_relaxed);
        if (n > s->pending_frames) n = s->pending_frames;
        if (n > cap) n = cap;
        /* AUDCLNT_BUFFERFLAGS_SILENT means "ignore what is in the buffer",
         * not "the buffer contains zeroes" -- the client is allowed to leave
         * whatever it likes there.  Writing silence straight into the ring is
         * both correct and cheaper than zeroing the scratch first. */
        ios_ingest_frames(s, n, wr, (p->flags & 0x2) != 0);
        /* release-store AFTER the conversion so the render thread never reads
         * frames that aren't fully written */
        atomic_store_explicit(&s->write_pos, wr + n, memory_order_release);
        atomic_fetch_add_explicit(&s->stat_frames_written, n, memory_order_relaxed);
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
    if (!ios_fmt_openable(p->fmt_in)) {
        p->result = S_FALSE;
    }
    else if (p->share == 0 /* AUDCLNT_SHAREMODE_SHARED */ &&
             p->fmt_in->nChannels > 2) {
        /* The endpoint is stereo.  Answering "yes, 5.1 is fine" is what a
         * multichannel-capable card says, and a client that hears it builds a
         * multichannel graph: the device log showed a title open a 5.1 stream
         * alongside its stereo one, feed the 5.1 one 48000 frames a second of
         * pure silence for the whole session, and put everything it actually
         * played through the stereo one at +18 dB.  A real stereo endpoint
         * answers S_FALSE here and hands back its own mix format as the
         * closest match, which is exactly what mmdevapi's client.c does with
         * this return -- so the client builds the stereo graph that matches
         * the hardware.
         *
         * create_stream still ACCEPTS more channels (and downmixes them), for
         * callers that ignore the advice or never ask. */
        p->result = S_FALSE;
        if (ios_outcome_is_new(0x5ce0a000u ^ p->fmt_in->nChannels))
            fprintf(stderr, "[audio] is_format_supported %uch shared -> S_FALSE "
                            "(stereo endpoint; closest match is the mix format). "
                            "create_stream still accepts it and downmixes.\n",
                    p->fmt_in->nChannels);
    }
    else p->result = S_OK;
    ios_log_fmt("is_format_supported", p->fmt_in, p->share, p->result);
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_loopback_capture_device(void *args) {
    struct get_loopback_capture_device_params *p = args;
    /* This driver exposes no capture endpoint at all (get_endpoint_ids
     * refuses eCapture), so loopback capture cannot work.  Say so: this used
     * to return STATUS_SUCCESS and leave `result` untouched, which is an
     * uninitialised HRESULT for the caller — harmless only because mmdevapi
     * never reaches this call without a capture endpoint. */
    if (p) p->result = (HRESULT)E_NOTIMPL;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_mix_format(void *args) {
    struct get_mix_format_params *p = args;
    LOG_FN_CALL(16, "get_mix_format");
    /* The mix format is the ENGINE's format, and the engine is a stereo
     * float32 mixer -- so that is what this reports.  It used to report
     * 16-bit PCM, which is not what the engine mixes in and not what a WASAPI
     * consumer expects from a shared-mode endpoint: every modern client
     * (XAudio2, FAudio, dsound's own resampler) takes the mix format as the
     * format it should hand over to avoid a conversion, and being told 16-bit
     * while the device actually wants float meant a conversion on every path
     * with nothing checking that the two agreed.
     *
     * The rate is the hardware's, learned when the engine was built, so a
     * client that follows the mix format needs no resampling from us at all.
     *
     * WAVEFORMATEXTENSIBLE is 40 bytes; the first 18 are WAVEFORMATEX. */
    if (p->fmt) {
        UINT32 rate = g_engine_rate ? g_engine_rate : IOS_AUDIO_SAMPLE_RATE;
        memset(p->fmt, 0, 40);
        struct WAVEFORMATEX_stub *f = p->fmt;
        f->wFormatTag = 0xFFFE; /* WAVE_FORMAT_EXTENSIBLE */
        f->nChannels = 2;
        f->nSamplesPerSec = rate;
        f->wBitsPerSample = 32;
        f->nBlockAlign = 2 * 4;
        f->nAvgBytesPerSec = rate * (2 * 4);
        f->cbSize = 22; /* extensible body */
        /* Extensible body: Samples (2), ChannelMask (4), SubFormat (16).
         * KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = {00000003-0000-0010-8000-00AA00389B71} */
        uint16_t *samples = (uint16_t *)((char *)p->fmt + 18);
        *samples = 32;
        uint32_t *mask = (uint32_t *)((char *)p->fmt + 20);
        *mask = IOS_SPK_FRONT_LEFT | IOS_SPK_FRONT_RIGHT;
        static const uint8_t float_guid[16] = {
            0x03,0x00,0x00,0x00, 0x00,0x00, 0x10,0x00,
            0x80,0x00, 0x00,0xAA, 0x00,0x38,0x9B,0x71
        };
        memcpy((char *)p->fmt + 24, float_guid, 16);
    }
    p->result = S_OK;
    ios_log_fmt("get_mix_format", p->fmt, 0, p->result);
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_device_period(void *args) {
    struct get_device_period_params *p = args;
    if (p->def_period) *p->def_period = 100000; /* 10 ms in 100ns units */
    if (p->min_period) *p->min_period = 50000;  /* 5 ms */
    p->result = S_OK;
    if (ios_outcome_is_new(0x6ea10d00u ^ (uint32_t)p->flow))
        fprintf(stderr, "[audio] get_device_period flow=%d -> def=10ms min=5ms 0x%08x\n",
                p->flow, (unsigned)p->result);
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
    /* The ENGINE's period, matching get_device_period's default, and
     * deliberately not the ring depth: latency is how long a frame waits
     * between the mixer taking it and the speaker, which is one engine
     * period.  How much the client is allowed to queue ahead of that is
     * get_buffer_size's business, and the two were conflated once already. */
    if (p->latency) *p->latency = 100000; /* 10 ms in 100ns units */
    p->result = S_OK;
    return STATUS_SUCCESS;
}

static NTSTATUS ios_get_current_padding(void *args) {
    LOG_FN_CALL(20, "get_current_padding");
    struct get_current_padding_params *p = args;
    struct ios_stream *s = stream_from_handle(p->stream);
    if (!s) { if (p->padding) *p->padding = 0; p->result = AUDCLNT_E_NOT_INITIALIZED; return STATUS_SUCCESS; }
    if (p->padding) {
        if (g_engine_au) {
            uint64_t pad = atomic_load(&s->write_pos) - atomic_load(&s->play_pos);
            *p->padding = (UINT32)(pad > s->buffer_frames ? s->buffer_frames : pad);
        } else {
            *p->padding = 0; /* null-mode: always hungry */
        }
    }
    p->result = S_OK;
    /* Every active client hits this at its device period, which makes it the
     * one place a periodic census can live without a thread of its own. */
    ios_report_streams();
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
    /* THIS is the function that drives a game engine's audio clock. Tier-2:
     * client frames the mixer actually consumed — the true hardware clock,
     * still counted in the CLIENT's frames even when the engine runs at a
     * different rate, because that is the unit get_frequency reports. Null-mode
     * fallback: wall-clock synthesis as before. */
    if (p->pos) {
        if (g_engine_au)
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
    if (p->rate > 0) {
        pthread_mutex_lock(&g_mix_lock);
        s->sample_rate = (UINT32)p->rate;
        /* The resampler's step is derived from this rate, so changing one
         * without the other silently plays the stream at the wrong speed --
         * which is what this call exists to avoid. */
        s->resample_step = ios_resample_step(s->sample_rate);
        pthread_mutex_unlock(&g_mix_lock);
    }
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
 * *quit turns that loop into a spin: in the reference trace the thread
 * "mmdevapi_midi_notify" held 96.7 % of a core for the whole session inside
 * the 31-byte guest loop at mmdevapi.dll+0xca4c, with the movie it was meant
 * to be playing stalled behind it.
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
    if (p && p->err) *p->err = IOS_DRV_FAILURE;
    if (ios_outcome_is_new(0x3d1d1000u))
        fprintf(stderr, "[audio] midi_init -> DRV_FAILURE (no MIDI backend on this "
                        "port; mmdevapi will not start its notify thread)\n");
    return STATUS_SUCCESS;
}

static NTSTATUS ios_midi_notify_wait(void *args) {
    struct ios_midi_notify_wait_params *p = args;
    if (p) {
        if (p->quit) *p->quit = 1;
        ios_midi_clear_notify(p->notify);
    }
    if (ios_outcome_is_new(0x3d1d2000u))
        fprintf(stderr, "[audio] midi_notify_wait -> quit=TRUE (there is nothing to "
                        "wait for; returning without this is a busy loop)\n");
    return STATUS_SUCCESS;
}

static NTSTATUS ios_midi_message(void *args) {
    struct ios_midi_message_params *p = args;
    if (p) {
        if (p->err) *p->err = IOS_MMSYSERR_NOTSUPPORTED;
        ios_midi_clear_notify(p->notify);
    }
    if (ios_outcome_is_new(0x3d1d3000u ^ (p ? p->msg : 0)))
        fprintf(stderr, "[audio] midi message msg=%u -> MMSYSERR_NOTSUPPORTED\n",
                p ? p->msg : 0);
    return STATUS_SUCCESS;
}

static NTSTATUS ios_aux_message(void *args) {
    struct ios_aux_message_params *p = args;
    if (p && p->err) *p->err = IOS_MMSYSERR_NOTSUPPORTED;
    if (ios_outcome_is_new(0x3d1d4000u ^ (p ? p->msg : 0)))
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

/* ================= MADEIRA: the 32-bit (WoW64) table =================
 *
 * WOW64_DESIGN.md 2/3 (invariant 2) and 7.10 item 1.  A 32-bit mmdevapi.dll
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
    /* WOW64_DESIGN.md 3 invariant 1: the client writes its samples straight
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

static NTSTATUS ios_wow64_get_loopback_capture_device(void *args)
{
    struct {
        PTR32 name;
        PTR32 device;
        PTR32 ret_device;
        UINT32 ret_device_len;
        HRESULT result;
    } *params32 = args;
    char *ret_device = ios_wow_host_ptr(params32->ret_device);
    struct get_loopback_capture_device_params params = {
        .name = ios_wow_host_ptr(params32->name),
        .device = ios_wow_host_ptr(params32->device),
        .ret_device = ret_device,
        .ret_device_len = params32->ret_device_len,
    };
    NTSTATUS status = ios_get_loopback_capture_device(&params);
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
    ios_wow64_get_loopback_capture_device, /* get_loopback_capture_device */
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
