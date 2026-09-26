/*
 * iOS-Madeira ml952: in-process fast sync ("fastsync") cell table.
 *
 * WHY THIS EXISTS
 * ---------------
 * On this target the wineserver is a THREAD in the same Mach task as every
 * guest thread, so a "server round trip" is a socket write, a scheduler hop,
 * the server's main loop, a socket write back and a second scheduler hop —
 * measured at ~50 us per request in [srv-stats].  Log 41 showed the 32-bit
 * title paying that 2900 times a second for event_op (SetEvent/ResetEvent)
 * and 900 times a second for a single-object infinite wait, all of it between
 * the game's main thread and its render/worker threads: ~150 us of latency on
 * every handoff between the two threads that pace the frame.
 *
 * Upstream Wine already has the shape of the answer: dlls/ntdll/unix/sync.c's
 * inproc_set_event()/inproc_wait() hooks, which on Linux hand the operation to
 * /dev/ntsync and never reach the server.  Those hooks are dead here
 * (inproc_device_fd < 0, there is no ntsync on iOS).  This header is the iOS
 * substitute for the ntsync object: a plain array of cells in the ONE address
 * space that the server and every guest thread share, with the same wake
 * primitive (os_sync_wait_on_address / __ulock_wait) already used by
 * NtWaitForAlertByThreadId.
 *
 * WHO OWNS WHAT
 * -------------
 * The table is DEFINED once, by the server (wine/server/event.c), and
 * referenced by the client (wine/dlls/ntdll/unix/sync.c).  Both archives are
 * linked into the one iOS image, so this is a plain cross-archive symbol
 * reference, exactly like the user_shared_data / shared_session globals the
 * wineserver build script already has to reason about.
 *
 * Cell allocation and freeing are SERVER-ONLY and happen on the server thread
 * (create_event / event destroy), so they need no lock.  Everything a client
 * touches is an atomic on one of the four words below.
 *
 * THE STATE WORD IS THE SINGLE SOURCE OF TRUTH
 * --------------------------------------------
 * For an event that owns a cell, the cell's STATE half — not the server's
 * `event_sync.signaled` bit — is what event_sync_signaled() reads and what
 * event_sync_satisfied() clears.  There is exactly one place the two can
 * disagree, and it is deliberate: MADEIRA_CELL_DISABLED (see below).
 *
 *   MADEIRA_CELL_RESET     (0)  not signaled.  Also the futex sleep value:
 *                               a parked client waits for this word to stop
 *                               being 0.
 *   MADEIRA_CELL_SET       (1)  signaled, and the token is up for grabs.
 *   MADEIRA_CELL_CLAIMED   (2)  signaled, but the SERVER has already decided
 *                               (inside event_sync_signaled) to hand this
 *                               auto-reset token to one of its own queued
 *                               waiters.  Clients must not consume it.  This
 *                               value only ever exists between check_wait()
 *                               and end_wait() on the server thread, i.e. for
 *                               a few hundred nanoseconds with no client
 *                               server-call in between.  It exists because
 *                               `satisfied' has no return value: without the
 *                               claim, a client CAS could steal the token
 *                               after the server's `signaled' said yes, and
 *                               the server would report WAIT_0 to a thread
 *                               that never acquired the event.
 *   MADEIRA_CELL_DISABLED (-1)  this event has left the fast path for good.
 *                               Set by the first NtPulseEvent on the object
 *                               (PulseEvent's "release whoever is waiting at
 *                               this instant and then immediately clear"
 *                               cannot be expressed on a futex word without
 *                               losing or duplicating wakeups), and by
 *                               madeira_cell_free().  While DISABLED the
 *                               server falls back to its own `signaled' bit
 *                               and clients always call the server, so the
 *                               object behaves exactly as it did before this
 *                               change.
 *
 * THE TWO DEKKER PAIRINGS
 * -----------------------
 * (1) client setter vs. SERVER waiter.  A server-side waiter must not sleep
 *     through a set that a client performed with no server call, and a client
 *     must not skip the server call while the server has someone queued.
 *
 *       client NtSetEvent:  store state = SET   (seq_cst)
 *                           load  srv_waiters   (seq_cst)  -> if != 0, ALSO
 *                                                             do the event_op
 *                                                             request so the
 *                                                             server wakes its
 *                                                             own queue
 *       server wait_on():   add   srv_waiters++ (seq_cst)   [event_sync_add_queue]
 *                           load  state         (seq_cst)   [event_sync_signaled,
 *                                                             from check_wait,
 *                                                             which always runs
 *                                                             after wait_on]
 *
 *     Two threads, each storing its own flag with seq_cst and then loading the
 *     other's with seq_cst: on a total order at least one of the two loads is
 *     ordered after the other's store, so they cannot both miss.  Worst case
 *     BOTH see the other and the set is delivered twice — harmless, the second
 *     delivery is an idempotent store plus a wake_up() over an empty queue.
 *
 * (2) client setter vs. CLIENT waiter.  Same shape, with `waiters' in place of
 *     `srv_waiters':
 *
 *       client setter:      store state = SET   (seq_cst)
 *                           load  waiters       (seq_cst) -> if != 0, wake
 *       client waiter:      add   waiters++     (seq_cst)
 *                           load  state         (seq_cst) -> if SET, consume
 *                                                            and never park
 *
 *     and the park itself re-checks: os_sync_wait_on_address is given the
 *     value the waiter last observed, so a set landing between the load and
 *     the syscall makes the syscall return immediately rather than sleep.
 *
 * GENERATION -- ml990: PACKED INTO THE STATE WORD, NOT BESIDE IT
 * --------------------------------------------------------------
 * `gen' is bumped on every allocation AND every free, so a client that cached
 * (index, gen) for a handle can detect that the cell has been recycled under
 * it and fall back to the server.  A live handle pins the event, and the event
 * pins the cell, so this only ever fires for the documented-undefined case of
 * operating on an already-closed handle.
 *
 * Through ml982 `gen' was a SEPARATE word, which made "is this still my cell"
 * (a load of gen) and "take the token" (a CAS on state) two operations with a
 * gap between them:
 *
 *      client                                server
 *      ------                                ------
 *      load gen        -> G, matches
 *                                            destroy event: state=DISABLED, gen=G+1
 *                                            create event:  gen=G+2, state=SET
 *      CAS state SET->RESET  SUCCEEDS  <---- and this token belongs to an event
 *                                            this thread never waited on
 *
 * i.e. a lost wakeup on an unrelated object.  ml982 documented it as a
 * residual and kept the wake path off by default because of it.
 *
 * ml990 removes the gap rather than narrowing it: the generation and the state
 * live in ONE 64-bit word, `sg', so the CAS that takes a token also validates
 * the generation.  There is no interleaving in which a CAS can succeed against
 * a cell that changed hands since the load, because a change of hands IS a
 * change of the word the CAS compares.
 *
 *      bits 63..32   gen   (never 0 for an allocated cell; 0 = never allocated)
 *      bits 31..0    state (MADEIRA_CELL_*, read back as a SIGNED int)
 *
 * THE FUTEX STILL WAITS ON THE LOW HALF.  madeira_cell_futex() hands back the
 * address of the state half -- which on this little-endian target is the
 * address of `sg' itself -- so os_sync_wait_on_address/__ulock_wait keep
 * comparing 4 bytes and a park is still "sleep while state == RESET".  That
 * matters in both directions: a pure generation bump must not wake a parked
 * waiter spuriously, and every recycle changes the LOW half too (a free stores
 * DISABLED with the bump in the same store), so no recycle can be missed.
 *
 * EVERY access to the pair is a 64-bit atomic on both sides.  A 32-bit store
 * to the low half would be architecturally fine on ARM64 but is a mixed-size
 * data race in the C memory model, so the server rebuilds the whole word from
 * the generation it read in the same load.  That read-modify-write is not
 * atomic against a client CAS, and does not need to be: it is exactly as
 * unconditional as the plain `state = RESET' store it replaces, and the server
 * is the only writer of `gen' and runs on one thread, so the generation it
 * reads cannot go stale under it.
 *
 * ml982: THE FOUR MODES OF MADEIRA_FASTSYNC
 * -----------------------------------------
 * The one env var now selects four points on a ladder, because the two halves
 * of this mechanism have very different risk profiles and only the cheap half
 * is worth having on by default:
 *
 *   "0" / "off" / "no"   NOTHING.  madeira_cell_alloc() answers -1 for every
 *                        event, so event->signaled is the state again and this
 *                        table is never touched by either side.  Byte for byte
 *                        the pre-ml952 server and client.
 *   unset                CELLS ONLY.  The server keeps each event's state in
 *                        its cell -- which is a pure relocation of one bit,
 *                        since with no client participation signaled()/
 *                        satisfied()/signal() read and write the cell exactly
 *                        where they used to read and write `signaled' -- and
 *                        the client uses it for ONE read-only thing: answering
 *                        a zero-timeout wait that the word says is NOT
 *                        signaled (MADEIRA_FS_POLLPEEK).  No wake semantics,
 *                        no token can be consumed or minted off-server, so
 *                        there is no lost- or double-wakeup to get wrong.
 *   "auto" (the DEFAULT) CELLS + the client wake path, armed only once the
 *                        task's own [srv-stats] window shows more event/select
 *                        traffic than MADEIRA_FS_AUTO_REQS (20000 per 10 s).
 *                        A quiet process (a launcher, a helper) never arms.
 *   "1" / "on"           CELLS + the client wake path from the first call.
 *
 * The client half is what NtSetEvent/NtResetEvent/NtWaitForSingleObject route
 * through; the server half is unconditional above "off".
 *
 * ml1010: SEMAPHORES USE THE SAME CELL, WITH THE COUNT IN THE STATE HALF
 * ---------------------------------------------------------------------
 * The measurement that motivated this: a title whose job system is driven by
 * semaphores spent `release_semaphore=76091 select=308752 per 10 s` and ~60 %
 * of ALL CPU in wineserver pipe I/O, with fastsync armed but inert because it
 * only knew events.  The shape is identical to the event handshake -- a
 * producer hands a token to one of N worker threads inside ONE Mach task --
 * so it gets the identical mechanism, not an approximation of it.
 *
 *   cell->kind   MADEIRA_CELL_KIND_SEM
 *   state half   the CURRENT COUNT, 0..max, as a non-negative int.
 *                MADEIRA_CELL_RESET (0) is "empty", which is also the futex
 *                sleep value, exactly as for an event.
 *                MADEIRA_CELL_DISABLED (-1) is the same one-way exit.
 *                MADEIRA_CELL_SET/_CLAIMED have NO meaning here: 1 and 2 are
 *                counts.  Every reader therefore branches on `kind' FIRST.
 *   cell->smax   the maximum, which is immutable for the life of the object
 *                and so needs no atomicity: it is written before the store of
 *                `sg' that publishes the cell and read only after a load of
 *                `sg' that matched the caller's generation.
 *
 * max <= 0x7fffffff (create_semaphore rejects more), so count + n can be
 * checked for overflow entirely inside the signed 32-bit state half.
 *
 * WHAT MAKES THE ACCOUNTING EXACT.  Every token transfer is a CAS on the ONE
 * packed word: a release CASes count -> count+n, a consumer CASes count ->
 * count-1, and both carry the generation.  So the count is a linearizable
 * counter, a consumer returns success only when its own CAS removed exactly
 * one token, and a failed CAS retries rather than losing one.  A waiter that
 * times out has by construction performed NO successful CAS, so it cannot be
 * holding a token it then drops; a waiter that performed one returns SUCCESS
 * immediately and can never report a timeout.
 *
 * THE MIXED-WAITER PROBLEM IS THE EVENT PROBLEM.  Both Dekker pairings are
 * reused verbatim with `count > 0' in place of `state == SET':
 *   client releaser:  CAS count+=n (seq_cst); load waiters (seq_cst) -> wake
 *                     ...              ; load srv_waiters (seq_cst) -> tell
 *                                        the server to re-run its own queue
 *   client waiter:    waiters++   (seq_cst); load count (seq_cst)
 *   server wait_on(): srv_waiters++(seq_cst); load count (seq_cst)  [signaled]
 *
 * and the "tell the server" request needs NO new opcode, because
 * `release_semaphore' with count == 0 already IS "change nothing, then run
 * wake_up( obj, 0 )", i.e. let every queued thread re-evaluate.  The server's
 * semaphore_sync_signaled() then CAS-claims a token out of the same word, so
 * a token a fast waiter already took simply makes that CAS fail and the queued
 * thread stays queued: one release, one release, never two.
 *
 * WAKING n WAITERS.  os_sync_wake_by_address has no "wake exactly n", so a
 * release of 1 wakes one and a release of n > 1 wakes ALL.  Over-waking is
 * safe in the direction that matters: every woken waiter re-runs the CAS and
 * re-parks if it loses, and the tokens it cannot take stay in the cell.
 *
 * MADEIRA_FASTSYNC_SEM=0 turns THIS path off and leaves events alone: the
 * server then allocates no cell for a semaphore and the client never learns
 * one, so semaphores behave exactly as they did before ml1010.
 *
 * ml990 MOVES THE DEFAULT FROM "unset = cells only" TO "auto".  The two
 * reasons ml982 gave for not doing so are both gone: (1) the lost-wakeup
 * vector was the split gen/state pair, which the packing above makes
 * unrepresentable; (2) "nothing has ever executed on a device" -- log y104 ran
 * the whole mechanism with MADEIRA_FASTSYNC=auto through a 32-bit job-system
 * title, armed it (`[fastsync] AUTO-ENABLED after 181468 event/select ops`),
 * and reported desync=0, stale_gen=0 and relearn=0 in every window while total
 * server traffic fell from 15296/s to ~5200/s.  MADEIRA_FASTSYNC=0 still
 * forces the whole thing off, cells included.
 */

