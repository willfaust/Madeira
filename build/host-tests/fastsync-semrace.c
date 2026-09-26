/* MADEIRA ml1010: host model of the fastsync SEMAPHORE cell protocol.
 *
 * The event model next door (fastsync-cellrace.c) reproduces one specific
 * residual.  This one is an exact-accounting model of the whole semaphore
 * protocol, because a semaphore carries a COUNT rather than a token and the
 * properties that have to hold are arithmetic ones that a soak test would hide
 * as a stall:
 *
 *   A. CONSERVATION.  Every token produced is consumed at most once, and no
 *      token is lost: produced == consumed + whatever is left in the cell.
 *      Enforced by a shadow ledger -- each consumer that wins a CAS takes one
 *      unit off a separate atomic "real work" counter which the producers add
 *      to BEFORE they release, so a consumer that proceeds without a token
 *      drives that counter negative and is caught exactly.
 *   B. NO LOST WAKEUP.  Consumers park on the cell with the shipping Dekker
 *      pairing (waiters++ / load count, against CAS count += n / load
 *      waiters).  At the end, with the producers stopped and every token
 *      drained, no consumer may still be parked.
 *   C. TIMED WAITS.  A consumer that reports a timeout must not be holding a
 *      token: a timed-out waiter performs no successful CAS, which the ledger
 *      would otherwise catch as a token that was consumed and dropped.
 *   D. OVERFLOW.  count + n > max refuses the WHOLE release and changes
 *      nothing, single- and multi-threaded.
 *   E. GENERATION.  A cell destroyed and handed to a different semaphore under
 *      a consumer's feet must never let that consumer's CAS succeed.
 *   F. LIVENESS OF THE MIXED PROTOCOL (ml1060).  With EVERY waiter on the
 *      modelled SERVER path and every releaser on the client fast path -- the
 *      shape a device log actually shows -- and with the producer WAITING for
 *      the batch it submitted, no batch may stay undrained for longer than a
 *      bound.  This is the one property an accounting test cannot see: the
 *      wrong ordering loses no token, it only fails to WAKE, and the count
 *      then reconciles perfectly while the program stops.
 *
 * The server half is modelled too -- a thread that CAS-claims tokens the way
 * semaphore_sync_signaled() does and hands them to "queued" waiters -- so the
 * mixed client/server case is under test, not just the client one.
 *
 * Everything is compiled against the REAL shipping header
 * (build/ntdll-unix/shims/ios_fastsync.h), so the packing, the accessors, the
 * sign handling and the struct layout under test are the shipping ones.
 *
 * Exit 0 = every check passed.  Exit 80-85 are the ml1060 server-path checks;
 * 84 ("a batch took longer than the bound to drain") is a lost wakeup, and 85
 * is the control failing to fail, which invalidates 84.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "ios_fastsync.h"

#define NPRODUCERS      3
#define NCONSUMERS      6
#define NSERVER         1           /* threads modelling the wineserver queue  */
#define RUN_MS       2500
#define SEM_MAX        64

/* ------------------------------------------------------------------------
 * The cell under test, plus the futex the header would use.  os_sync_* does
 * not exist on Linux, so the park/wake pair is modelled with a condvar keyed
 * on the SAME word the shipping code parks on (the state half of `sg'):
 * madeira_fast_park( addr, val, ns ) == "sleep while *addr == val".  The
 * protocol under test is the CAS ordering and the waiter accounting, which
 * are identical whichever primitive delivers the wake.
 * ---------------------------------------------------------------------- */

static struct madeira_sync_cell cell;

static pthread_mutex_t park_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  park_cnd = PTHREAD_COND_INITIALIZER;

static void park_on( const int *addr, int val, unsigned long long ns )
{
    struct timespec ts;

    pthread_mutex_lock( &park_mtx );
    if (atomic_load_explicit( (const _Atomic int *)addr, memory_order_seq_cst ) == val)
    {
        clock_gettime( CLOCK_REALTIME, &ts );
        ts.tv_nsec += (long)(ns % 1000000000ull);
        ts.tv_sec  += (time_t)(ns / 1000000000ull);
        if (ts.tv_nsec >= 1000000000L) { ts.tv_nsec -= 1000000000L; ts.tv_sec++; }
        pthread_cond_timedwait( &park_cnd, &park_mtx, &ts );
    }
    pthread_mutex_unlock( &park_mtx );
}

static void wake_all( void )
{
    pthread_mutex_lock( &park_mtx );
    pthread_cond_broadcast( &park_cnd );
    pthread_mutex_unlock( &park_mtx );
}

/* ------------------------------------------------------------------------
 * The ledger.  `work' is incremented by a producer BEFORE it publishes the
 * tokens and decremented by a consumer AFTER it has won a CAS, so a consumer
 * that proceeds without a real token takes it below zero.
 * ---------------------------------------------------------------------- */

static _Atomic long  work;
static _Atomic unsigned long produced, consumed, timeouts, parked_now;
static _Atomic unsigned long overflow_refused, srv_served, parks, no_work;
static _Atomic int stop;                 /* harness only, atomic so a TSan
                                          * report can only ever be about the
                                          * protocol under test */
static unsigned int my_gen;          /* the generation every thread resolved */

/* ---- the CLIENT's release, verbatim in shape with the shipping
 * madeira_fast_sem_release() in ntdll/unix/sync.c -------------------------- */

static int client_release( unsigned int gen, unsigned int n, unsigned int *prev )
{
    uint64_t sg;
    int cur;

    for (;;)
    {
        sg = atomic_load_explicit( (_Atomic uint64_t *)&cell.sg, memory_order_seq_cst );
        if (MADEIRA_SG_GEN( sg ) != gen) return -1;              /* recycled: server */
        cur = MADEIRA_SG_STATE( sg );
        if (cur < 0) return -1;                                  /* DISABLED */
        if (n > cell.smax || (unsigned int)cur + n > cell.smax)
        {
            atomic_fetch_add_explicit( &overflow_refused, 1, memory_order_relaxed );
            return 0;                                            /* LIMIT_EXCEEDED */
        }
        if (atomic_compare_exchange_strong_explicit(
                (_Atomic uint64_t *)&cell.sg, &sg, MADEIRA_SG( gen, cur + (int)n ),
                memory_order_seq_cst, memory_order_seq_cst )) break;
    }
    if (prev) *prev = (unsigned int)cur;

    /* Dekker half #2: the CAS above and this load are both seq_cst. */
    if (n && atomic_load_explicit( (_Atomic int *)&cell.waiters, memory_order_seq_cst ))
        wake_all();
    return 1;
}

/* ---- the CLIENT's "take one token", verbatim in shape with
 * madeira_fast_try()'s semaphore arm ------------------------------------- */

