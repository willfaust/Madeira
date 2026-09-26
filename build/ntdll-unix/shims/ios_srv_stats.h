/*
 * iOS-Madeira ml950: shared counter block for the [srv-stats] report.
 *
 * The report itself lives in build/ntdll-unix/server_ios.c (it is printed from
 * whichever thread first notices the 10 s deadline at the end of a server
 * call).  The Nt* entry-point counters below are incremented from
 * wine/dlls/ntdll/unix/sync.c, which is a different translation unit, so the
 * storage is declared here and defined once in server_ios.c.
 *
 * Every counter is written with __ATOMIC_RELAXED and is allowed to lose an
 * increment to a race; these are rates, not ledgers.  Nothing reads them
 * except the reporter, which exchanges them to zero once per window.
 */

#ifndef __IOS_SRV_STATS_H
#define __IOS_SRV_STATS_H

enum ios_srv_nt_counter
{
    IOS_NT_SET_EVENT,          /* NtSetEvent                                 */
    IOS_NT_RESET_EVENT,        /* NtResetEvent / NtClearEvent                */
    IOS_NT_PULSE_EVENT,        /* NtPulseEvent                               */
    IOS_NT_WAIT_SINGLE,        /* NtWaitForSingleObject                      */
    IOS_NT_WAIT_MULTI,         /* NtWaitForMultipleObjects (count > 1)       */
    IOS_NT_SIGNAL_AND_WAIT,    /* NtSignalAndWaitForSingleObject             */
    IOS_NT_RELEASE_SEM,        /* NtReleaseSemaphore                         */
    IOS_NT_RELEASE_MUTANT,     /* NtReleaseMutant                            */
    IOS_NT_DELAY_ZERO,         /* NtDelayExecution with a zero timeout       */
    IOS_NT_DELAY_NONZERO,      /* NtDelayExecution with a real timeout       */
    IOS_NT_YIELD_SYSCALL,      /* sched_yield() actually issued              */
    IOS_NT_SLEEP0_PARK,        /* ml951: bounded park instead of a yield     */
    IOS_NT_ALERT_WAIT,         /* NtWaitForAlertByThreadId (futex, no server)*/
    IOS_NT_ALERT_WAKE,         /* NtAlertThreadByThreadId  (futex, no server)*/
    /* fast-path outcomes, see MADEIRA_FASTSYNC in sync.c */
    IOS_NT_FAST_HIT,           /* completed with no server round trip        */
    IOS_NT_FAST_MISS,          /* fell back to the server                    */
    IOS_NT_FAST_WAKE,          /* os_sync_wake_by_address issued             */
    IOS_NT_FAST_SLEEP,         /* os_sync_wait_on_address entered            */

    /* ml962: what the handle -> cell cache is actually doing.  On the first
     * device logs get_inproc_sync_fd was the #1 request kind (925-1837 per
     * 10 s), i.e. "learn once per handle, ever" was not happening at all --
     * the negative answer was never cached, so every wait on a thread,
     * process, mutex, semaphore, timer or file re-asked.  These four make that
     * visible instead of inferable: learn_ev + learn_none is the number of
     * get_inproc_sync_fd requests the cache issued, relearn is how many of
     * them were for a handle whose own entry was still in the slot (thrash,
     * not cold misses), stale_gen is the recycled-cell rejection. */
    IOS_FS_LEARN_EVENT,        /* learn resolved to a cell-backed event      */
    IOS_FS_LEARN_NONE,         /* learn resolved to "no cell", now cached    */
    IOS_FS_RELEARN,            /* learn for a handle already in its slot     */
    IOS_FS_STALE_GEN,          /* entry matched but the cell was recycled    */
    IOS_FS_EVICT,              /* madeira_fast_close() dropped an entry      */

    /* ml982.  POLLPEEK is the whole point of the default mode: a zero-timeout
     * single-object wait answered STATUS_TIMEOUT from the shared cell with no
     * server round trip.  On the measurement this was written against that is
     * 116607 requests per 10 s, a third of all traffic, of which 115920 were
     * going to be told "no" anyway.  WATCHDOG/DESYNC are the self-heal: a
     * watchdog tick is one re-validation of a long INFINITE wait, a desync is
     * one object that had to be demoted to the server path because the server
     * and the cell disagreed. */
    IOS_FS_POLLPEEK,           /* zero-timeout wait answered from the cell   */
    IOS_FS_WATCHDOG,           /* long-wait re-validations performed         */
    IOS_FS_DESYNC,             /* objects demoted after a real disagreement  */

    /* ml1010: the SEMAPHORE half of the fast path, counted separately from
     * the event half because the two arm together but can fail apart.  The
     * measurement this was written against has release_semaphore=76091 and
     * select=308752 per 10 s, essentially all of it single-object INFINITE
     * waits by worker threads of ONE process: sem_rel should end up tracking
     * NtReleaseSemaphore almost exactly, sem_wait should track the worker
     * wakeups, and `release_semaphore'/`select' in the kinds line should fall
     * by an order of magnitude.  MADEIRA_FASTSYNC_SEM=0 zeroes both. */
    IOS_FS_SEM_REL,            /* NtReleaseSemaphore served from the cell    */
    IOS_FS_SEM_WAIT,           /* a wait that took a token from the cell     */