#ifndef __IOS_FASTSYNC_H
#define __IOS_FASTSYNC_H

#include <stdint.h>

/* 8192 cells x 32 bytes = 256 KB of BSS, demand-zero, only the touched pages
 * are ever committed.  A running 32-bit title has a few hundred events; the
 * allocator simply hands back "no cell" past the end and those events keep the
 * pre-fastsync behaviour, so the size is a tuning constant, not a limit. */
#define MADEIRA_SYNC_CELLS      8192

#define MADEIRA_CELL_DISABLED   (-1)
#define MADEIRA_CELL_RESET      0
#define MADEIRA_CELL_SET        1
#define MADEIRA_CELL_CLAIMED    2

/* ml1010: which object owns this cell.  EVENT is 0 so that a zero-initialised
 * cell and every pre-ml1010 reading of the table mean exactly what they used
 * to.  The value is immutable for the life of a generation, so a reader that
 * has matched the generation has by construction read the right kind. */
#define MADEIRA_CELL_KIND_EVENT 0
#define MADEIRA_CELL_KIND_SEM   1

/* ml990: the packed {gen, state} word.  `state' is stored as the low 32 bits
 * and read back SIGNED, so MADEIRA_CELL_DISABLED survives the round trip. */
#define MADEIRA_SG(gen, state)  (((uint64_t)(unsigned int)(gen) << 32) | \
                                 (uint64_t)(uint32_t)(int32_t)(state))
