/*
 * iOS-Madeira override for wine/dlls/win32u/syscall.c.
 *
 * THE RULE, and why upstream's cannot be used verbatim here.
 *
 * Upstream win32u keeps one process-global, `zero_bits`, set at unix-lib init
 * when the process has a WoW64 TEB:
 *
 *     if (NtCurrentTeb()->WowTebOffset)
 *         zero_bits = (ULONG_PTR)info.HighestUserAddress | 0x7fffffff;
 *
 * Every later NtAllocateVirtualMemory in win32u passes it, so the GDI shared
 * handle table (gdiobj.c), DC_ATTR buckets (dc.c), DIB section pixel buffers
 * (dib.c), message return buffers (message.c) and Vulkan host mappings
 * (vulkan.c) land where 32-bit guest code can address them.  That is not an
 * optimisation: win32u hands those addresses to the guest, and 32-bit gdi32
 * TRUNCATES them (wine/dlls/gdi32/objects.c:70-79 reads
 * peb64->GdiSharedHandleTable through a 32-bit UINT_PTR cast).
 *
 * On Madeira every Windows process is a pseudo-process -- a thread inside ONE
 * Mach task, sharing ONE win32u instance -- so a "process global" is really
 * TASK-global and is wrong for every process except the one that wrote it:
 *
 *   - 32-bit process first: the global stays set after it exits, so every
 *     later 64-bit pseudo-process allocates with a low-2GB ceiling it can
 *     never satisfy on iOS (`[va-scan] FAILED window=0x10000..0x80000000 ...
 *     STATUS_NO_MEMORY`) -- explorer's dialogs got no window surface.
 *   - Global cleared (the ml750 change this file used to make): a 32-bit
 *     pseudo-process then receives raw HOST pointers, and the truncation above
 *     produces a guest address that FEX rebases into the window at B + low32,
 *     which is unmapped -- `[mach_exc] UNHANDLED pc=... addr=0x7138c9057e`
 *     inside i386 gdi32!get_gdi_client_ptr.
 *
 * Both are the same root cause, so neither value can be right for everyone.
 * `zero_bits` is therefore DEAD on iOS (kept at 0 so a missed call site fails
 * the safe way for the 64-bit majority) and every consumer calls
 * win32u_zero_bits(), which answers for the CALLING pseudo-process:
 *
 *     wow (WowTebOffset != 0) -> HighestUserAddress | 0x7fffffff   (a GUEST
 *         ceiling, which build/ntdll-unix/virtual_ios.c's
 *         ios_wow_translate_limits() turns into [B+floor, B+ceiling])
 *     otherwise               -> 0
 *
 * The ceiling is cached per (pid, peb) -- the key class_ios.c's builtin-class
 * registry already uses, so a recycled PEB address cannot answer for a dead
 * process -- plus a per-thread fast path.
 *
 * NOTE the companion rule in gdiobj.c: the GDI shared table itself must NOT be
 * allocated with a guest ceiling even when the process that first initialises
 * win32u is 32-bit.  It is session-wide state, while a guest window is torn
 * down and replaced with PROT_NONE when its 32-bit pseudo-process exits.  The
 * master table stays at a host address for the life of the session and each
 * 32-bit pseudo-process gets a second VIEW of it inside its own window.
 */

#include <stdio.h>
#include <unistd.h>
#include <pthread.h>

/* Compile upstream syscall.c with its init entry point renamed, then wrap it.
 * build.sh already maps __wine_unix_lib_init -> win32u_unix_lib_init; this
 * pushes that one step further so the wrapper below can own the real name. */
#define win32u_unix_lib_init win32u_unix_lib_init_upstream
#include "../../wine/dlls/win32u/syscall.c"
#undef win32u_unix_lib_init

/***********************************************************************
 *           win32u_zero_bits
 *
 * The allocation ceiling of the CALLING pseudo-process.  See the file header.
 */

struct ios_zero_bits_entry
{
    DWORD     pid;
    void     *peb;
    ULONG_PTR zero_bits;
};