static int client_try( unsigned int gen )
{
    uint64_t sg = atomic_load_explicit( (_Atomic uint64_t *)&cell.sg, memory_order_seq_cst );

    for (;;)
    {
        int cur = MADEIRA_SG_STATE( sg );

        if (MADEIRA_SG_GEN( sg ) != gen) return 0;
        if (cur <= 0) return 0;
        if (atomic_compare_exchange_strong_explicit(
                (_Atomic uint64_t *)&cell.sg, &sg, MADEIRA_SG( gen, cur - 1 ),
                memory_order_seq_cst, memory_order_seq_cst )) return 1;
    }
}

/* ---- the CLIENT's park loop, verbatim in shape with madeira_fast_wait() -- */

static int client_wait( unsigned int gen, unsigned long long budget_ns )
{
    int rounds;

    if (client_try( gen )) return 1;
    for (rounds = 0; rounds < 64 && !stop; rounds++)
    {
        int st;
        uint64_t sg;

        /* Dekker half #1: waiters++ then load state, both seq_cst. */
        atomic_fetch_add_explicit( (_Atomic int *)&cell.waiters, 1, memory_order_seq_cst );
        atomic_fetch_add_explicit( &parked_now, 1, memory_order_relaxed );
        sg = atomic_load_explicit( (_Atomic uint64_t *)&cell.sg, memory_order_seq_cst );
        if (MADEIRA_SG_GEN( sg ) != gen)
        {
            /* leave `waiters' alone: it belongs to the new occupant's count */
            atomic_fetch_sub_explicit( &parked_now, 1, memory_order_relaxed );
            return -1;
        }
        st = MADEIRA_SG_STATE( sg );
        if (st == MADEIRA_CELL_RESET)
        {
            atomic_fetch_add_explicit( &parks, 1, memory_order_relaxed );
            park_on( madeira_cell_futex( &cell ), MADEIRA_CELL_RESET, budget_ns );
        }

        if (MADEIRA_SG_GEN( atomic_load_explicit( (_Atomic uint64_t *)&cell.sg,
                                                  memory_order_seq_cst ) ) != gen)
        {
            atomic_fetch_sub_explicit( &parked_now, 1, memory_order_relaxed );
            return -1;
        }
        atomic_fetch_sub_explicit( (_Atomic int *)&cell.waiters, 1, memory_order_seq_cst );
        atomic_fetch_sub_explicit( &parked_now, 1, memory_order_relaxed );

        if (st < 0) return -1;                       /* DISABLED: the server */
        if (client_try( gen )) return 1;
    }
    return 0;                                        /* timed out: NO token held */
}

/* ---- the SERVER's claim, verbatim in shape with semaphore_cell_take() --- */

static int server_take( void )
{
    uint64_t sg = atomic_load_explicit( (_Atomic uint64_t *)&cell.sg, memory_order_seq_cst );

    for (;;)
    {
        int cur = MADEIRA_SG_STATE( sg );

        if (cur <= 0) return 0;
        if (atomic_compare_exchange_strong_explicit(
                (_Atomic uint64_t *)&cell.sg, &sg, MADEIRA_SG( MADEIRA_SG_GEN( sg ), cur - 1 ),
                memory_order_seq_cst, memory_order_seq_cst )) return 1;
    }
}

/* ------------------------------------------------------------------ threads */

static void *producer( void *arg )
{
    unsigned int s = 7717 + (unsigned int)(uintptr_t)arg;

    while (!stop)
    {
        unsigned int n = 1 + ((s = s * 1103515245u + 12345u) >> 16) % 4u;
        unsigned int prev = 0;

        /* publish the WORK before the tokens: a consumer must never find a
         * token with nothing behind it */
        atomic_fetch_add_explicit( &work, (long)n, memory_order_seq_cst );
        if (client_release( my_gen, n, &prev ) == 1)
            atomic_fetch_add_explicit( &produced, n, memory_order_relaxed );
        else
            atomic_fetch_sub_explicit( &work, (long)n, memory_order_seq_cst );  /* refused */
        /* Idle now and then, so the cell genuinely empties and the consumers
         * genuinely PARK.  Without this the count never reaches zero and the
         * whole park/wake half of the protocol is never exercised -- which is
         * the half a lost wakeup lives in. */
        if (!(s & 0x30)) sched_yield();
        if (!(s & 0xf00)) usleep( 200 );
    }
    return NULL;
}

static void *consumer( void *arg )
{
    unsigned int s = 31337 + (unsigned int)(uintptr_t)arg;

    while (!stop)
    {
        unsigned long long budget = 50000ull + ((s = s * 1103515245u + 12345u) >> 18) % 400000ull;
        int r = client_wait( my_gen, budget );

        if (r == 1)
        {
            atomic_fetch_add_explicit( &consumed, 1, memory_order_relaxed );
            if (atomic_fetch_sub_explicit( &work, 1, memory_order_seq_cst ) <= 0)
                atomic_fetch_add_explicit( &no_work, 1, memory_order_relaxed );
        }
        else if (!r) atomic_fetch_add_explicit( &timeouts, 1, memory_order_relaxed );
    }
    return NULL;
}

/* The wineserver's own queue: claims tokens with the same CAS the real
 * semaphore_sync_signaled() uses and hands them to its queued threads.  This
 * is the mixed-waiter case -- fast waiters and server waiters on one object. */
static void *server_thread( void *arg )
{
    while (!stop)
    {
        atomic_fetch_add_explicit( (_Atomic int *)&cell.srv_waiters, 1, memory_order_seq_cst );
        sched_yield();
        if (server_take())
        {
            atomic_fetch_add_explicit( &srv_served, 1, memory_order_relaxed );
            atomic_fetch_add_explicit( &consumed, 1, memory_order_relaxed );
            if (atomic_fetch_sub_explicit( &work, 1, memory_order_seq_cst ) <= 0)
                atomic_fetch_add_explicit( &no_work, 1, memory_order_relaxed );
        }
        atomic_fetch_sub_explicit( (_Atomic int *)&cell.srv_waiters, 1, memory_order_seq_cst );
    }
    return NULL;
}

/* ------------------------------------------------------------------- checks */

static void cell_init( unsigned int gen, unsigned int initial, unsigned int max )
{
    memset( (void *)&cell, 0, sizeof(cell) );
    cell.kind = MADEIRA_CELL_KIND_SEM;
    cell.smax = max;
    atomic_store_explicit( (_Atomic uint64_t *)&cell.sg, MADEIRA_SG( gen, (int)initial ),
                           memory_order_seq_cst );
}

