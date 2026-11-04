/* iOS-Madeira: opengl32's get_teb64() for a 32-bit (WoW64) caller.
 *
 * Wine's dlls/opengl32/unix_private.h turns the 32-bit TEB address a WoW64
 * thunk passes down into the 64-bit TEB with
 *
 *     TEB32 *teb32_ptr = ULongToPtr( teb32 );
 *     return (TEB *)((char *)teb32_ptr + teb32_ptr->WowTebOffset);
 *
 * which assumes the classic WoW64 identity (guest address == host address).
 * On iOS a 32-bit pseudo-process lives in a 4 GB window at host B + guest
 * (build/ntdll-unix/ios_wow.h), so the read of WowTebOffset went to the bare
 * guest address and faulted. Every 32-bit program that loads opengl32.dll died
 * in its thread-attach call before showing anything ("opengl32.dll failed to
 * initialize", c0000142; seen with AI6WIN.exe: fault at 0x7ffc2fdc =
 * guest TEB32 0x7ffc2000 + 0xfdc, window base 0x7100000000).
 *
 * The wrapper sources opengl32_wgl_ios.c and opengl32_thunks_ios.c include
 * this header before Wine's sources: unix_private.h then defines its own
 * version under another name (unused), and every caller uses this one, which
 * adds the window base exactly as ios_wow_host_ptr() does. With no window (a
 * 64-bit caller, base 0) it is Wine's function unchanged.
 *
 * Only the TEB is converted here: the generated wow64 thunks still pass other
 * embedded 32-bit pointers through ULongToPtr, so a 32-bit program that really
 * draws with OpenGL is not supported by this; one that only loads opengl32
 * (and draws with Direct3D) now starts. */
#ifndef __MADEIRA_OPENGL32_TEB64_IOS_H
#define __MADEIRA_OPENGL32_TEB64_IOS_H

#define get_teb64 wine_upstream_get_teb64_unused
#include "unix_private.h"
#undef get_teb64

extern ULONG_PTR ios_wow_base(void) __attribute__((weak));

static inline TEB *get_teb64( ULONG teb32 )
{
    ULONG_PTR base = ios_wow_base ? ios_wow_base() : 0;
    TEB32 *teb32_ptr = (TEB32 *)(base + (ULONG_PTR)teb32);
    return (TEB *)((char *)teb32_ptr + teb32_ptr->WowTebOffset);
}

#endif /* __MADEIRA_OPENGL32_TEB64_IOS_H */
