/* MADEIRA ml990: host model of the fastsync CELL protocol.
 *
 * This is not a model of the Win32 event surface (that is sync-x86.c + the
 * windows.h in this directory).  It models exactly the thing ml982 documented
 * as its residual and refused to default on because of:
 *
 *    "madeira_cell_alive() and the state CAS are not atomic with each other:
 *     between them the event can be destroyed and the cell re-allocated, and
 *     the CAS then touches a stranger's event."
 *
 * Both shapes are compiled from the SAME real header
 * (build/ntdll-unix/shims/ios_fastsync.h), so the packing, the accessors and
 * the sign handling under test are the shipping ones:
 *
 *   SPLIT  - ml982: a separate `gen' word, checked, then a 32-bit CAS on the
 *            state half.  Reproduced here over the packed word by checking the
 *            generation from one load and then CASing ONLY the low half.
 *   PACKED - ml990: one 64-bit load, and the generation carried into the CAS.
 *
 * A "theft" is a client that consumed a token out of a cell whose generation
 * was not the one it resolved.  The server side stamps every token it mints
 * with the epoch that minted it, so a theft is detected exactly, not inferred.
 *
 * Exit 0 = PACKED had zero thefts.  Anything else is a failure.
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ios_fastsync.h"

#define NCELLS      64
#define NCLIENTS     6
#define RUN_MS    2500

static struct madeira_sync_cell cells[NCELLS];

/* The server's private per-cell epoch, and the epoch that minted the token
 * currently in the cell.  Only the recycler thread writes `epoch'; `token_epoch'
 * is written by the setter half of the recycler and read by a consumer, so a
 * consumer can say which incarnation of the cell it just took a token from. */
static unsigned int epoch[NCELLS];
static _Atomic unsigned int token_epoch[NCELLS];

static volatile int stop;
static int use_packed;              /* 0 = ml982 SPLIT, 1 = ml990 PACKED   */
static int widen;                   /* insert the preemption being modelled */

static _Atomic unsigned long thefts, consumed, missed, recycles;

/* Model the preemption that makes the ml982 window reachable.  This is not a
 * cheat: it is one scheduler slice between two instructions that the ml982 code
 * genuinely does not hold anything across.  The PACKED shape gets exactly the
 * same delay in exactly the same place. */
static void preempt(void)
{
    if (widen) sched_yield();
}

/* ---- the CLIENT's "take the auto-reset token" -------------------------- */

static int client_try( struct madeira_sync_cell *cell, unsigned int gen, unsigned int *got_epoch )
{
    int idx = (int)(cell - cells);

    if (use_packed)
    {
        /* ml990, verbatim in shape with madeira_fast_try() in sync.c */
        uint64_t sg = atomic_load_explicit( (_Atomic uint64_t *)&cell->sg, memory_order_seq_cst );

        if (MADEIRA_SG_GEN( sg ) != gen) return 0;
        if (MADEIRA_SG_STATE( sg ) != MADEIRA_CELL_SET) return 0;
        preempt();
        *got_epoch = atomic_load_explicit( &token_epoch[idx], memory_order_seq_cst );
        return atomic_compare_exchange_strong_explicit(
            (_Atomic uint64_t *)&cell->sg, &sg, MADEIRA_SG( gen, MADEIRA_CELL_RESET ),
            memory_order_seq_cst, memory_order_seq_cst );
    }
    else
    {
        /* ml982: madeira_cell_alive() first ... */
        uint64_t sg = atomic_load_explicit( (_Atomic uint64_t *)&cell->sg, memory_order_seq_cst );
        int st;

        if (MADEIRA_SG_GEN( sg ) != gen) return 0;
        st = MADEIRA_SG_STATE( sg );
        if (st != MADEIRA_CELL_SET) return 0;
        preempt();                       /* ... and the gap it leaves open ... */
        *got_epoch = atomic_load_explicit( &token_epoch[idx], memory_order_seq_cst );
        /* ... then a CAS that compares the STATE ONLY. */
        {
            _Atomic int *lo = (_Atomic int *)madeira_cell_futex( cell );
            int want = MADEIRA_CELL_SET;
            return atomic_compare_exchange_strong_explicit(
                lo, &want, MADEIRA_CELL_RESET, memory_order_seq_cst, memory_order_seq_cst );
        }
    }
}

/* ---- the SERVER: alloc / free / mint ----------------------------------- */

static void srv_alloc( int i, int signaled )
{
    unsigned int g = MADEIRA_SG_GEN( cells[i].sg );

    if (!++g) g = 1;
    epoch[i] = g;
    cells[i].manual = 0;
    atomic_store_explicit( &token_epoch[i], g, memory_order_seq_cst );
    atomic_store_explicit( (_Atomic uint64_t *)&cells[i].sg,
                           MADEIRA_SG( g, signaled ? MADEIRA_CELL_SET : MADEIRA_CELL_RESET ),
                           memory_order_seq_cst );
}

static void srv_free( int i )
{
    unsigned int g = MADEIRA_SG_GEN( cells[i].sg );

    if (!++g) g = 1;
    epoch[i] = g;
    atomic_store_explicit( (_Atomic uint64_t *)&cells[i].sg,
                           MADEIRA_SG( g, MADEIRA_CELL_DISABLED ), memory_order_seq_cst );
}

