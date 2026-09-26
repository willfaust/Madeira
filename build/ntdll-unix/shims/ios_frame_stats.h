/*
 * iOS-Madeira ml1050: the frame critical-path breakdown.
 *
 * ONE compact `[frame]` line every ten seconds, default ON, from the same
 * heartbeat that already prints `[perf]` (build/ntdll-unix/server_ios.c,
 * ios_perf_line()).  MADEIRA_FRAME_STATS=0 turns it off.
 *
 * WHY THIS EXISTS.  Every log this port has ever taken can say how much CPU
 * was burned and where, but not what BOUNDS a frame.  The kprev5 gameplay
 * capture is the clearest possible statement of the problem: `[prof]` reports
 * busy=1.37 cores on a six-core device with wait=97.5%, the presenting thread
 * at 18.7% of that (~0.26 core, i.e. ~9ms of CPU in a ~35ms frame) and the
 * encode thread at 11.7% (~5ms).  Nothing is saturated, so fps is set by
 * whatever the frame is WAITING on -- and no counter in the image could name
 * it.  "25-30 fps" is consistent with a 20ms pipeline quantised to a 16.67ms
 * display grid, with a GPU that takes 30ms, and with a chain of wake-ups that
 * each arrive a millisecond late.  Those want opposite fixes and the log could
 * not tell them apart.
 *
 * WHAT IT COSTS. Two clock reads per presenting frame and encode interval,
 * relaxed counter adds, and a Metal completion handler per command buffer.
 * The presenter clock hook uses trylock and drops contended samples rather
 * than blocking. Native encoder counts inspect attachment actions only while
 * statistics are enabled. MADEIRA_FRAME_STATS=0 bypasses these diagnostics.
 *
 * WHAT IT CANNOT SEE, stated so the line is not over-read.  The producers live
 * on the two sides that can actually observe the events: the winemetal unix
 * thunks (drawable acquire, present, GPU timestamps -- research/dxmt/src/
 * winemetal/unix/winemetal_unix.c) and ntdll's unix side (the waits --
 * wine/dlls/ntdll/unix/sync.c, build/ntdll-unix/server_ios.c).  DXMT's own
 * PE-side handoffs (game waits for a free chunk, game waits for the frame
 * latency fence) are emulated i386 code and are NOT separately attributable
 * here; they appear inside the game thread's wait buckets, because every one
 * of them bottoms out in an ntdll wait.  `other=` is exactly that remainder.
 *
 * ROLES.  A thread claims a role the first time it reaches the hook that
 * DEFINES that role. Since ml1140 GAME follows presenter ownership changes
 * with fresh clock baselines; MADEIRA_FRAME_FOLLOW=0 restores initial pinning:
 *   GAME    -- the thread that calls WMTQueryDisplaySettingForLayer, which
 *              Presenter::synchronizeLayerProperties() issues exactly once per
 *              Present on the calling thread (dxmt_presenter.cpp:119, reached
 *              from the d3d9 swapchain's Present).  This is the frame boundary
 *              and it is the only per-frame native call the presenting thread
 *              makes, so it costs nothing to hook.
 *   ENCODE  -- the thread that calls MetalLayer_nextDrawable / presentDrawable,
 *              which is DXMT's encode thread by construction (the present
 *              chunk is encoded there).
 * GPU timestamps and queue retirement are collected in Metal completion
 * handlers, including buffers that completed before the finish thread waits.
 * They are not attributed to a CPU thread role.
 *
 * Every counter is a relaxed add and is exchanged to zero when the window is
 * read, exactly like ios_srv_nt_counts: these are rates, not ledgers, and a
 * lost increment costs fidelity, never correctness.
 */

#ifndef __IOS_FRAME_STATS_H
#define __IOS_FRAME_STATS_H

#include <pthread.h>

enum ios_frame_role
{
    IOS_FRAME_ROLE_GAME = 0,
    IOS_FRAME_ROLE_ENCODE,
    IOS_FRAME_ROLE_FINISH,
    IOS_FRAME_ROLE_MAX
};

/* Causes charged to the PRESENTING thread's blocked time.  The sum of these
 * is always <= (wall - cpu); the difference is printed as `other'. */