static int check_layout( void )
{
    struct madeira_sync_cell c;

    printf( "MADEIRA-SEM: sizeof(struct madeira_sync_cell)=%zu (must be 32)\n", sizeof(c) );
    if (sizeof(c) != 32) return 70;

    c.sg = MADEIRA_SG( 0xAABBCCDDu, MADEIRA_CELL_DISABLED );
    if (*madeira_cell_futex( &c ) != MADEIRA_CELL_DISABLED) return 71;
    if (MADEIRA_SG_GEN( c.sg ) != 0xAABBCCDDu ||
        MADEIRA_SG_STATE( c.sg ) != MADEIRA_CELL_DISABLED) return 72;

    /* the largest count a semaphore may hold must survive the round trip as a
     * POSITIVE number, i.e. must not collide with DISABLED */
    c.sg = MADEIRA_SG( 1u, 0x7fffffff );
    if (MADEIRA_SG_STATE( c.sg ) != 0x7fffffff) return 72;
    c.kind = MADEIRA_CELL_KIND_SEM;
    if (madeira_cell_kind( &c ) != MADEIRA_CELL_KIND_SEM) return 72;
    printf( "MADEIRA-SEM: layout, futex half, sign and max-count round trip OK\n" );
    return 0;
}

/* D: overflow refuses the whole release and changes nothing. */
static int check_overflow( void )
{
    unsigned int prev = 0xdeadbeef;

    cell_init( 5u, 60, SEM_MAX );
    if (client_release( 5u, 4, &prev ) != 1 || prev != 60) return 73;
    if (MADEIRA_SG_STATE( cell.sg ) != 64) return 73;
    /* at max: one more must be refused and the count must not move */
    prev = 0xdeadbeef;
    if (client_release( 5u, 1, &prev ) != 0) return 73;
    if (MADEIRA_SG_STATE( cell.sg ) != 64) return 73;
    /* a release larger than max is refused whatever the count */
    cell_init( 5u, 0, SEM_MAX );
    if (client_release( 5u, SEM_MAX + 1, NULL ) != 0) return 73;
    if (MADEIRA_SG_STATE( cell.sg ) != 0) return 73;
    /* count == 0 is the "wake your queue" request: legal, changes nothing */
    cell_init( 5u, 7, SEM_MAX );
    prev = 0;
    if (client_release( 5u, 0, &prev ) != 1 || prev != 7) return 73;
    if (MADEIRA_SG_STATE( cell.sg ) != 7) return 73;
    printf( "MADEIRA-SEM: overflow refuses the whole release, count==0 is a no-op OK\n" );
    return 0;
}

/* E: a cell handed to a different semaphore must reject a stale consumer. */
static int check_generation( void )
{
    cell_init( 9u, 4, SEM_MAX );
    if (!client_try( 9u )) return 74;
    /* the object is destroyed (gen bump + DISABLED) and the cell re-allocated
     * to a stranger, already holding tokens */
    atomic_store_explicit( (_Atomic uint64_t *)&cell.sg,
                           MADEIRA_SG( 10u, MADEIRA_CELL_DISABLED ), memory_order_seq_cst );
    atomic_store_explicit( (_Atomic uint64_t *)&cell.sg, MADEIRA_SG( 11u, 8 ),
                           memory_order_seq_cst );
    if (client_try( 9u )) return 74;                 /* would be a stolen token */
    if (client_release( 9u, 1, NULL ) != -1) return 74;
    if (MADEIRA_SG_STATE( cell.sg ) != 8) return 74; /* stranger untouched */
    if (!client_try( 11u )) return 74;               /* the new owner still works */
    printf( "MADEIRA-SEM: a recycled cell rejects the stale generation, both ways OK\n" );
    return 0;
}

static int check_stress( void )
{
    pthread_t th[NPRODUCERS + NCONSUMERS + NSERVER];
    int i, n = 0;
    long left, w;
    unsigned long p, c;

    my_gen = 3u;
    cell_init( my_gen, 0, SEM_MAX );
    atomic_store( &work, 0 ); atomic_store( &produced, 0 ); atomic_store( &consumed, 0 );
    atomic_store( &timeouts, 0 ); atomic_store( &parked_now, 0 ); atomic_store( &no_work, 0 );
    atomic_store( &overflow_refused, 0 ); atomic_store( &srv_served, 0 );
    atomic_store( &parks, 0 );
    stop = 0;

    for (i = 0; i < NPRODUCERS; i++)
        pthread_create( &th[n++], NULL, producer, (void *)(uintptr_t)i );
    for (i = 0; i < NCONSUMERS; i++)
        pthread_create( &th[n++], NULL, consumer, (void *)(uintptr_t)i );
    for (i = 0; i < NSERVER; i++)
        pthread_create( &th[n++], NULL, server_thread, (void *)(uintptr_t)i );

    usleep( RUN_MS * 1000 );
    stop = 1;
    for (i = 0; i < 200; i++) { wake_all(); usleep( 1000 ); }
    for (i = 0; i < n; i++) pthread_join( th[i], NULL );

    left = MADEIRA_SG_STATE( cell.sg );
    p = atomic_load( &produced );
    c = atomic_load( &consumed );
    w = atomic_load( &work );

    printf( "MADEIRA-SEM: produced=%lu consumed=%lu left_in_cell=%ld timeouts=%lu "
            "parks=%lu srv_served=%lu refused=%lu\n",
            p, c, left, atomic_load( &timeouts ), atomic_load( &parks ),
            atomic_load( &srv_served ), atomic_load( &overflow_refused ) );

    /* A: conservation.  Every token is accounted for exactly once. */
    if ((unsigned long)left + c != p)
    {
        printf( "MADEIRA-SEM: FAIL - consumed+left=%lu but produced=%lu\n",
                (unsigned long)left + c, p );
        return 75;
    }
    /* A/C: no consumer ever proceeded without a token behind it, which also
     * proves no timed-out waiter consumed one and dropped it (the ledger would
     * be short by exactly that many). */
    if (atomic_load( &no_work ))
    {
        printf( "MADEIRA-SEM: FAIL - %lu consumers proceeded with no work behind the token\n",
                atomic_load( &no_work ) );
        return 76;
    }
    if (w != left)
    {
        printf( "MADEIRA-SEM: FAIL - ledger %ld but %ld tokens left in the cell\n", w, left );
        return 76;
    }
    /* B: nobody is still parked, and `waiters' has come back to zero. */
    if (atomic_load( &parked_now ) || cell.waiters || cell.srv_waiters)
    {
        printf( "MADEIRA-SEM: FAIL - parked=%lu waiters=%d srv_waiters=%d at rest\n",
                atomic_load( &parked_now ), cell.waiters, cell.srv_waiters );
        return 77;
    }
    if (!p || !c || !atomic_load( &parks ) || !atomic_load( &srv_served ))
    {
        printf( "MADEIRA-SEM: FAIL - the stress did not reach the paths it exists for"
                " (produced=%lu consumed=%lu parks=%lu srv_served=%lu)\n",
                p, c, atomic_load( &parks ), atomic_load( &srv_served ) );
        return 78;
    }
    printf( "MADEIRA-SEM: conservation, no-work-behind-a-token, waiter accounting OK\n" );
    return 0;
}