#define MADEIRA_SG_GEN(sg)      ((unsigned int)((uint64_t)(sg) >> 32))
#define MADEIRA_SG_STATE(sg)    ((int)(int32_t)(uint32_t)(uint64_t)(sg))

struct madeira_sync_cell
{
    uint64_t     sg;           /* ml990 PACKED {gen:63..32, state:31..0}         */
    int          srv_waiters;  /* server wait_queue entries on this object       */
    int          waiters;      /* client threads parked on the state half        */
    unsigned int manual;       /* 1 = manual-reset (NotificationEvent), events   */
    unsigned int kind;         /* ml1010 MADEIRA_CELL_KIND_*                     */
    unsigned int smax;         /* ml1010 semaphore maximum count, immutable      */
    unsigned int rel_us;       /* ml1110 CLIENT release stamp, see below         */
};

/* ml1110: WHEN THE LAST CLIENT-SIDE RELEASE RAISED THIS CELL.
 *
 * Truncated CLOCK_UPTIME_RAW microseconds, written relaxed by the two client
 * fast paths that can raise a cell without the server knowing -- the
 * NtReleaseSemaphore arithmetic and NtSetEvent -- and read by nothing on the
 * hot path.  It exists for ONE question, which no counter in this port could
 * answer: a timed wait that ended in STATUS_TIMEOUT while its object was
 * already signalled is either a genuine race (the token landed a microsecond
 * ago and the wake is in flight) or a wake that was owed and not delivered,
 * and the only thing that separates them is HOW LONG the token had been
 * sitting there.  Truncation to 32 bits wraps every ~71 minutes; the only
 * consumer subtracts two stamps taken within milliseconds of each other and
 * unsigned arithmetic makes the wrap invisible to it.
 *
 * SERVER-SIDE releases are deliberately NOT stamped.  A release that runs on
 * the server thread walks its own wait queue in the same call, so it cannot be
 * late by construction, and a stamp from it would only dilute the measurement
 * of the mixed protocol this is aimed at.  A cell that has never been raised
 * by a client keeps rel_us == 0, which the reader reports as "no stamp"
 * rather than as an age of 71 minutes.
 *
 * Relaxed on both sides on purpose: it is a diagnostic, it is never read to
 * decide anything, and a torn or stale value costs one mis-bucketed age. */
