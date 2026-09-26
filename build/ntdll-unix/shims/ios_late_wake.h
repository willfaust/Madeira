/*
 * iOS-Madeira ml1110: the LATE-WAKE census.
 *
 * WHAT IT IS FOR, AND WHY ml1060'S DETECTOR COULD NOT SEE IT.
 * ----------------------------------------------------------
 * ml1060 added a server-side lost-wakeup detector (ios_scan_lost_wakeups in
 * build/wineserver/queue_ios.c).  It is deliberately conservative: it reports
 * only a thread that has been inside ONE server_wait for more than five
 * seconds, on ONE cell-backed object, that the server really has queued, whose
 * cell says signalled -- and only when all four still hold on the NEXT scan
 * five seconds later.  That is the right shape for a HANG.
 *
 * It is the wrong shape for the failure this census exists for: a run that is
 * making progress, just far too slowly, because hand-offs are arriving on the
 * back of a TIMEOUT rather than on the back of a wake.  Nothing in that state
 * waits five seconds.  A wait that should have been satisfied in microseconds
 * and is instead satisfied by a 1 ms, 2 ms or 2 s timer expiry looks, to every
 * counter this port had, exactly like a wait that legitimately timed out:
 * [srv-stats] reports `tmo_fin=11159' per 10 s and cannot say whether any of
 * those objects were signalled at the moment the timer fired.
 *
 * THE THREE NUMBERS.
 *   late    -- a FINITE single-object wait returned STATUS_TIMEOUT and the
 *              object's cell said "a waiter could be released right now" at
 *              that instant.  The wait was owed a wake and got a timer.
 *   age     -- how long the token had been sitting in the cell when that
 *              happened, from the client-side release stamp (cell->rel_us).
 *              A handful of microseconds is an honest race -- the release and
 *              the expiry genuinely collided.  Hundreds of microseconds or
 *              more is a wake that was owed and never delivered, and the p50
 *              of this distribution is the whole difference between the two
 *              readings.
 *   rescued -- an INFINITE wait that the ml982/ml1060 heartbeat turned into a
 *              chain of finite server waits timed out, and the watchdog's
 *              zero-timeout re-ask then satisfied it immediately.  That is
 *              literally "this release's wake was delivered only by a later
 *              timeout", counted at the one place in the image that can see
 *              both halves.  It was previously invisible: it is currently
 *              folded into `watchdog=' in [srv-stats], which counts the check
 *              whether or not it found anything.
 *
 * COST.  One predicted-not-taken branch on the release path (the stamp, and
 * only while the census is on), and on the wait path nothing at all until a
 * wait has already returned STATUS_TIMEOUT -- at which point the thread has
 * just paid a server round trip and one more cell load is free.
 *
 * KNOB.  MADEIRA_LATEWAKE=0 removes the stamp and the census entirely.
 *
 * Every counter is a relaxed atomic add, drained by exactly ONE reader
 * (ios_srv_stats_report / the [perf] line in build/ntdll-unix/server_ios.c),
 * which exchanges the block to zero -- the same discipline as
 * ios_srv_nt_counts and ios_spin_hist.  No thread_local anywhere: implicit
 * TLS is unpopulated on FEX-created threads in this image.
 */

#ifndef __IOS_LATE_WAKE_H
#define __IOS_LATE_WAKE_H

#define IOS_LATE_AGE_N     16   /* log2 us buckets: 0,1,2,4,...,>=16384 us */
#define IOS_LATE_HOT_N      4   /* objects named in the detail line         */

struct ios_late_hot
{
    unsigned int cell;         /* cell index, or 0xffffffff for an empty slot */
    unsigned int kind;         /* MADEIRA_CELL_KIND_*                         */
    unsigned int late;         /* late expiries charged to this cell           */
};

struct ios_late_snapshot
{
    unsigned int tmo_fin;      /* finite 1-object waits that returned TIMEOUT */
    unsigned int late_sem;     /* ... on a semaphore cell that was signalled  */
    unsigned int late_event;   /* ... on an event cell that was signalled     */
    unsigned int nostamp;      /* ... signalled but never client-released     */
    unsigned int hb;           /* heartbeat expiries on an infinite wait      */
    unsigned int hb_late;      /* ... with the cell signalled at expiry       */
    unsigned int rescued;      /* wakes delivered only by a later timeout     */
    unsigned int age[IOS_LATE_AGE_N];
    unsigned int age_p50;      /* us, bucket lower bound (never overstates)   */
    unsigned int age_p90;
    struct ios_late_hot hot[IOS_LATE_HOT_N];
};

/* Read and zero the whole block.  Safe from any thread; a lost increment costs
 * fidelity, never correctness.  Defined in wine/dlls/ntdll/unix/sync.c next to
 * the counters, like madeira_fast_park_hist_snapshot(). */
extern void madeira_late_wake_snapshot( struct ios_late_snapshot *out );

/* "did anything at all happen this window" -- lets the quiet build print the
 * two numbers on [perf] without formatting a block nobody needs. */
extern unsigned int madeira_late_wake_peek( unsigned int *rescued );

#endif /* __IOS_LATE_WAKE_H */