/* ========================================================================
 * ml1060: THE CASE THE DEVICE ACTUALLY RUNS -- every waiter on the SERVER
 * path, every releaser on the CLIENT fast path, bursts of N in [1,8], and the
 * producer WAITING for its batch before it releases the next one.
 *
 * check_stress() above models a mix: six consumers that park on the cell and
 * one thread that CAS-claims the way semaphore_sync_signaled() does.  A device
 * log (k67) showed the shipping shape is not that mix but its EXTREME:
 * sem_rel=16802 per 10 s against sem_wait=0, i.e. essentially every release
 * takes the client fast path and NOT ONE wait does -- because a managed
 * runtime waits alertably and an alertable wait is handed straight to the
 * server.  So the mixed protocol is exercised on EVERY hand-off, and the only
 * thing between a queued thread and a token in the cell is the Dekker pair
 * `CAS count+=n; load srv_waiters' against `srv_waiters++; load count'.
 *
 * WHY THIS IS A CLOSED LOOP, AND WHY THE FIRST VERSION OF IT PROVED NOTHING.
 * An open-loop model -- producers releasing on a timer -- CANNOT fail, whatever
 * the ordering, and the reason is worth writing down because it is also the
 * reason the real defect is so hard to see: a missed wake is always collected
 * by the NEXT release, because every release re-runs the server's whole queue.
 * A first draft of this test duly reported zero lost wakeups for the correct
 * AND the deliberately broken ordering, which says only that the test was
 * measuring the wrong thing.
 *
 * A lost wake only becomes a HANG when nothing else is going to release: a job
 * system whose producer is waiting for the batch it just submitted.  That is
 * the closed loop modelled here, and in it ONE lost wake is terminal.  The
 * check is therefore a liveness bound, exactly as it should be: no batch may
 * stay undrained for more than SRV_STALL_MS while workers are queued on it.
 *
 * The rescue when the bound is exceeded is `srv_wake_up_unlimited()' -- which
 * is `wake_up( obj, 0 )', which is precisely what the ml1060 server-side
 * detector does on the device.  So the model also demonstrates that the
 * self-heal works: the broken ordering stalls, is rescued, and still passes
 * conservation with no token lost or duplicated.
 * ===================================================================== */

#define SRV_WAITERS      8
#define SRV_RELEASERS    3
#define SRV_WAIT_MS   5000        /* effectively INFINITE: a Wine wait with no
                                   * timeout has no rescuer but the protocol  */
#define SRV_STALL_MS   100        /* liveness bound on draining a batch      */
#define SRV_RUN_MS    2500

struct srv_entry
{
    int queued;                   /* on the server's wait queue              */
    int satisfied;                /* check_wait handed it a token            */
    pthread_cond_t cv;
};

static struct srv_entry      srvq[SRV_WAITERS];
static pthread_mutex_t       srv_mtx = PTHREAD_MUTEX_INITIALIZER;
/* ONE BATCH IN FLIGHT AT A TIME, and this is the point of the whole test.
 * With several batches overlapping, a release whose wake was lost is rescued
 * by the NEXT release from another producer -- every release re-runs the
 * server's entire queue, so one notifying producer collects everybody's
 * stranded tokens.  That rescue is real and is why the defect is survivable in
 * a busy phase; it is also why a model with overlapping producers reports a
 * clean bill of health for a protocol that is demonstrably broken.  A job
 * system that is WAITING for the batch it submitted has no such rescuer, and
 * that is the state a loading screen is in. */
static pthread_mutex_t       prod_mtx = PTHREAD_MUTEX_INITIALIZER;
static _Atomic long          outstanding;      /* jobs released, not yet run */
static _Atomic unsigned long srv_late, srv_woken, srv_timeouts, srv_requests;
static _Atomic unsigned long srv_stalls, srv_stall_ms_max;
static int                   srv_broken;       /* the wrong-order releaser   */

static unsigned long long srv_now_ms( void )
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return (unsigned long long)ts.tv_sec * 1000ull + (unsigned long long)ts.tv_nsec / 1000000ull;
}

/* wake_up( obj, 0 ): walk the queue handing out tokens until a whole pass
 * hands out none.  The caller holds srv_mtx, exactly as every server request
 * runs on the one server thread. */
static void srv_wake_up_unlimited( void )
{
    int again = 1;

    while (again)
    {
        int i;

        again = 0;
        for (i = 0; i < SRV_WAITERS; i++)
        {
            if (!srvq[i].queued || srvq[i].satisfied) continue;
            if (!server_take()) return;            /* no tokens left at all */
            srvq[i].satisfied = 1;
            pthread_cond_signal( &srvq[i].cv );
            atomic_fetch_add_explicit( &srv_woken, 1, memory_order_relaxed );
            again = 1;
        }
    }
}

/* THE SAME DELAY IN THE SAME PLACE.
 *
 * Both orderings are two operations -- a CAS on the count and a load of
 * srv_waiters -- differing only in which comes first.  A window a handful of
 * instructions wide is not reliably hit in either, so it is WIDENED,
 * identically, BETWEEN the two operations in both.  That is the discipline
 * fastsync-cellrace.c used to show ml982 stealing 943854 tokens where ml990
 * stole 0 of 5.2 M: the two runs differ in the protocol and in nothing else.
 *
 *   Shipping:  CAS count += n   [widen]   load srv_waiters
 *              a waiter that queues inside the window published srv_waiters
 *              BEFORE this load, so it is woken.
 *   Wrong:     load srv_waiters [widen]   CAS count += n
 *              a waiter that queues inside the window published srv_waiters
 *              AFTER the load, and the count it read was still 0, so it sleeps
 *              on a token that lands a moment later and nobody tells it. */
static void srv_widen( void )
{
    usleep( 50 );
}