    /* ml1050 NOTE: the adaptive spin's payoff counters are deliberately NOT
     * here.  This array is exchanged to zero by ios_srv_stats_report(), and
     * with MADEIRA_DIAG on the [frame] reporter runs in the same window, so a
     * second reader would get whatever the first left behind.  They live in
     * wine/dlls/ntdll/unix/sync.c next to the controller that produces them
     * and are drained by exactly one reader
     * (madeira_fast_park_hist_snapshot). */

    /* Breakdown of the `select` request, which is the one request kind whose
     * count says nothing about its cause: NtWaitForSingleObject, a multi-object
     * wait, NtSignalAndWaitForSingleObject, a keyed event and an alertable
     * NtDelayExecution all arrive as REQ_select.  These buckets are what
     * separate "a handful of threads parked on an infinite wait" (free — the
     * thread is descheduled and the request happened once) from "a pacing loop
     * paying a full round trip per millisecond to be told it timed out"
     * (candidate (a) of the ml950 brief), which look identical in reqs=.
     * Counted in server_wait, which still has the caller's own timeout. */
    IOS_SEL_WAIT1_INF,         /* 1 handle,  no timeout                      */
    IOS_SEL_WAIT1_FIN,         /* 1 handle,  finite timeout                  */
    IOS_SEL_WAIT1_POLL,        /* 1 handle,  zero timeout (a state query)    */
    IOS_SEL_WAITN_INF,         /* >1 handle, no timeout                      */
    IOS_SEL_WAITN_FIN,         /* >1 handle, finite timeout                  */
    IOS_SEL_WAITN_POLL,        /* >1 handle, zero timeout                    */
    IOS_SEL_WAITALL,           /* SELECT_WAIT_ALL, any timeout               */
    IOS_SEL_SIGWAIT,           /* SELECT_SIGNAL_AND_WAIT                     */
    IOS_SEL_KEYED,             /* SELECT_KEYED_EVENT_WAIT / _RELEASE         */
    IOS_SEL_DELAY_ALERT,       /* select_op == NULL: alertable NtDelayExecution */
    IOS_SEL_OTHER,
    IOS_SEL_RET_TIMEOUT,       /* ... of all of the above, returned TIMEOUT   */
    IOS_SEL_RET_TIMEOUT_FIN,   /* ... of the FINITE ones only                */

    IOS_NT_COUNTER_MAX
};

extern unsigned int ios_srv_nt_counts[IOS_NT_COUNTER_MAX];

static inline void ios_srv_nt_count( enum ios_srv_nt_counter which )
{
    __atomic_fetch_add( &ios_srv_nt_counts[which], 1, __ATOMIC_RELAXED );
}

/* ml962: print one report right now instead of waiting for the next 10 s
 * window.  Defined in build/ntdll-unix/server_ios.c, called from the
 * MADEIRA-EXIT path so a process that dies in its first seconds still leaves
 * its counters in the log. */
extern void ios_srv_stats_report_now(void);

/*
 * ml951: NtQueryInformationThread breakdown.  `get_thread_info' was the
 * second-loudest request kind (103140 in a 10 s window) and every one of them
 * comes from NtQueryInformationThread in build/ntdll-unix/thread_ios.c — but
 * the request counter cannot say WHICH info class, nor whether the target is
 * the calling thread (answerable without the server) or another one.  These
 * buckets answer both, and the SELF/OTHER split is what decides whether the
 * client-side cache below can help at all.
 *
 * Counted in NtQueryInformationThread, reported by ios_srv_stats_report().
 */
enum ios_srv_thrinfo_counter
{
    IOS_TI_BASIC_SELF,         /* ThreadBasicInformation, current thread     */
    IOS_TI_BASIC_OTHER,        /* ThreadBasicInformation, another thread     */
    IOS_TI_BASIC_CACHED,       /* ... of the SELF ones, answered from cache  */
    IOS_TI_AFFINITY,           /* ThreadAffinityMask / ThreadGroupInformation*/
    IOS_TI_AFFINITY_CACHED,
    IOS_TI_TIMES,              /* ThreadTimes (get_thread_times, not _info)  */
    IOS_TI_AMILAST,            /* ThreadAmILastThread                        */
    IOS_TI_TERMINATED,         /* ThreadIsTerminated                         */
    IOS_TI_SUSPEND,            /* ThreadSuspendCount                         */
    IOS_TI_START_ADDR,         /* ThreadQuerySetWin32StartAddress            */
    IOS_TI_NAME,               /* ThreadNameInformation                      */
    IOS_TI_OTHER_CLASS,        /* everything else that reaches the server    */
    IOS_TI_SET,                /* NtSetInformationThread (cache invalidation)*/

    IOS_TI_COUNTER_MAX
};

extern unsigned int ios_srv_thrinfo_counts[IOS_TI_COUNTER_MAX];

static inline void ios_srv_thrinfo_count( enum ios_srv_thrinfo_counter which )
{
    __atomic_fetch_add( &ios_srv_thrinfo_counts[which], 1, __ATOMIC_RELAXED );
}

#endif /* __IOS_SRV_STATS_H */
