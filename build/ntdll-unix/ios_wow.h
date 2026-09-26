/* WoW64 guest window — see WOW64_DESIGN.md §2 "shifted guest window".
 *
 * XNU's mandatory 4 GB __PAGEZERO makes the classic WoW64 identity
 * (guest address == host address) impossible: nothing can be mapped below
 * 4 GB.  Instead every 32-bit pseudo-process owns one reserved host range
 * [B, B+4G); guest address `a` (always < 4 GB, what the x86 code sees) lives
 * at host address `B + a`.
 *
 * The unix side and the wineserver speak HOST addresses throughout.  The one
 * exception is a CEILING that a WoW process sends down (a zero_bits value or
 * a MEM_ADDRESS_REQUIREMENTS limit below 4 GB) or that is reported back up
 * (HighestUserAddress): those are GUEST-namespace numbers, and the unix side
 * translates a guest ceiling L into the host range [B, B+L] when it picks an
 * address.  virtual_get_system_info keeps reporting the guest value so
 * wow64.dll's default_zero_bits logic is unchanged.
 *
 * B is published to wow64.dll and to the FEX WoW64 module through
 * NtQueryInformationProcess( handle, ProcessWineIosWowGuestBase, ... ).
 *
 * virtual_ios.c owns the registry; this header is the interface the other
 * forked unix files (thread_ios.c, env_ios.c, process_ios.c, loader_ios.c,
 * server_ios.c, signal_arm64_ios.c) use.
 */
#ifndef __MADEIRA_IOS_WOW_H
#define __MADEIRA_IOS_WOW_H

#define IOS_WOW_WINDOW_SIZE  ((ULONG_PTR)1 << 32)   /* 4 GB */

/* B for an explicit pseudo-process, 0 when that process has no window. */
extern ULONG_PTR ios_wow_base_for_peb( void *peb_id );

/* B for the calling thread's pseudo-process.  Also reports a window that was
 * reserved on this thread but is not bound to a PEB yet (the child boot path
 * reserves before its PEB exists).  0 when the caller is not in a WoW
 * process — which is also the "is this a WoW process" predicate, and is
 * per-process where is_wow64() is only per-session. */
extern ULONG_PTR ios_wow_base(void);

/* Published by the app before __wine_main: nonzero when this pseudo-process's
 * MAIN image is 32-bit, so start_main_thread reserves a window before the
 * first TEB (the machine is otherwise unknown until unix_init_startup_info,
 * which runs too late).  0 for a 64-bit main image. */
extern int ios_main_image_i386;

/* Reserve a window for the calling thread.  Idempotent per thread. */
extern NTSTATUS ios_wow_window_reserve(void);
/* Bind the window reserved on this thread to a pseudo-process. */
extern void ios_wow_window_bind( void *peb_id );
/* Release a pseudo-process's window (process EXIT): the slot stops resolving,
 * the session-start placeholder becomes unadopted again, and the 4 GB range and
 * all of Wine's bookkeeping inside it are torn down when the next 32-bit
 * pseudo-process claims the slot (release-on-next-adopt — nothing joins a dead
 * pseudo-process's threads on iOS, so the teardown cannot run on the dying
 * thread, which is still standing on a TEB inside the window). */
extern void ios_wow_window_release( void *peb_id );
/* Same, for the calling thread's own pseudo-process. */
extern void ios_wow_window_release_current(void);
/* ABANDON the calling thread's window for good: for a pseudo-process that stops
 * being a WoW process while STAYING ALIVE inside the window (env_ios.c's
 * start.exe fallback).  The VA is leaked on purpose and the slot serves no
 * further 32-bit process this session. */
extern void ios_wow_window_retire_current(void);

/* Translate a GUEST-namespace ceiling pair into the calling process's host
 * window.  A no-op when the caller has no window, or when limit_high is not a
 * guest ceiling (0 = unconstrained, or already >= 4 GB = a host address). */
extern void ios_wow_translate_limits( ULONG_PTR *limit_low, ULONG_PTR *limit_high );

/* TRUE when `addr` lies inside the calling process's window. */
extern int ios_wow_in_window( const void *addr );

/* Guest view of a host address for the calling process: host - B, or the
 * address truncated unchanged when the caller has no window.  NULL stays 0. */
extern ULONG ios_wow_guest_addr( const void *host );

/* Map a read-only second view of KUSER_SHARED_DATA at host B + 0x7ffe0000,
 * i.e. at guest 0x7ffe0000.  No-op outside a window. */
extern void ios_wow_map_user_shared_data(void);

/* ml1040: hold guest 0x7ffe0000 from before the first TEB block is reserved
 * until the real KUSER_SHARED_DATA view replaces it.  Without this the
 * MEM_TOP_DOWN search for the TEB block takes that address and every 32-bit
 * tick read in the process is frozen. */
extern void ios_wow_reserve_usd_slot( ULONG_PTR base );
extern void ios_wow_release_usd_slot(void);

/* Convert the PEB64 pointer fields that the 32-bit ntdll writes itself with
 * the classic WoW64 identity (`peb64->X = PtrToUlong( guest_ptr )`) into HOST
 * pointers, so invariant 2 holds for the native readers of those fields.
 * Exact test: nothing is mapped below iOS's 4 GB __PAGEZERO, so a non-zero
 * sub-4 GB value is a guest address.  Idempotent; no-op without a window.
 * Implemented in env_ios.c next to the NLS code that produces the values. */
extern void ios_wow_fixup_peb64_ptrs(void);

/* A pointer EMBEDDED in a 32-bit unix-call argument block (an entry of
 * __wine_unix_call_wow64_funcs) is a GUEST address: the WoW64 module converts
 * only the OUTER `args` pointer.  ios_wow_host_ptr() is the +B conversion for
 * those, NULL-preserving; ios_wow_guest_ptr32() writes one back.  Defined in
 * wine/unixlib.h so every unixlib, not just this tree, can use it; the guard
 * below keeps whichever header is included first as the definition. */
#ifndef __MADEIRA_IOS_WOW_HOST_PTR
#define __MADEIRA_IOS_WOW_HOST_PTR
static inline void *ios_wow_host_ptr( ULONG addr )
{
    return addr ? (void *)(ios_wow_base() + (ULONG_PTR)addr) : NULL;
}
static inline ULONG ios_wow_guest_ptr32( const void *host )
{
    return host ? (ULONG)((ULONG_PTR)host - ios_wow_base()) : 0;
}
#endif

#endif /* __MADEIRA_IOS_WOW_H */