/* The CLIENT's NtReleaseSemaphore fast path, both orderings. */
static void srv_client_release( unsigned int gen, unsigned int n )
{
    uint64_t sg;
    int cur, notify = 0;

    if (srv_broken)
    {
        notify = atomic_load_explicit( (_Atomic int *)&cell.srv_waiters,
                                       memory_order_seq_cst ) != 0;
        srv_widen();
    }
    for (;;)
    {
        sg = atomic_load_explicit( (_Atomic uint64_t *)&cell.sg, memory_order_seq_cst );
        if (MADEIRA_SG_GEN( sg ) != gen) return;
        cur = MADEIRA_SG_STATE( sg );
        if (cur < 0) return;
        if (n > cell.smax || (unsigned int)cur + n > cell.smax)
        {
            atomic_fetch_add_explicit( &overflow_refused, 1, memory_order_relaxed );
            atomic_fetch_sub_explicit( &work, (long)n, memory_order_seq_cst );
            atomic_fetch_sub_explicit( &outstanding, (long)n, memory_order_seq_cst );
            return;                                /* LIMIT_EXCEEDED: no work */
        }
        if (atomic_compare_exchange_strong_explicit(
                (_Atomic uint64_t *)&cell.sg, &sg, MADEIRA_SG( gen, cur + (int)n ),
                memory_order_seq_cst, memory_order_seq_cst )) break;
    }
    atomic_fetch_add_explicit( &produced, n, memory_order_relaxed );

    /* Dekker, client half #1.  The shipping order loads srv_waiters AFTER the
     * CAS; `srv_broken' loaded it before, which is the hole. */
    if (!srv_broken)
    {
        srv_widen();
        notify = atomic_load_explicit( (_Atomic int *)&cell.srv_waiters,
                                       memory_order_seq_cst ) != 0;
    }
    if (notify)
    {
        atomic_fetch_add_explicit( &srv_requests, 1, memory_order_relaxed );
        pthread_mutex_lock( &srv_mtx );
        srv_wake_up_unlimited();                   /* release_semaphore( 0 ) */
        pthread_mutex_unlock( &srv_mtx );
    }
}

static void *srv_releaser( void *arg )
{
    unsigned int s = 5557 + (unsigned int)(uintptr_t)arg;

    while (!stop)
    {
        unsigned int n = 1 + ((s = s * 1103515245u + 12345u) >> 16) % 8u;
        unsigned long long t0;

        pthread_mutex_lock( &prod_mtx );
        atomic_fetch_add_explicit( &work, (long)n, memory_order_seq_cst );
        atomic_fetch_add_explicit( &outstanding, (long)n, memory_order_seq_cst );
        srv_client_release( my_gen, n );

        /* THE CLOSED LOOP: nothing else will release until this batch has run,
         * so a wake that was not delivered is not recoverable by a later
         * release.  This is the job system the device is running. */
        t0 = srv_now_ms();
        while (!stop && atomic_load_explicit( &outstanding, memory_order_seq_cst ) > 0)
        {
            unsigned long long el = srv_now_ms() - t0;

            if (el > SRV_STALL_MS)
            {
                unsigned long prev;

                atomic_fetch_add_explicit( &srv_stalls, 1, memory_order_relaxed );
                prev = atomic_load_explicit( &srv_stall_ms_max, memory_order_relaxed );
                if (el > prev)
                    atomic_store_explicit( &srv_stall_ms_max, (unsigned long)el,
                                           memory_order_relaxed );
                /* THE SELF-HEAL, and it is the same call ml1060's server-side
                 * detector makes: wake_up( obj, 0 ). */
                pthread_mutex_lock( &srv_mtx );
                srv_wake_up_unlimited();
                pthread_mutex_unlock( &srv_mtx );
                t0 = srv_now_ms();
            }
            /* Poll rather than sleep: the producer must submit the NEXT batch
             * while the workers are still on their way back to the wait, which
             * is the only moment `srv_waiters == 0' and the Dekker pair is the
             * only thing keeping the hand-off alive.  A 200 us sleep here gives
             * every worker time to re-queue first, srv_waiters is then never 0
             * at a release, and the test cannot distinguish the two orderings. */
            sched_yield();
        }
        pthread_mutex_unlock( &prod_mtx );
    }
    return NULL;
}

static void *srv_waiter( void *arg )
{
    int idx = (int)(uintptr_t)arg;

    while (!stop)
    {
        int got = 0, timed_out = 0;
        struct timespec ts;

        pthread_mutex_lock( &srv_mtx );
        /* wait_on() -> semaphore_sync_add_queue(): srv_waiters++ (seq_cst)
         * strictly before check_wait() reads the count. */
        atomic_fetch_add_explicit( (_Atomic int *)&cell.srv_waiters, 1, memory_order_seq_cst );
        srvq[idx].queued = 1;
        srvq[idx].satisfied = 0;

        /* check_wait() -> semaphore_sync_signaled(): CAS-claim a token. */
        if (server_take()) { srvq[idx].satisfied = 1; got = 1; }

        if (!got)
        {
            clock_gettime( CLOCK_REALTIME, &ts );
            /* Normalise for a deadline of SECONDS, not milliseconds: adding
             * 5000 ms straight into tv_nsec leaves it at 4e9, which is not a
             * valid timespec, and pthread_cond_timedwait then returns EINVAL
             * immediately -- forever, inside srv_mtx, which is a livelock and
             * not a test. */
            ts.tv_sec  += (time_t)(SRV_WAIT_MS / 1000);
            ts.tv_nsec += (long)(SRV_WAIT_MS % 1000) * 1000000L;
            if (ts.tv_nsec >= 1000000000L) { ts.tv_nsec -= 1000000000L; ts.tv_sec++; }
            while (!srvq[idx].satisfied && !stop)
            {
                int r = pthread_cond_timedwait( &srvq[idx].cv, &srv_mtx, &ts );
                if (r == ETIMEDOUT) { timed_out = 1; break; }
                if (r && r != EINTR) break;          /* never spin on an error */
            }
            if (srvq[idx].satisfied) got = 1;
            else if (timed_out)
            {
                /* thread_timeout() -> the client re-selects immediately.  If a
                 * token is there NOW it was there while this thread slept: a
                 * wake the protocol owed and did not deliver.  `timed_out' is
                 * set ONLY by a real ETIMEDOUT, never by the shutdown exit --
                 * otherwise every run ends by counting its own teardown as a
                 * lost wakeup. */
                if (server_take())
                {
                    got = 1;
                    atomic_fetch_add_explicit( &srv_late, 1, memory_order_relaxed );
                }
            }
        }

        srvq[idx].queued = 0;
        srvq[idx].satisfied = 0;
        atomic_fetch_sub_explicit( (_Atomic int *)&cell.srv_waiters, 1, memory_order_seq_cst );
        pthread_mutex_unlock( &srv_mtx );

        if (got)
        {
            atomic_fetch_add_explicit( &consumed, 1, memory_order_relaxed );
            atomic_fetch_add_explicit( &srv_served, 1, memory_order_relaxed );
            if (atomic_fetch_sub_explicit( &work, 1, memory_order_seq_cst ) <= 0)
                atomic_fetch_add_explicit( &no_work, 1, memory_order_relaxed );
            /* REPORT THE JOB DONE, then take the return path back to the
             * wait.  The order of these two matters and is the realistic one:
             * a job system decrements its completion counter when the job
             * finishes and the worker then spends a little time getting back
             * to its wait.  It is also what gives the model the state the
             * Dekker pair exists for -- with the sleep BEFORE the decrement,
             * every worker is already re-queued by the time the producer
             * notices the batch is done, srv_waiters is never 0 at a release,
             * and a releaser notifies the server on every single release
             * whichever order it uses.  That is why an earlier version of this
             * control could not fail. */
            atomic_fetch_sub_explicit( &outstanding, 1, memory_order_seq_cst );
            usleep( 5 + ((unsigned)idx * 37u) % 120u );
        }
        else if (timed_out)
            atomic_fetch_add_explicit( &srv_timeouts, 1, memory_order_relaxed );
    }
    return NULL;
}