static inline void madeira_cell_note_release( struct madeira_sync_cell *cell,
                                              unsigned long long now_ns )
{
    unsigned int us = (unsigned int)(now_ns / 1000);

    __atomic_store_n( &cell->rel_us, us ? us : 1u, __ATOMIC_RELAXED );
}

/* The kind, read without synchronisation on purpose.  It is written once, by
 * the server, BEFORE the store of `sg' that publishes the cell, and every
 * operation that acts on it re-validates the generation in the same atomic
 * that performs the operation -- so a kind read from a cell that has since
 * changed hands can only ever lead to a CAS that fails. */
static inline unsigned int madeira_cell_kind( const struct madeira_sync_cell *cell )
{
    return __atomic_load_n( &cell->kind, __ATOMIC_RELAXED );
}

/* ml1060: "does this cell say a waiter could be released RIGHT NOW?", written
 * once so that the client watchdog, the server-side lost-wakeup detector and
 * the host models cannot drift apart on it.
 *
 *   semaphore      count > 0                      (DISABLED is -1, so excluded)
 *   manual event   state > 0                      (SET; DISABLED excluded)
 *   auto event     state == MADEIRA_CELL_SET only -- CLAIMED (2) means the
 *                  server is handing this token to one of its own queued
 *                  threads at this instant, which resolves in nanoseconds on
 *                  the server thread and is nobody's hang.
 *
 * `state' must come out of a load whose generation the caller has already
 * matched; this function does no validation of its own on purpose, because the
 * only correct place for that is the same atomic that read the state. */