/* Mint a token into a live cell, stamped with the cell's current epoch. */
static void srv_set( int i )
{
    uint64_t sg = atomic_load_explicit( (_Atomic uint64_t *)&cells[i].sg, memory_order_seq_cst );

    if (MADEIRA_SG_STATE( sg ) == MADEIRA_CELL_DISABLED) return;
    atomic_store_explicit( &token_epoch[i], MADEIRA_SG_GEN( sg ), memory_order_seq_cst );
    atomic_store_explicit( (_Atomic uint64_t *)&cells[i].sg,
                           MADEIRA_SG( MADEIRA_SG_GEN( sg ), MADEIRA_CELL_SET ),
                           memory_order_seq_cst );
}

/* The recycler: destroy-and-recreate the event behind a cell, continuously.
 * That is what a loader, a thread pool or any program that creates and closes
 * events thousands of times a second does to this table. */
static void *recycler( void *arg )
{
    unsigned int s = 12345 + (unsigned int)(uintptr_t)arg;

    while (!stop)
    {
        int i = (int)((s = s * 1103515245u + 12345u) % (unsigned int)NCELLS);

        srv_set( i );                 /* a token for whoever is waiting  */
        sched_yield();
        srv_free( i );                /* last handle closed              */
        srv_alloc( i, 1 );            /* and the cell handed to a NEW event,
                                       * already signalled -- the stranger   */
        atomic_fetch_add_explicit( &recycles, 1, memory_order_relaxed );
    }
    return NULL;
}

/* A client that resolved (idx, gen) and then goes to take the token. */
static void *client( void *arg )
{
    unsigned int s = 999 + (unsigned int)(uintptr_t)arg;

    while (!stop)
    {
        int i = (int)((s = s * 1103515245u + 12345u) % (unsigned int)NCELLS);
        uint64_t sg = atomic_load_explicit( (_Atomic uint64_t *)&cells[i].sg, memory_order_seq_cst );
        unsigned int gen = MADEIRA_SG_GEN( sg );
        unsigned int got = 0;

        if (!gen) continue;
        if (client_try( &cells[i], gen, &got ))
        {
            atomic_fetch_add_explicit( &consumed, 1, memory_order_relaxed );
            /* The token we just consumed was minted by epoch `got'.  We
             * believed we were operating on epoch `gen'.  If they differ we
             * have taken a token out of an event we never waited on. */
            if (got != gen) atomic_fetch_add_explicit( &thefts, 1, memory_order_relaxed );
        }
        else atomic_fetch_add_explicit( &missed, 1, memory_order_relaxed );
    }
    return NULL;
}

static unsigned long run( int packed, int widen_gap, const char *name )
{
    pthread_t th[NCLIENTS + 1];
    int i;
    unsigned long t;

    memset( cells, 0, sizeof(cells) );
    memset( epoch, 0, sizeof(epoch) );
    for (i = 0; i < NCELLS; i++) atomic_store( &token_epoch[i], 0 );
    for (i = 0; i < NCELLS; i++) srv_alloc( i, 0 );
    atomic_store( &thefts, 0 ); atomic_store( &consumed, 0 );
    atomic_store( &missed, 0 ); atomic_store( &recycles, 0 );
    use_packed = packed; widen = widen_gap; stop = 0;

    pthread_create( &th[0], NULL, recycler, (void *)0 );
    for (i = 0; i < NCLIENTS; i++)
        pthread_create( &th[i + 1], NULL, client, (void *)(uintptr_t)(i + 1) );
    usleep( RUN_MS * 1000 );
    stop = 1;
    for (i = 0; i < NCLIENTS + 1; i++) pthread_join( th[i], NULL );

    t = atomic_load( &thefts );
    printf( "MADEIRA-CELL: %-28s consumed=%-9lu missed=%-9lu recycles=%-8lu THEFTS=%lu\n",
            name, atomic_load( &consumed ), atomic_load( &missed ),
            atomic_load( &recycles ), t );
    return t;
}

int main( void )
{
    unsigned long split_w, packed_w, packed_n;

    printf( "MADEIRA-CELL: sizeof(struct madeira_sync_cell)=%zu (must be 32)\n",
            sizeof(struct madeira_sync_cell) );
    if (sizeof(struct madeira_sync_cell) != 32) return 70;

    /* The futex address must be the STATE half, i.e. offset 0 of sg. */
    {
        struct madeira_sync_cell c;
        c.sg = MADEIRA_SG( 0xAABBCCDDu, MADEIRA_CELL_DISABLED );
        if (*madeira_cell_futex( &c ) != MADEIRA_CELL_DISABLED)
        {
            printf( "MADEIRA-CELL: futex half is not the state half\n" );
            return 71;
        }
        if (MADEIRA_SG_GEN( c.sg ) != 0xAABBCCDDu ||
            MADEIRA_SG_STATE( c.sg ) != MADEIRA_CELL_DISABLED)
        {
            printf( "MADEIRA-CELL: pack/unpack round trip failed\n" );
            return 72;
        }
    }

    split_w  = run( 0, 1, "ml982 SPLIT  (gap widened)" );
    packed_w = run( 1, 1, "ml990 PACKED (gap widened)" );
    packed_n = run( 1, 0, "ml990 PACKED (no widening)" );

    if (packed_w || packed_n)
    {
        printf( "MADEIRA-CELL: FAIL - the packed word stole a token\n" );
        return 73;
    }
    if (!split_w)
        printf( "MADEIRA-CELL: NOTE - the split shape did not lose a race in this run;"
                " the packed result still stands, it is just not a contrast\n" );
    else
        printf( "MADEIRA-CELL: the split shape stole %lu tokens; the packed shape stole none\n",
                split_w );
    printf( "MADEIRA-CELL: all checks passed\n" );
    return 0;
}