enum ios_frame_wait
{
    IOS_FRAME_WAIT_FAST = 0,   /* madeira_fast_wait: spin + in-process park  */
    IOS_FRAME_WAIT_SRV,        /* server_wait: a wineserver round trip       */
    IOS_FRAME_WAIT_SLEEP,      /* NtDelayExecution with a real timeout       */
    IOS_FRAME_WAIT_UNIX,       /* inside a winemetal unix call (Metal work)  */
    IOS_FRAME_WAIT_PRESENT,    /* inside the per-frame present unix call     */
    IOS_FRAME_WAIT_LIMITER,    /* the present limiter's own precise sleep    */
    IOS_FRAME_WAIT_MAX
};

/* 1ms buckets, 0..62ms, [63] = everything slower.  Linear rather than log2
 * because the question is "did this frame miss a 16.67 or an 8.33ms vblank",
 * and a factor-of-two bucket cannot answer that. */
#define IOS_FRAME_HIST_N 4096 /* ml1150: don't clip every long frame to 64ms */

extern int ios_frame_stats_on;                                  /* MADEIRA_FRAME_STATS */
extern unsigned long long ios_frame_role_tid[IOS_FRAME_ROLE_MAX];

/* THE ONE HOT-PATH PREDICATE.  pthread_self() on arm64 is a TPIDRRO_EL0 read
 * and a mask -- no call into the kernel, no TLS section, so this is safe on a
 * FEX-created thread (see the project rule about implicit TLS).  The role
 * table is written once per role for the life of the process; a relaxed read
 * of a stale zero simply declines to account one wait. */
static inline int ios_frame_is_role( enum ios_frame_role role )
{
    if (!ios_frame_stats_on) return 0;
    return (unsigned long long)(uintptr_t)pthread_self()
           == __atomic_load_n( &ios_frame_role_tid[role], __ATOMIC_RELAXED );
}

static inline int ios_frame_tracking( void )
{
    return ios_frame_is_role( IOS_FRAME_ROLE_GAME );
}

/* Producers.  All are no-ops when the instrument is off. */

/* Presenting thread, once per Present.  Closes the previous frame: wall delta,
 * this thread's CPU delta, and the wait buckets accumulated since the last
 * call.  Claims IOS_FRAME_ROLE_GAME on first use. */
void ios_frame_game_tick( void );

/* Encode thread.  `skipped' is the RAW-mode mailbox drop (nil drawable), which
 * still ends a game frame but puts nothing on glass. */
void ios_frame_encode_present( int skipped );

/* Encode thread: nanoseconds inside CAMetalLayer.nextDrawable.  This is the
 * number that says whether the producer is being held by the display. */
void ios_frame_drawable_wait( unsigned long long ns );

/* Finish thread: one retired command buffer.  `gpu_ns' is
 * GPUEndTime-GPUStartTime (0 when Metal did not report them); `inflight' is
 * commits-minus-completions at the moment it retired, i.e. the real queue
 * depth. */
void ios_frame_gpu( unsigned long long gpu_ns, unsigned long long inflight );

/* Any thread; filters on the GAME role internally so a caller may invoke it
 * unconditionally.  Callers that would have to READ A CLOCK to produce `ns'
 * should gate on ios_frame_tracking() first -- that is the whole reason the
 * predicate is inline and public. */
void ios_frame_wait_add( enum ios_frame_wait kind, unsigned long long ns );

/* ml1100: the presenting thread's server waits, attributed.  Called from the one
 * site that already times them; `tclass' is 0 infinite / 1 finite / 2 poll.  The
 * top three by time become the `[frame]   srv-sites:' line. */
void ios_frame_srv_site( const void *pc, unsigned int handle, unsigned int nobj,
                         unsigned char tclass, unsigned long long ns, int timed_out );

/* Published from Swift through winemetal (only UIKit knows them) and from the
 * present thunk.  panel_hz = the display's maximum refresh; intent_hz = the
 * rate a CADisplayLink is currently asking for (0 = nothing armed); mode = the
 * live g_madeira_vsync_mode. */
void ios_frame_note_display( int panel_hz, int intent_hz, int mode );

/* Called from ios_perf_line() once per heartbeat window. */
void ios_frame_report( unsigned long long win_ns );

#endif /* __IOS_FRAME_STATS_H */