static inline int madeira_cell_signalled( unsigned int kind, unsigned int manual, int state )
{
    if (kind == MADEIRA_CELL_KIND_SEM) return state > 0;
    if (manual) return state > 0;
    return state == MADEIRA_CELL_SET;
}

/* The futex address: the STATE half of `sg'.  Both sides must use this and
 * only this, or a client parked by one could never be woken by the other. */
#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__) && \
    __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "madeira_cell_futex() assumes the low half of sg lives at offset 0"
#endif
static inline int *madeira_cell_futex( struct madeira_sync_cell *cell )
{
    return (int *)&cell->sg;
}

extern struct madeira_sync_cell madeira_sync_cells[MADEIRA_SYNC_CELLS];

/* Packing of the get_inproc_sync_fd reply.  `type' is an int carrying a small
 * enum inproc_sync_type on every other target; bit 30 is free there and says
 * "this is a Madeira cell reply, there is no fd in flight".  24 bits of index
 * covers MADEIRA_SYNC_CELLS with room to spare. */
#define MADEIRA_FAST_REPLY_FLAG    0x40000000
#define MADEIRA_FAST_REPLY_MANUAL  0x20000000
#define MADEIRA_FAST_REPLY_IDX(t)  ((t) & 0x00ffffff)

/* ml962: the `event_op' opcode that means "WAKE YOUR QUEUE, DO NOT SIGNAL".
 *
 * A client NtSetEvent that finds srv_waiters != 0 has ALREADY published the
 * new state in the cell; all that is left for the server is to let the threads
 * sitting in its own wait queue re-evaluate that word.  It must NOT signal the
 * event a second time: between the client's CAS and the server picking the
 * request up, another client can legitimately consume the auto-reset token on
 * the fast path, and a server-side SET_EVENT on top of that mints a SECOND
 * token out of ONE SetEvent and releases two waiters.  That was the ml952
 * double-release bug (WOW64_DESIGN.md section 6, ml962 entry).
 *
 * `op' is a plain int in struct event_op_request and the server's switch has a
 * `default: STATUS_INVALID_PARAMETER' arm, so an out-of-enum value is a safe
 * private extension with no protocol.def change: only the iOS client ever
 * sends it and only the iOS server ever accepts it. */