#define IOS_MAX_ZERO_BITS_PROCS 64
static struct ios_zero_bits_entry ios_zero_bits_reg[IOS_MAX_ZERO_BITS_PROCS];
static int ios_zero_bits_count;
static pthread_mutex_t ios_zero_bits_lock = PTHREAD_MUTEX_INITIALIZER;

/* a thread never changes pseudo-process, so this needs no invalidation */
static __thread void      *ios_zero_bits_cached_peb;
static __thread ULONG_PTR  ios_zero_bits_cached;

static ULONG_PTR ios_compute_zero_bits( void *peb, DWORD pid )
{
    SYSTEM_BASIC_INFORMATION info;
    ULONG_PTR high = 0, value;

    if (!NtCurrentTeb()->WowTebOffset) value = 0;
    else
    {
        if (!NtQuerySystemInformation( SystemEmulationBasicInformation, &info, sizeof(info), NULL ))
            high = (ULONG_PTR)info.HighestUserAddress;
        /* A sane answer is a GUEST address below 4 GB.  Anything else (query
         * failure, or a host-sized limit leaking out of a session global) must
         * not escape as a ceiling: >= 4 GB would be taken for a host address
         * and skip the window translation entirely, so fall back to the
         * conservative 2 GB guest ceiling. */
        value = (high && high < ((ULONG_PTR)1 << 32)) ? (high | 0x7fffffff) : 0x7fffffff;
    }

    dprintf( 2, "[zero-bits] peb=%p pid=%04x wow=%d ceiling=%#lx\n",
             peb, (int)pid, NtCurrentTeb()->WowTebOffset ? 1 : 0, (unsigned long)value );
    return value;
}

ULONG_PTR win32u_zero_bits(void)
{
    void *peb = NtCurrentTeb()->Peb;
    ULONG_PTR ret;
    DWORD pid;
    int i;

    if (ios_zero_bits_cached_peb == peb) return ios_zero_bits_cached;

    pid = HandleToULong( NtCurrentTeb()->ClientId.UniqueProcess );

    pthread_mutex_lock( &ios_zero_bits_lock );
    for (i = 0; i < ios_zero_bits_count; i++)
        if (ios_zero_bits_reg[i].peb == peb && ios_zero_bits_reg[i].pid == pid) break;

    if (i < ios_zero_bits_count) ret = ios_zero_bits_reg[i].zero_bits;
    else
    {
        ret = ios_compute_zero_bits( peb, pid );
        if (ios_zero_bits_count < IOS_MAX_ZERO_BITS_PROCS)
        {
            ios_zero_bits_reg[i].pid       = pid;
            ios_zero_bits_reg[i].peb       = peb;
            ios_zero_bits_reg[i].zero_bits = ret;
            ios_zero_bits_count = i + 1;
        }
        else
        {
            static int warned;
            if (!warned++)
                dprintf( 2, "[zero-bits] registry FULL (%d processes) — recomputing per call\n",
                         IOS_MAX_ZERO_BITS_PROCS );
        }
    }
    pthread_mutex_unlock( &ios_zero_bits_lock );

    /* only cache what the registry vouches for, so a full registry keeps
     * answering from a fresh query instead of pinning a stale value */
    if (i < IOS_MAX_ZERO_BITS_PROCS)
    {
        ios_zero_bits_cached     = ret;
        ios_zero_bits_cached_peb = peb;
    }
    return ret;
}

NTSTATUS win32u_unix_lib_init(void)
{
    NTSTATUS status = win32u_unix_lib_init_upstream();

    /* The task-global is dead here; win32u_zero_bits() answers per
     * pseudo-process.  Keep it at 0 so that any call site that still reads it
     * behaves like a 64-bit process (which is the common case and the only one
     * for which a host address is right). */
    if (zero_bits)
    {
        dprintf( 2, "[zero-bits] win32u unix init: dropping the task-global ceiling %#lx — "
                    "every consumer now asks win32u_zero_bits() for the calling "
                    "pseudo-process\n", (unsigned long)zero_bits );
        zero_bits = 0;
    }
    return status;
}