/* broken == 0 : the shipping ordering, which must never stall.
 * broken == 1 : the ml952-style ordering, which must stall -- the control that
 *               proves this liveness check can fail at all. */
static int check_server_stress( int broken )
{
    pthread_t th[SRV_RELEASERS + SRV_WAITERS];
    int i, n = 0;
    long left, w;
    unsigned long p, c, stalls;

    my_gen = 17u;
    srv_broken = broken;
    cell_init( my_gen, 0, SEM_MAX );
    atomic_store( &work, 0 ); atomic_store( &produced, 0 ); atomic_store( &consumed, 0 );
    atomic_store( &no_work, 0 ); atomic_store( &overflow_refused, 0 );
    atomic_store( &srv_served, 0 ); atomic_store( &srv_late, 0 );
    atomic_store( &srv_woken, 0 ); atomic_store( &srv_timeouts, 0 );
    atomic_store( &srv_requests, 0 ); atomic_store( &srv_stalls, 0 );
    atomic_store( &srv_stall_ms_max, 0 ); atomic_store( &outstanding, 0 );
    for (i = 0; i < SRV_WAITERS; i++)
    {
        pthread_cond_init( &srvq[i].cv, NULL );
        srvq[i].queued = srvq[i].satisfied = 0;
    }
    stop = 0;

    for (i = 0; i < SRV_RELEASERS; i++)
        pthread_create( &th[n++], NULL, srv_releaser, (void *)(uintptr_t)i );
    for (i = 0; i < SRV_WAITERS; i++)
        pthread_create( &th[n++], NULL, srv_waiter, (void *)(uintptr_t)i );

    usleep( SRV_RUN_MS * 1000 );
    stop = 1;
    for (i = 0; i < 400; i++)
    {
        int j;
        pthread_mutex_lock( &srv_mtx );
        for (j = 0; j < SRV_WAITERS; j++) pthread_cond_signal( &srvq[j].cv );
        pthread_mutex_unlock( &srv_mtx );
        usleep( 1000 );
    }
    for (i = 0; i < n; i++) pthread_join( th[i], NULL );

    left   = MADEIRA_SG_STATE( cell.sg );
    p      = atomic_load( &produced );
    c      = atomic_load( &consumed );
    w      = atomic_load( &work );
    stalls = atomic_load( &srv_stalls );

    printf( "MADEIRA-SEM[srv%s]: produced=%lu consumed=%lu left_in_cell=%ld "
            "srv_woken=%lu wake_requests=%lu timeouts=%lu late=%lu "
            "STALLS=%lu worst=%lums\n",
            broken ? ",WRONG-ORDER" : "", p, c, left,
            atomic_load( &srv_woken ), atomic_load( &srv_requests ),
            atomic_load( &srv_timeouts ), atomic_load( &srv_late ),
            stalls, atomic_load( &srv_stall_ms_max ) );

    /* Conservation holds in BOTH orderings: the wrong order DELAYS tokens, it
     * does not lose or duplicate them.  That is precisely why an accounting
     * test alone cannot see this bug and the liveness bound has to exist. */
    if ((unsigned long)left + c != p)
    {
        printf( "MADEIRA-SEM[srv]: FAIL - consumed+left=%lu but produced=%lu\n",
                (unsigned long)left + c, p );
        return 80;
    }
    if (atomic_load( &no_work ))
    {
        printf( "MADEIRA-SEM[srv]: FAIL - %lu waiters proceeded with no work behind the token\n",
                atomic_load( &no_work ) );
        return 81;
    }
    if (w != left)
    {
        printf( "MADEIRA-SEM[srv]: FAIL - ledger %ld but %ld tokens left in the cell\n", w, left );
        return 81;
    }
    if (cell.srv_waiters || cell.waiters)
    {
        printf( "MADEIRA-SEM[srv]: FAIL - waiters=%d srv_waiters=%d at rest\n",
                cell.waiters, cell.srv_waiters );
        return 82;
    }
    if (!p || !c || !atomic_load( &srv_woken ) || !atomic_load( &srv_requests ))
    {
        printf( "MADEIRA-SEM[srv]: FAIL - the stress did not reach the server wake path"
                " (produced=%lu consumed=%lu woken=%lu requests=%lu)\n",
                p, c, atomic_load( &srv_woken ), atomic_load( &srv_requests ) );
        return 83;
    }
    if (!broken && stalls)
    {
        printf( "MADEIRA-SEM[srv]: FAIL - %lu batches took longer than %ums to drain"
                " (worst %lums); a wakeup was lost\n",
                stalls, (unsigned)SRV_STALL_MS, atomic_load( &srv_stall_ms_max ) );
        return 84;
    }
    if (broken && !stalls)
    {
        printf( "MADEIRA-SEM[srv]: FAIL - the WRONG-ORDER control never stalled, so this"
                " liveness bound proves nothing about the right one\n" );
        return 85;
    }
    printf( "MADEIRA-SEM[srv%s]: conservation, ledger, waiter accounting and liveness OK\n",
            broken ? ",WRONG-ORDER (stalled as designed, self-heal recovered it)" : "" );
    return 0;
}