#define MADEIRA_EVENT_OP_WAKE      0x4d415741   /* 'MAWA' */

/* ml982: "TAKE THIS OBJECT OUT OF THE FAST PATH, PERMANENTLY."
 *
 * The self-heal half of the watchdog in ntdll/unix/sync.c.  When a client that
 * has been waiting on an object finds the server saying "not signaled" while
 * the shared word says SET -- the only shape of incoherence either side can
 * actually observe -- it sends this, and the server runs exactly the code path
 * a PulseEvent runs: event_sync_disable_cell(), which folds the cell's state
 * back into `signaled', stores MADEIRA_CELL_DISABLED and wakes every parked
 * client so they re-read it and go to the server.  From then on that ONE event
 * behaves as it did before ml952 and every other event is untouched.
 *
 * A hang therefore degrades to a logged hiccup plus one permanently slower
 * event, which is the direction this whole mechanism is supposed to fail in.
 *
 * Unlike the other opcodes this one is accepted on a SYNCHRONIZE handle: the
 * thread that notices the incoherence is a WAITER, and a waiter is not
 * required to hold EVENT_MODIFY_STATE.  It changes no observable event state
 * (disable_cell copies the cell word into `signaled' and leaves it there), so
 * it is not a state modification in the sense EVENT_MODIFY_STATE guards. */
#define MADEIRA_EVENT_OP_DISABLE   0x4d414449   /* 'MADI' */

