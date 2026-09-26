/*
 * iOS-Madeira ml970: the spin governor's own histogram.
 *
 * The governor lives in wine/dlls/ntdll/unix/sync.c (ios_spin_governor, shared
 * by NtDelayExecution's zero-timeout path and by NtYieldExecution); the report
 * lives in build/ntdll-unix/server_ios.c next to the rest of [srv-stats].
 * Those are two translation units, so the snapshot shape is declared here.
 *
 * WHY THIS EXISTS.  [srv-stats] can say how many Sleep(0)s, yields and parks a
 * window contained, but not the ONE number the policy is actually a function
 * of: how long a spin runs before the thread it is waiting for makes progress.
 * A 200 k/s Sleep(0) rate is 2 k streaks of 100 calls or 200 k streaks of one,
 * and those want opposite policies (park deeply vs never enter the kernel at
 * all).  The governor already knows, because a streak ENDS exactly when the
 * thread does something else -- a real wait, a non-zero sleep, or a gap longer
 * than the 2 ms window -- so it records the finished streak's length and
 * duration into log2 buckets on the way out.  That distribution is what the
 * park/gap ladder in sync.c is calibrated against, and it is what the NEXT
 * device log has to show before the constants there are touched again.
 *
 * Every counter is a relaxed atomic add and is exchanged to zero when it is
 * read, so the numbers are per-window rates, exactly like ios_srv_nt_counts.
 */

#ifndef __IOS_SPIN_HIST_H
#define __IOS_SPIN_HIST_H

#define IOS_SPIN_HIST_N   16   /* log2 buckets: 1,2,4,...,>=32768 */

struct ios_spin_snapshot
{
    /* log2 histogram of a finished streak's LENGTH, in governed calls */
    unsigned int calls[IOS_SPIN_HIST_N];
    /* log2 histogram of a finished streak's DURATION, in microseconds.
     * A streak ends when the thread makes progress, so this is the
     * time-to-progress distribution the park length has to cover. */
    unsigned int us[IOS_SPIN_HIST_N];

    unsigned int streaks;      /* finished streaks in this window            */
    unsigned int gov_sleep0;   /* governed calls that arrived as Sleep(0)    */
    unsigned int gov_yield;    /* governed calls that arrived as a yield     */
    unsigned int sys_yield;    /* sched_yield() the governor actually issued */
    unsigned int sys_park;     /* futex parks the governor actually issued   */
    unsigned int us_p50;       /* median streak duration, us (from `us`)     */
    unsigned int us_p80;       /* 80th percentile streak duration, us        */
    unsigned int warm_hits;    /* streaks that started on a learned rung     */
};

/* Read and zero the whole block.  Safe from any thread; a lost increment
 * costs fidelity, never correctness. */
extern void ios_spin_hist_snapshot( struct ios_spin_snapshot *out );

#endif /* __IOS_SPIN_HIST_H */