/* ========================================================================
 * ml1110: THE TIMEOUT / RE-QUEUE CASE -- thread_timeout() vs a client release
 * ========================================================================
 *
 * WHAT IS BEING MODELLED, AND WHY IT IS NOT THE CHECK ABOVE.
 * check_server_stress() models waiters on an INFINITE server wait: the only
 * thing that can end their wait is a wake.  Every hand-off in the device log
 * this round was written against is ALERTABLE, and an alertable wait on this
 * port is a chain of FINITE server waits -- the ml982/ml1060 heartbeat -- so
 * the server's `thread_timeout()' runs on the hand-off path thousands of times
 * a second.  Upstream that handler is allowed to end the wait without looking
 * at the objects, because on a server that owns all the state "the timer fired"
 * implies "nothing signalled it".  With a cell it does not: a client can CAS
 * the count up and still be on its way to the server with the
 * `release_semaphore( count = 0 )' that makes the server re-run its queue.
 *
 * The two orderings differ in ONE thing, inside the expiry handler:
 *   recheck == 1 (shipping)  check_wait() first -- an available token beats
 *                            the timer, which is the order every other entry
 *                            into check_wait() already uses.
 *   recheck == 0 (upstream)  end the wait, report STATUS_TIMEOUT, dequeue
 *                            (srv_waiters--), and let the client re-select.
 *
 * NOTHING IS LOST EITHER WAY -- the token stays in the cell and the re-select
 * collects it -- so, exactly as in check_server_stress(), conservation cannot
 * distinguish them and the assertion has to be about WHO delivered the
 * hand-off.  `late' counts hand-offs collected by the waiter's own re-select
 * after it had already been told TIMEOUT.  The shipping ordering must produce
 * none; the upstream ordering must produce some, or this check proves nothing.
 */

#define TQ_WAITERS      6
#define TQ_WAIT_MS      4         /* the finite timeout under test          */
#define TQ_RUN_MS    2000

struct tq_entry
{
    int queued;
    int satisfied;
    pthread_cond_t cv;
};

static struct tq_entry       tqq[TQ_WAITERS];
static pthread_mutex_t       tq_mtx = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned long tq_late, tq_direct, tq_timeouts, tq_rechecked;
static int                   tq_recheck;

/* wake_up( obj, 0 ) again, and it has to be the same walk: the caller holds
 * tq_mtx because the wineserver is one thread. */
static void tq_wake_up_unlimited( void )
{
    int again = 1;

    while (again)
    {
        int i;

        again = 0;
        for (i = 0; i < TQ_WAITERS; i++)
        {
            if (!tqq[i].queued || tqq[i].satisfied) continue;
            if (!server_take()) return;
            tqq[i].satisfied = 1;
            pthread_cond_signal( &tqq[i].cv );
            again = 1;
        }
    }
}

static void *tq_releaser( void *arg )
{
    unsigned int s = 9001 + (unsigned int)(uintptr_t)arg;

    while (!stop)
    {
        uint64_t sg;
        int cur, notify;

        /* NtReleaseSemaphore's client fast path, shipping ordering. */
        for (;;)
        {
            sg = atomic_load_explicit( (_Atomic uint64_t *)&cell.sg, memory_order_seq_cst );
            cur = MADEIRA_SG_STATE( sg );
            if ((unsigned int)cur + 1u > cell.smax) break;
            if (atomic_compare_exchange_strong_explicit(
                    (_Atomic uint64_t *)&cell.sg, &sg, MADEIRA_SG( my_gen, cur + 1 ),
                    memory_order_seq_cst, memory_order_seq_cst ))
            {
                atomic_fetch_add_explicit( &produced, 1, memory_order_relaxed );
                atomic_fetch_add_explicit( &work, 1, memory_order_seq_cst );
                break;
            }
        }
        notify = atomic_load_explicit( (_Atomic int *)&cell.srv_waiters,
                                       memory_order_seq_cst ) != 0;

        /* THE WINDOW UNDER TEST, and it is the real one: the request has been
         * decided on but has not reached the server yet, so a timer that is
         * already due fires first.  Widening it is the same discipline the
         * ordering test above uses -- the two runs differ in the handler and
         * in nothing else. */
        usleep( 1 + ((s = s * 1103515245u + 12345u) >> 20) % 6000u );

        if (notify)
        {
            pthread_mutex_lock( &tq_mtx );
            tq_wake_up_unlimited();
            pthread_mutex_unlock( &tq_mtx );
        }
    }
    return NULL;
}

static void *tq_waiter( void *arg )
{
    int idx = (int)(uintptr_t)arg;

    while (!stop)
    {
        int got = 0, timed_out = 0, late = 0;
        struct timespec ts;

        pthread_mutex_lock( &tq_mtx );
        atomic_fetch_add_explicit( (_Atomic int *)&cell.srv_waiters, 1, memory_order_seq_cst );
        tqq[idx].queued = 1;
        tqq[idx].satisfied = 0;
        if (server_take()) { tqq[idx].satisfied = 1; got = 1; }

        if (!got)
        {
            clock_gettime( CLOCK_REALTIME, &ts );
            ts.tv_sec  += (time_t)(TQ_WAIT_MS / 1000);
            ts.tv_nsec += (long)(TQ_WAIT_MS % 1000) * 1000000L;
            if (ts.tv_nsec >= 1000000000L) { ts.tv_nsec -= 1000000000L; ts.tv_sec++; }
            while (!tqq[idx].satisfied && !stop)
            {
                int r = pthread_cond_timedwait( &tqq[idx].cv, &tq_mtx, &ts );
                if (r == ETIMEDOUT) { timed_out = 1; break; }
                if (r && r != EINTR) break;
            }
            if (tqq[idx].satisfied) got = 1;
            else if (timed_out)
            {
                /* ===== thread_timeout(), the two orderings =====
                 *
                 * `owed' is the whole measurement and it is taken HERE, under
                 * the server lock, at the instant the handler runs -- not
                 * afterwards from the client's re-select, which would also
                 * catch tokens that legitimately arrived later and would make
                 * the check flap.  A token in the cell at this instant is one
                 * the client fast path put there before the timer fired, and
                 * reporting STATUS_TIMEOUT over it is the defect. */
                int st = MADEIRA_SG_STATE(
                             atomic_load_explicit( (_Atomic uint64_t *)&cell.sg,
                                                   memory_order_seq_cst ) );
                int owed = madeira_cell_signalled( MADEIRA_CELL_KIND_SEM, 0, st );

                if (tq_recheck && server_take())
                {
                    /* ml1110: check_wait() ran first and the token was there.
                     * The wait is SATISFIED; no STATUS_TIMEOUT is produced and
                     * the client never re-selects.  Nobody else can have taken
                     * that token between the load and here: the other waiters
                     * need this lock and a releaser only ever ADDS. */
                    tqq[idx].satisfied = 1;
                    got = 1;
                    timed_out = 0;
                    atomic_fetch_add_explicit( &tq_rechecked, 1, memory_order_relaxed );
                }
                else if (owed) late = 1;   /* told TIMEOUT over a live token */
            }
        }

        tqq[idx].queued = 0;
        tqq[idx].satisfied = 0;
        atomic_fetch_sub_explicit( (_Atomic int *)&cell.srv_waiters, 1, memory_order_seq_cst );
        pthread_mutex_unlock( &tq_mtx );

        if (late) atomic_fetch_add_explicit( &tq_late, 1, memory_order_relaxed );

        if (!got && timed_out)
        {
            /* The client got STATUS_TIMEOUT and re-selects at once, which is
             * what an alertable wait's heartbeat does.  Nothing is lost -- the
             * token is still in the cell -- but this whole round trip is the
             * cost the re-check removes. */
            atomic_fetch_add_explicit( &tq_timeouts, 1, memory_order_relaxed );
            pthread_mutex_lock( &tq_mtx );
            atomic_fetch_add_explicit( (_Atomic int *)&cell.srv_waiters, 1, memory_order_seq_cst );
            if (server_take()) got = 1;
            atomic_fetch_sub_explicit( (_Atomic int *)&cell.srv_waiters, 1, memory_order_seq_cst );
            pthread_mutex_unlock( &tq_mtx );
        }
        if (got)
        {
            atomic_fetch_add_explicit( &consumed, 1, memory_order_relaxed );
            if (atomic_fetch_sub_explicit( &work, 1, memory_order_seq_cst ) <= 0)
                atomic_fetch_add_explicit( &no_work, 1, memory_order_relaxed );
            atomic_fetch_add_explicit( &tq_direct, 1, memory_order_relaxed );
        }
    }
    return NULL;
}