/* ml1010: the same self-heal for a SEMAPHORE, sent through the same `event_op'
 * request because that request is the only one in the protocol with a spare
 * opcode space and a `default: STATUS_INVALID_PARAMETER' arm.  It is answered
 * before event_op's own get_event_obj(), because the handle it carries is a
 * semaphore handle and would fail that object-type check.
 *
 * There is deliberately no semaphore analogue of MADEIRA_EVENT_OP_WAKE: the
 * "wake your queue and change nothing" request for a semaphore already exists
 * as `release_semaphore' with count == 0, which upstream implements as exactly
 * that (no state change, then wake_up( obj, 0 ), and 0 means "no limit"). */
#define MADEIRA_SEM_OP_DISABLE     0x4d414453   /* 'MADS' */

/* ------------------------------------------------------------------------
 * The wake primitive, shared verbatim by both sides.
 *
 * This is the same ladder dlls/ntdll/unix/sync.c uses for the alert futex
 * (os_sync_wait_on_address on 14.4+/iOS 17.4+, __ulock_wait below that),
 * lifted into a header so the SERVER can issue exactly the same wake a client
 * setter would.  If the two sides used different primitives a client parked by
 * one could never be woken by the other.
 * ------------------------------------------------------------------------ */

#ifdef __APPLE__

#include <AvailabilityMacros.h>
#ifdef MAC_OS_VERSION_14_4
#include <os/os_sync_wait_on_address.h>
#endif

#ifndef UL_COMPARE_AND_WAIT
#define UL_COMPARE_AND_WAIT 1
#endif
#ifndef ULF_WAKE_ALL
#define ULF_WAKE_ALL 0x00000100
#endif

extern int __ulock_wait( uint32_t operation, void *addr, uint64_t value, uint32_t timeout );
extern int __ulock_wake( uint32_t operation, void *addr, uint64_t wake_value );

/* Park on *addr while it still reads `val', for at most ns_timeout
 * nanoseconds (0 = forever, which this file never asks for).  Returns
 * immediately if the word already changed. */
static inline void madeira_fast_park( const int *addr, int val, uint64_t ns_timeout )
{
#ifdef MAC_OS_VERSION_14_4
    if (__builtin_available( macOS 14.4, iOS 17.4, * ))
    {
        if (ns_timeout)
            os_sync_wait_on_address_with_timeout( (void *)addr, (uint64_t)(uint32_t)val, 4,
                                                  OS_SYNC_WAIT_ON_ADDRESS_NONE,
                                                  OS_CLOCK_MACH_ABSOLUTE_TIME, ns_timeout );
        else
            os_sync_wait_on_address( (void *)addr, (uint64_t)(uint32_t)val, 4,
                                     OS_SYNC_WAIT_ON_ADDRESS_NONE );
        return;
    }
#endif
    {
        uint32_t us = (uint32_t)(ns_timeout / 1000);
        if (ns_timeout && !us) us = 1;
        __ulock_wait( UL_COMPARE_AND_WAIT, (void *)addr, (uint64_t)(uint32_t)val, us );
    }
}

/* Wake one parked thread, or all of them for a manual-reset event (where a
 * single set releases every waiter). */
static inline void madeira_fast_wake( const int *addr, int all )
{
#ifdef MAC_OS_VERSION_14_4
    if (__builtin_available( macOS 14.4, iOS 17.4, * ))
    {
        if (all) os_sync_wake_by_address_all( (void *)addr, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE );
        else     os_sync_wake_by_address_any( (void *)addr, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE );
        return;
    }
#endif
    __ulock_wake( UL_COMPARE_AND_WAIT | (all ? ULF_WAKE_ALL : 0), (void *)addr, 0 );
}

#else  /* !__APPLE__ — fastsync is an iOS-only path; keep the header compilable */

static inline void madeira_fast_park( const int *addr, int val, uint64_t ns_timeout ) { }
static inline void madeira_fast_wake( const int *addr, int all ) { }

#endif /* __APPLE__ */

#endif /* __IOS_FASTSYNC_H */