static int check_timeout_requeue( int recheck )
{
    pthread_t th[1 + TQ_WAITERS];
    int i, n = 0;
    long left;
    unsigned long p, c, late;

    my_gen = 23u;
    tq_recheck = recheck;
    cell_init( my_gen, 0, SEM_MAX );
    atomic_store( &work, 0 ); atomic_store( &produced, 0 ); atomic_store( &consumed, 0 );
    atomic_store( &no_work, 0 );
    atomic_store( &tq_late, 0 ); atomic_store( &tq_direct, 0 );
    atomic_store( &tq_timeouts, 0 ); atomic_store( &tq_rechecked, 0 );
    for (i = 0; i < TQ_WAITERS; i++)
    {
        pthread_cond_init( &tqq[i].cv, NULL );
        tqq[i].queued = tqq[i].satisfied = 0;
    }
    stop = 0;

    pthread_create( &th[n++], NULL, tq_releaser, (void *)(uintptr_t)0 );
    for (i = 0; i < TQ_WAITERS; i++)
        pthread_create( &th[n++], NULL, tq_waiter, (void *)(uintptr_t)i );

    usleep( TQ_RUN_MS * 1000 );
    stop = 1;
    for (i = 0; i < 400; i++)
    {
        int j;
        pthread_mutex_lock( &tq_mtx );
        for (j = 0; j < TQ_WAITERS; j++) pthread_cond_signal( &tqq[j].cv );
        pthread_mutex_unlock( &tq_mtx );
        usleep( 1000 );
    }
    for (i = 0; i < n; i++) pthread_join( th[i], NULL );

    left = MADEIRA_SG_STATE( cell.sg );
    p    = atomic_load( &produced );
    c    = atomic_load( &consumed );
    late = atomic_load( &tq_late );

    printf( "MADEIRA-SEM[tmo,%s]: produced=%lu consumed=%lu left_in_cell=%ld "
            "delivered=%lu by_recheck=%lu reported_timeouts=%lu LATE=%lu\n",
            recheck ? "recheck" : "NO-RECHECK", p, c, left,
            atomic_load( &tq_direct ), atomic_load( &tq_rechecked ),
            atomic_load( &tq_timeouts ), late );

    if ((unsigned long)left + c != p)
    {
        printf( "MADEIRA-SEM[tmo]: FAIL - consumed+left=%lu but produced=%lu\n",
                (unsigned long)left + c, p );
        return 86;
    }
    if (atomic_load( &no_work ))
    {
        printf( "MADEIRA-SEM[tmo]: FAIL - %lu waiters proceeded with no work behind the token\n",
                atomic_load( &no_work ) );
        return 87;
    }
    if (cell.srv_waiters || cell.waiters)
    {
        printf( "MADEIRA-SEM[tmo]: FAIL - waiters=%d srv_waiters=%d at rest\n",
                cell.waiters, cell.srv_waiters );
        return 87;
    }
    if (!p || !c)
    {
        printf( "MADEIRA-SEM[tmo]: FAIL - the stress produced nothing (p=%lu c=%lu)\n", p, c );
        return 88;
    }
    if (recheck && late)
    {
        printf( "MADEIRA-SEM[tmo]: FAIL - %lu hand-offs were delivered by a timer although the"
                " expiry handler re-checked the objects first\n", late );
        return 89;
    }
    if (!recheck && !late)
    {
        printf( "MADEIRA-SEM[tmo]: FAIL - the NO-RECHECK control never delivered a hand-off by"
                " a timer, so this check proves nothing about the other ordering\n" );
        return 90;
    }
    printf( "MADEIRA-SEM[tmo,%s]: conservation, ledger and delivery-by-wake OK\n",
            recheck ? "recheck" : "NO-RECHECK (timer-delivered, as designed)" );
    return 0;
}

int main( void )
{
    int rc, pass;

    if ((rc = check_layout())) return rc;
    if ((rc = check_overflow())) return rc;
    if ((rc = check_generation())) return rc;
    /* three passes: the interleavings that matter here are timing-dependent
     * and a single 2.5 s window is one sample, not a result */
    for (pass = 0; pass < 3; pass++)
        if ((rc = check_stress())) return rc;

    /* ml1060: the device's actual shape -- every waiter on the SERVER path,
     * every releaser on the client fast path, bursts of 1..8 in one release.
     * Three passes of the shipping ordering (late must be 0), then ONE pass of
     * the wrong ordering, which must lose wakeups -- otherwise the liveness
     * assertion above is not testing anything. */
    for (pass = 0; pass < 3; pass++)
        if ((rc = check_server_stress( 0 ))) return rc;
    if ((rc = check_server_stress( 1 ))) return rc;

    /* ml1110: the expiry handler.  Three passes of the shipping ordering
     * (LATE must be 0), then ONE of upstream's, which must deliver hand-offs
     * by the timer -- otherwise the assertion above is decoration. */
    for (pass = 0; pass < 3; pass++)
        if ((rc = check_timeout_requeue( 1 ))) return rc;
    if ((rc = check_timeout_requeue( 0 ))) return rc;

    printf( "MADEIRA-SEM: all checks passed\n" );
    return 0;
}
