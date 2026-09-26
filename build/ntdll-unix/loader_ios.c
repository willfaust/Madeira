/*
 * Unix interface for loader functions
 *
 * Copyright (C) 2020 Alexandre Julliard
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#if 0
#pragma makedep unix
#endif

#include "config.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <dlfcn.h>
#ifdef HAVE_PWD_H
# include <pwd.h>
#endif
#ifdef HAVE_ELF_H
# include <elf.h>
#endif
#ifdef HAVE_LINK_H
# include <link.h>
#endif
#ifdef HAVE_SYS_AUXV_H
# include <sys/auxv.h>
#endif
#ifdef HAVE_SYS_RESOURCE_H
# include <sys/resource.h>
#endif
#include <limits.h>
#ifdef HAVE_SYS_SYSCTL_H
# include <sys/sysctl.h>
#endif
#ifdef __APPLE__
# include <CoreFoundation/CoreFoundation.h>
# define LoadResource MacLoadResource
# define GetCurrentThread MacGetCurrentThread
# include <CoreServices/CoreServices.h>
# undef LoadResource
# undef GetCurrentThread
# include <pthread.h>
# include <mach/mach.h>
# include <mach/mach_error.h>
# include <mach-o/getsect.h>
# include <crt_externs.h>
# ifndef _POSIX_SPAWN_DISABLE_ASLR
#  define _POSIX_SPAWN_DISABLE_ASLR 0x0100
# endif
# define environ (*_NSGetEnviron())
#else
  extern char **environ;
#endif
#ifdef __ANDROID__
# include <jni.h>
#endif

#include "ntstatus.h"
#include "windef.h"
#include "winnt.h"
#include "winbase.h"
#include "winnls.h"
#include "winioctl.h"
#include "winternl.h"
#include "unix_private.h"
#include "ios_wow.h"
#include "wine/list.h"
#include "wine/debug.h"

#ifdef WINE_IOS
#include <os/log.h>
#include <pthread.h>
#include <mach-o/dyld.h>
#endif

WINE_DEFAULT_DEBUG_CHANNEL(module);

#if defined __i386__ || defined __x86_64__
#define SO_DLLS_SUPPORTED
#endif

void *pDbgUiRemoteBreakin = NULL;
void *pKiRaiseUserExceptionDispatcher = NULL;
void *pKiUserExceptionDispatcher = NULL;
void *pKiUserApcDispatcher = NULL;
void *pKiUserCallbackDispatcher = NULL;
void *pKiUserEmulationDispatcher = NULL;
void *pLdrInitializeThunk = NULL;
void *pRtlUserThreadStart = NULL;
void *p__wine_ctrl_routine = NULL;
SYSTEM_DLL_INIT_BLOCK *pLdrSystemDllInitBlock = NULL;

#ifdef __GNUC__
static void fatal_error( const char *err, ... ) __attribute__((noreturn, format(printf,1,2)));
#endif

static const char *bin_dir;
static const char *dll_dir;
static const char *ntdll_dir;
static const char *alt_build_dir;
static SIZE_T dll_path_maxlen;

const char *home_dir = NULL;
const char *data_dir = NULL;
const char *build_dir = NULL;
const char *config_dir = NULL;
const char *wineloader = NULL;
const char **dll_paths = NULL;
const char **system_dll_paths = NULL;
const char *user_name = NULL;
SECTION_IMAGE_INFORMATION main_image_info = { NULL };

/* die on a fatal error; use only during initialization */
static void fatal_error( const char *err, ... )
{
    va_list args;
    va_start( args, err );
#ifdef WINE_IOS
    char buf[1024];
    vsnprintf( buf, sizeof(buf), err, args );
    va_end( args );
    os_log_error( OS_LOG_DEFAULT, "[Wine ntdll] FATAL: %{public}s", buf );
    pthread_exit( NULL );
#else
    fprintf( stderr, "wine: " );
    vfprintf( stderr, err, args );
    va_end( args );
    exit(1);
#endif
}

static void set_max_limit( int limit )
{
    struct rlimit rlimit;

    if (!getrlimit( limit, &rlimit ))
    {
        rlimit.rlim_cur = rlimit.rlim_max;
        if (!setrlimit( limit, &rlimit )) return;
#ifdef __APPLE__
        if (limit == RLIMIT_NOFILE)
        {
            /* macOS before Big Sur fails if rlim_max is larger than maxfilesperproc */
            unsigned int nlimit = 0;
            size_t size = sizeof(nlimit);
            sysctlbyname("kern.maxfilesperproc", &nlimit, &size, NULL, 0);
            rlimit.rlim_cur = max( nlimit, OPEN_MAX );
            if (!setrlimit( RLIMIT_NOFILE, &rlimit )) return;
        }
#endif
        WARN("Failed to raise limit %d\n", limit);
    }
}

/* canonicalize path and return its directory name */
static char *realpath_dirname( const char *name )
{
    char *p, *fullpath = realpath( name, NULL );

    if (fullpath)
    {
        p = strrchr( fullpath, '/' );
        if (p == fullpath) p++;
        if (p) *p = 0;
    }
    return fullpath;
}

/* if string ends with tail, remove it */
static char *remove_tail( const char *str, const char *tail )
{
    size_t len = strlen( str );
    size_t tail_len = strlen( tail );
    char *ret;

    if (len < tail_len) return NULL;
    if (strcmp( str + len - tail_len, tail )) return NULL;
    ret = malloc( len - tail_len + 1 );
    memcpy( ret, str, len - tail_len );
    ret[len - tail_len] = 0;
    return ret;
}

/* build a path from the specified dir and name */
static char *build_path( const char *dir, const char *name )
{
    size_t len = strlen( dir );
    char *ret = malloc( len + strlen( name ) + 2 );

    if (len)
    {
        memcpy( ret, dir, len );
        if (ret[len - 1] != '/') ret[len++] = '/';
        if (name[0] == '/') name++;
    }
    strcpy( ret + len, name );
    return ret;
}

/* build a path with the relative dir from 'from' to 'dest' appended to base */
static char *build_relative_path( const char *base, const char *from, const char *dest )
{
    const char *start;
    char *ret;
    unsigned int dotdots = 0;

    for (;;)
    {
        while (*from == '/') from++;
        while (*dest == '/') dest++;
        start = dest;  /* save start of next path element */
        if (!*from) break;

        while (*from && *from != '/' && *from == *dest) { from++; dest++; }
        if ((!*from || *from == '/') && (!*dest || *dest == '/')) continue;

        do  /* count remaining elements in 'from' */
        {
            dotdots++;
            while (*from && *from != '/') from++;
            while (*from == '/') from++;
        }
        while (*from);
        break;
    }

    ret = malloc( strlen(base) + 3 * dotdots + strlen(start) + 2 );
    strcpy( ret, base );
    while (dotdots--) strcat( ret, "/.." );

    if (!start[0]) return ret;
    strcat( ret, "/" );
    strcat( ret, start );
    return ret;
}

/* build a path to a binary and exec it */
static int build_path_and_exec( pid_t *pid, const char *dir, const char *name, char **argv )
{
#ifdef WINE_IOS
    /* Cannot spawn processes on iOS */
    return ENOSYS;
#else
    int ret;

    argv[0] = build_path( dir, name );
    ret = posix_spawn( pid, argv[0], NULL, NULL, argv, environ );
    free( argv[0] );
    return ret;
#endif
}


static const char *get_so_dir( WORD machine )
{
    switch (machine)
    {
    case IMAGE_FILE_MACHINE_I386:  return "/i386-unix";
    case IMAGE_FILE_MACHINE_AMD64: return "/x86_64-unix";
    case IMAGE_FILE_MACHINE_ARMNT: return "/arm-unix";
    case IMAGE_FILE_MACHINE_ARM64: return "/aarch64-unix";
    default: return "";
    }
}

#ifdef WINE_IOS
/* X3 mixed-mode pseudo-processes: per-process main-image identity.
 *
 * is_arm64ec() and main_image_info are session globals, but each child
 * pseudo-process has its own main exe: an AMD64 child under an ARM64
 * desktop session must see is_arm64ec()=TRUE (arm64ec-windows pe_dir,
 * CHPE cpu_area on its threads, EC fault dispatch) while the parent and
 * its siblings keep seeing FALSE. Worse, unix_init_startup_info()
 * OVERWRITES the main_image_info global with each child's exe info,
 * retroactively flipping the whole session's identity — parent threads
 * run concurrently, so that flip poisons their fault handling and DLL
 * resolution. wine_ios_child_main registers the child's info here and
 * restores the global (S1 registry pattern, same as fd_socket).
 *
 * Readers are lock-free (fault handlers call this): slots are fully
 * written before the count is published. Audit 2026-07-06: every
 * is_arm64ec/main_image_info consumer lives in forked files; unforked
 * wine unix files have zero users. */
#include "ios_mixed.h"

#define IOS_MAX_PROC_IDENTS 64
struct ios_proc_ident
{
    void *peb;                        /* NULL = free slot */
    SECTION_IMAGE_INFORMATION info;   /* this pseudo-process's main exe */
    /* X3c: cross-arch children run their own ntdll image (the session's
     * aarch64 ntdll can't host an AMD64 process). NULL = session ntdll. */
    void *ntdll_module;
    struct ios_ntdll_funcs funcs;     /* valid when ntdll_module != NULL */
};
static struct ios_proc_ident ios_proc_idents[IOS_MAX_PROC_IDENTS];
static int ios_proc_ident_count;

extern void *ios_jit_current_peb(void);

const SECTION_IMAGE_INFORMATION *ios_image_info_for_peb( void *peb_id )
{
    int i, n = ios_proc_ident_count;
    if (peb_id)
        for (i = 0; i < n; i++)
            if (ios_proc_idents[i].peb == peb_id) return &ios_proc_idents[i].info;
    return &main_image_info;
}

const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void)
{
    return ios_image_info_for_peb( ios_jit_current_peb() );
}

int ios_is_arm64ec_cur(void)
{
    return current_machine == IMAGE_FILE_MACHINE_ARM64 &&
           ios_cur_image_info()->Machine == IMAGE_FILE_MACHINE_AMD64;
}

void ios_register_proc_ident( void *peb_id, const SECTION_IMAGE_INFORMATION *info )
{
    int idx = ios_proc_ident_count, i;

    /* prefer a slot released by a dead pseudo-process (ios_proc_ident_release)
     * — without this the registry fills up over a long multi-process session
     * even though entries keep being freed.  Writing `info` before `peb` is the
     * same publish order the append path uses, for the same lock-free readers. */
    for (i = 0; i < ios_proc_ident_count; i++)
        if (!ios_proc_idents[i].peb) { idx = i; break; }

    if (idx >= IOS_MAX_PROC_IDENTS)
    {
        dprintf(2, "[proc-ident] registry FULL — %p keeps session identity\n", peb_id);
        return;
    }
    ios_proc_idents[idx].info = *info;
    ios_proc_idents[idx].ntdll_module = NULL;
    __sync_synchronize();
    ios_proc_idents[idx].peb = peb_id;
    __sync_synchronize();
    if (idx == ios_proc_ident_count) ios_proc_ident_count = idx + 1;
    dprintf(2, "[proc-ident] peb=%p Machine=0x%x (slot %d)\n",
            peb_id, info->Machine, idx);
}

/* A pseudo-process has exited and its PEB is about to be REUSED.
 *
 * This registry is keyed by PEB pointer, and a 32-bit child's PEB is allocated
 * inside its guest window — so when the window is released and re-adopted, the
 * next child's PEB lands at the same host address.  A surviving entry would
 * then answer for the new process with the dead one's main-image info and its
 * private (already tombstoned) ntdll copy, which is how a stale identity turns
 * into a wrong pe_dir, a wrong is_arm64ec() and a call into freed pool memory.
 * Called from the guest-window teardown (virtual_ios.c). */
void ios_proc_ident_release( void *peb_id )
{
    int i, n = ios_proc_ident_count;

    if (!peb_id) return;
    for (i = 0; i < n; i++)
    {
        if (ios_proc_idents[i].peb != peb_id) continue;
        ios_proc_idents[i].peb = NULL;        /* readers match on peb: clear it first */
        __sync_synchronize();
        ios_proc_idents[i].ntdll_module = NULL;
        memset( &ios_proc_idents[i].funcs, 0, sizeof(ios_proc_idents[i].funcs) );
        memset( &ios_proc_idents[i].info, 0, sizeof(ios_proc_idents[i].info) );
        dprintf(2, "[proc-ident] released peb=%p (slot %d)\n", peb_id, i);
        return;
    }
    dprintf(2, "[proc-ident] release: peb=%p was not registered\n", peb_id);
}

/* X3c: attach a private ntdll image + entry points to a registered ident. */
static void ios_set_proc_ntdll( void *peb_id, void *module, const struct ios_ntdll_funcs *funcs )
{
    int i, n = ios_proc_ident_count;
    for (i = 0; i < n; i++)
    {
        if (ios_proc_idents[i].peb != peb_id) continue;
        ios_proc_idents[i].funcs = *funcs;
        __sync_synchronize();
        ios_proc_idents[i].ntdll_module = module;
        dprintf(2, "[proc-ident] peb=%p private ntdll=%p (slot %d)\n", peb_id, module, i);
        return;
    }
    dprintf(2, "[proc-ident] ios_set_proc_ntdll: peb %p NOT REGISTERED\n", peb_id);
}

const struct ios_ntdll_funcs *ios_cur_ntdll_funcs(void)
{
    void *cur = ios_jit_current_peb();
    int i, n = ios_proc_ident_count;
    if (cur)
        for (i = 0; i < n; i++)
            if (ios_proc_idents[i].peb == cur)
                return ios_proc_idents[i].ntdll_module ? &ios_proc_idents[i].funcs : NULL;
    return NULL;
}

/* ml369 (#63): same lookup keyed by an explicit PEB — for the Mach
 * exception-server thread, which has no pseudo-process identity of its own
 * but delivers guest exceptions into a specific TARGET thread's process. */
const struct ios_ntdll_funcs *ios_ntdll_funcs_for_peb( void *peb_id )
{
    int i, n = ios_proc_ident_count;
    if (peb_id)
        for (i = 0; i < n; i++)
            if (ios_proc_idents[i].peb == peb_id)
                return ios_proc_idents[i].ntdll_module ? &ios_proc_idents[i].funcs : NULL;
    return NULL;
}

/* ml381: find __os_arm64x_dispatch_call_no_redirect's RVA BY SCANNING, not by
 * hardcoding it.
 *
 * The old probe hardcoded RVA 0xC4480, measured against one particular
 * arm64ec-windows/ntdll.dll build. Rebuilding ntdll (which this port does
 * routinely — ml377 alone rebuilt it) MOVES that global, and the probe then
 * dumps an unrelated .data address. In ml380 it printed all-zeros and I nearly
 * concluded "the ARM64X dispatch globals are NULL in every private EC ntdll
 * copy" — a fabricated root cause. Verified offline against the CURRENT build:
 * the real global is at 0xc0bb8 (referenced by 258 exit thunks), NOT 0xc4480.
 *
 * Every exit thunk loads it with the pair
 *   adrp x16, <page> ; ldr x16, [x16, #imm]
 * so the global is simply the most-referenced .data target of that pattern.
 * Scanning for it makes the probe correct for any build, forever. Cached.
 *
 * 🔑 A hardcoded RVA in a probe is a landmine: it keeps printing plausible
 * numbers after it stops being right. */
static unsigned int ios_ec_dispatch_rva( const unsigned char *base )
{
    static unsigned int cached;
    unsigned int e_lfanew, nsec, optsz, sect, i, best_rva = 0, best_hits = 0;
    unsigned int text_va = 0, text_sz = 0, data_va = 0, data_sz = 0;
    struct { unsigned int rva, hits; } top[24];
    unsigned int ntop = 0, off;

    if (cached) return cached;
    if (!(base[0] == 'M' && base[1] == 'Z')) return 0;
    e_lfanew = *(const unsigned int *)(base + 0x3c);
    if (e_lfanew >= 0x1000) return 0;
    nsec  = *(const unsigned short *)(base + e_lfanew + 6);
    optsz = *(const unsigned short *)(base + e_lfanew + 20);
    sect  = e_lfanew + 24 + optsz;
    for (i = 0; i < nsec && i < 32; i++)
    {
        const unsigned char *s = base + sect + i * 40;
        unsigned int vsz = *(const unsigned int *)(s + 8);
        unsigned int va  = *(const unsigned int *)(s + 12);
        if (!memcmp( s, ".text", 5 ))  { text_va = va; text_sz = vsz; }
        if (!memcmp( s, ".data", 5 ))  { data_va = va; data_sz = vsz; }
    }
    if (!text_sz || !data_sz) return 0;

    for (off = 0; off + 8 <= text_sz; off += 4)
    {
        unsigned int w0 = *(const unsigned int *)(base + text_va + off);
        unsigned int w1 = *(const unsigned int *)(base + text_va + off + 4);
        int immhi, immlo, imm21;
        unsigned int pc_va, page, tgt, k;

        if ((w0 & 0x9f00001fu) != 0x90000010u) continue;   /* adrp x16, ... */
        if ((w1 & 0xffc003ffu) != 0xf9400210u) continue;   /* ldr x16,[x16,#imm] */
        immhi = (int)((w0 >> 5) & 0x7ffff);
        immlo = (int)((w0 >> 29) & 3);
        imm21 = (immhi << 2) | immlo;
        if (imm21 & (1 << 20)) imm21 -= (1 << 21);
        pc_va = text_va + off;
        page  = (pc_va & ~0xfffu) + (unsigned int)(imm21 << 12);
        tgt   = page + (((w1 >> 10) & 0xfff) * 8);
        if (tgt < data_va || tgt >= data_va + data_sz) continue;

        for (k = 0; k < ntop; k++) if (top[k].rva == tgt) { top[k].hits++; break; }
        if (k == ntop && ntop < 24) { top[ntop].rva = tgt; top[ntop].hits = 1; ntop++; }
    }
    for (i = 0; i < ntop; i++)
        if (top[i].hits > best_hits) { best_hits = top[i].hits; best_rva = top[i].rva; }

    dprintf( 2, "[thunk-slot] rev=ml381 dispatch-global RVA resolved to 0x%x (%u thunk refs)\n",
             best_rva, best_hits );
    cached = best_rva;
    return best_rva;
}

/* Thing B probe: a thread wedged in an EC ntdll exit thunk after
 * `blr x16` with x16==1 — the ldr read the ARM64X dispatch global
 * __os_arm64x_dispatch_call_no_redirect and got 1 instead of a code
 * pointer. Dump the neighborhood in EVERY private EC ntdll copy so we can see
 * which copies were initialized (ExitToX64 pointer) and which still hold the
 * on-disk sentinel. lr_va is the wedged thread's lr pre-translated to a module
 * VA (or raw if translation failed). */
void ios_dump_ec_dispatch_slots( unsigned long long lr_va, unsigned long long x9 )
{
    int i, n = ios_proc_ident_count;
    dprintf(2, "[thunk-slot] idents=%d lr_va=0x%llx x9=0x%llx\n", n, lr_va, x9);
    for (i = 0; i < n; i++)
    {
        const unsigned char *base = ios_proc_idents[i].ntdll_module;
        unsigned int e_lfanew, size_img = 0;
        const unsigned long long *q;
        if (!base)
        {
            dprintf(2, "[thunk-slot] ident %d peb=%p ntdll=SESSION\n",
                    i, ios_proc_idents[i].peb);
            continue;
        }
        if (base[0] == 'M' && base[1] == 'Z' &&
            (e_lfanew = *(const unsigned int *)(base + 0x3c)) < 0x1000)
            size_img = *(const unsigned int *)(base + e_lfanew + 0x50);
        dprintf(2, "[thunk-slot] ident %d peb=%p ntdll=%p size=0x%x machine=0x%x%s\n",
                i, ios_proc_idents[i].peb, base, size_img,
                ios_proc_idents[i].info.Machine,
                (lr_va >= (unsigned long long)(uintptr_t)base &&
                 lr_va < (unsigned long long)(uintptr_t)base + size_img)
                    ? "  <-- lr IS IN THIS IMAGE" : "");
        {
            unsigned int rva = ios_ec_dispatch_rva( base );
            if (!rva)
            {
                dprintf(2, "[thunk-slot]   dispatch-global RVA UNRESOLVED — cannot judge this copy\n");
                continue;
            }
            q = (const unsigned long long *)(base + rva);
            dprintf(2, "[thunk-slot]   +0x%x dispatch_call_no_redirect=%016llx %s\n"
                       "[thunk-slot]     neighbours: %016llx %016llx %016llx\n",
                    rva, q[0],
                    q[0] ? "(INITIALISED)" : "<== ZERO: blr x16 would branch to NULL",
                    q[1], q[2], q[3]);
        }
    }
}
#endif

/* iOS host runs ARM64 natively. When loading an x86_64 (AMD64) main image
 * on ARM64 (= ARM64EC mode), system DLLs live in `arm64ec-windows/` as
 * hybrid PEs (Machine=AMD64 with native ARM64 code via CHPEMetadata).
 * Plain `aarch64-windows/` is for ARM64-only PEs.
 *
 * Owner-aware: an x64 child in an aarch64 session resolves arm64ec-windows
 * for its own loads while the session default stays aarch64-windows. */
static const char *get_pe_dir( WORD machine )
{
    switch(machine)
    {
    case IMAGE_FILE_MACHINE_I386:  return "/i386-windows";
    case IMAGE_FILE_MACHINE_AMD64:
        if (ios_is_arm64ec_cur()) return "/arm64ec-windows";
        return "/x86_64-windows";
    case IMAGE_FILE_MACHINE_ARMNT: return "/arm-windows";
    case IMAGE_FILE_MACHINE_ARM64:
        if (ios_is_arm64ec_cur()) return "/arm64ec-windows";
        return "/aarch64-windows";
    default: return "";
    }
}

/* Same answer as get_pe_dir(), exported so the spawn path can SAY which PE farm
 * a child's system DLLs will be resolved from.  Routing an i386 child at an
 * aarch64/arm64ec farm (or vice versa) otherwise shows up only as a child that
 * never produces a window. */
const char *ios_pe_dir_for_machine( WORD machine )
{
    return get_pe_dir( machine );
}

static WORD get_alt_machine( WORD machine )
{
    switch (machine)
    {
    case IMAGE_FILE_MACHINE_I386:  return IMAGE_FILE_MACHINE_AMD64;
    case IMAGE_FILE_MACHINE_AMD64: return IMAGE_FILE_MACHINE_I386;
    case IMAGE_FILE_MACHINE_ARMNT: return IMAGE_FILE_MACHINE_ARM64;
    case IMAGE_FILE_MACHINE_ARM64: return IMAGE_FILE_MACHINE_ARMNT;
    default: return machine;
    }
}

static void set_dll_path(void)
{
    char *p, *path = getenv( "WINEDLLPATH" );
    int i, count = 0;

    if (path) for (p = path, count = 1; *p; p++) if (*p == ':') count++;

    dll_paths = malloc( (count + 2) * sizeof(*dll_paths) );
    count = 0;

    if (!build_dir) dll_paths[count++] = dll_dir;

    if (path)
    {
        path = strdup(path);
        for (p = strtok( path, ":" ); p; p = strtok( NULL, ":" )) dll_paths[count++] = strdup( p );
        free( path );
    }

    for (i = 0; i < count; i++) dll_path_maxlen = max( dll_path_maxlen, strlen(dll_paths[i]) );
    dll_paths[count] = NULL;
}


static void set_system_dll_path(void)
{
    const char *p, *path = SYSTEMDLLPATH;
    int count = 0;

    if (path && *path) for (p = path, count = 1; *p; p++) if (*p == ':') count++;

    system_dll_paths = malloc( (count + 1) * sizeof(*system_dll_paths) );
    count = 0;

    if (path && *path)
    {
        char *path_copy = strdup(path);
        for (p = strtok( path_copy, ":" ); p; p = strtok( NULL, ":" ))
            system_dll_paths[count++] = strdup( p );
        free( path_copy );
    }
    system_dll_paths[count] = NULL;
}


static void set_home_dir(void)
{
    const char *home = getenv( "HOME" );
    const char *name = getenv( "USER" );
    const char *p;

    if (!home || !name)
    {
        struct passwd *pwd = getpwuid( getuid() );
        if (pwd)
        {
            if (!home) home = pwd->pw_dir;
            if (!name) name = pwd->pw_name;
        }
        if (!name) name = "wine";
    }
    if ((p = strrchr( name, '/' ))) name = p + 1;
    if ((p = strrchr( name, '\\' ))) name = p + 1;
    home_dir = strdup( home );
    user_name = strdup( name );
}


static void set_config_dir(void)
{
    char *p, *dir;
    const char *prefix = getenv( "WINEPREFIX" );

    if (prefix)
    {
        if (prefix[0] != '/')
            fatal_error( "invalid directory %s in WINEPREFIX: not an absolute path\n", prefix );
        config_dir = dir = strdup( prefix );
        for (p = dir + strlen(dir) - 1; p > dir && *p == '/'; p--) *p = 0;
    }
    else
    {
        if (!home_dir) fatal_error( "could not determine your home directory\n" );
        if (home_dir[0] != '/') fatal_error( "the home directory %s is not an absolute path\n", home_dir );
        config_dir = build_path( home_dir, ".wine" );
    }
}

static void init_paths(void)
{
#ifdef WINE_IOS
    /* On iOS, ntdll is statically linked. Use bundle path. */
    char exe_path[PATH_MAX];
    uint32_t exe_size = sizeof(exe_path);
    char *p;

    if (_NSGetExecutablePath( exe_path, &exe_size ) != 0)
        fatal_error( "cannot get executable path\n" );

    p = strrchr( exe_path, '/' );
    if (p) *p = 0;

    ntdll_dir = strdup( exe_path );
    dll_dir = strdup( exe_path );
    bin_dir = strdup( exe_path );
    data_dir = strdup( exe_path );  /* NLS files at <bundle>/nls/ */
    wineloader = build_path( exe_path, "wine" );

    set_dll_path();
    set_system_dll_path();
    set_dll_path();
    set_system_dll_path();
    set_home_dir();
    set_config_dir();
#else
    Dl_info info;

    if (!dladdr( init_paths, &info ) || !(ntdll_dir = realpath_dirname( info.dli_fname )))
        fatal_error( "cannot get path to ntdll.so\n" );

    if ((build_dir = remove_tail( ntdll_dir, "/dlls/ntdll" )))
    {
        wineloader = build_path( build_dir, "loader/wine" );
        alt_build_dir = realpath_dirname( build_path( build_dir, "loader-wow64" ));
    }
    else
    {
        if (!(dll_dir = remove_tail( ntdll_dir, get_so_dir(current_machine) ))) dll_dir = ntdll_dir;
        bin_dir = build_relative_path( dll_dir, LIBDIR "/wine", BINDIR );
        data_dir = build_relative_path( dll_dir, LIBDIR "/wine", DATADIR "/wine" );
        wineloader = build_path( ntdll_dir, "wine" );
    }

    set_dll_path();
    set_system_dll_path();
    set_home_dir();
    set_config_dir();
#endif
}


/***********************************************************************
 *           get_alternate_wineloader
 */
char *get_alternate_wineloader( WORD machine )
{
    const char *arch;
    BOOL force_wow64 = (arch = getenv( "WINEARCH" )) && !strcmp( arch, "wow64" );
    char *ret = NULL;

    if (is_win64)
    {
        if (force_wow64) return NULL;
        if (machine != get_alt_machine( current_machine )) return NULL;
    }
    else
    {
        if (!force_wow64 && machine == current_machine) return NULL;
        machine = get_alt_machine( current_machine );
    }

    if (!build_dir)
        asprintf( &ret, "%s%s/wine", dll_dir, get_so_dir( machine ));
    else if (alt_build_dir)
        asprintf( &ret, "%s/loader/wine", alt_build_dir );

    return ret;
}


static void preloader_exec( char **argv )
{
#ifdef HAVE_WINE_PRELOADER
    asprintf( &argv[0], "%s-preloader", argv[1] );
#ifdef __APPLE__
    {
        posix_spawnattr_t attr;
        posix_spawnattr_init( &attr );
        posix_spawnattr_setflags( &attr, POSIX_SPAWN_SETEXEC | _POSIX_SPAWN_DISABLE_ASLR );
        posix_spawn( NULL, argv[0], NULL, &attr, argv, *_NSGetEnviron() );
        posix_spawnattr_destroy( &attr );
    }
#endif
    execv( argv[0], argv );
    free( argv[0] );
#endif
    execv( argv[1], argv + 1 );
}

/* exec the appropriate wine loader for the specified machine */
static NTSTATUS loader_exec( char **argv, WORD machine )
{
    static char noexec[] = "WINELOADERNOEXEC=1";

    putenv( noexec );

    if (((argv[1] = get_alternate_wineloader( machine )))) preloader_exec( argv );

    argv[1] = strdup( wineloader );
    preloader_exec( argv );
    return STATUS_INVALID_IMAGE_FORMAT;
}


/***********************************************************************
 *           exec_wineloader
 *
 * argv[0] and argv[1] must be reserved for the preloader and loader respectively.
 */
NTSTATUS exec_wineloader( char **argv, int socketfd, const struct pe_image_info *pe_info )
{
    WORD machine = pe_info->machine;
    ULONGLONG res_start = pe_info->base;
    ULONGLONG res_end = pe_info->base + pe_info->map_size;
    char preloader_reserve[64], socket_env[64];

    if (pe_info->wine_fakedll) res_start = res_end = 0;
    if (pe_info->image_flags & IMAGE_FLAGS_ComPlusNativeReady) machine = native_machine;

    signal( SIGPIPE, SIG_DFL );

    snprintf( socket_env, sizeof(socket_env), "WINESERVERSOCKET=%u", socketfd );
    snprintf( preloader_reserve, sizeof(preloader_reserve), "WINEPRELOADRESERVE=%x%08x-%x%08x",
             (UINT)(res_start >> 32), (UINT)res_start, (UINT)(res_end >> 32), (UINT)res_end );

    putenv( preloader_reserve );
    putenv( socket_env );

    return loader_exec( argv, machine );
}


/***********************************************************************
 *           exec_wineserver
 *
 * Exec a new wine server.
 */
static int exec_wineserver( pid_t *pid, char **argv )
{
    char *path;

    if (!is_win64 && alt_build_dir)  /* look for 64-bit server */
        return build_path_and_exec( pid, alt_build_dir, "server/wineserver", argv );

    if (build_dir)
        return build_path_and_exec( pid, build_dir, "server/wineserver", argv );

    if (!build_path_and_exec( pid, bin_dir, "wineserver", argv )) return 0;
    if ((path = getenv( "WINESERVER" )) && !build_path_and_exec( pid, "", path, argv )) return 0;

    if ((path = getenv( "PATH" )))
    {
        for (path = strtok( strdup( path ), ":" ); path; path = strtok( NULL, ":" ))
            if (!build_path_and_exec( pid, path, "wineserver", argv )) return 0;
    }
    return build_path_and_exec( pid, BINDIR, "wineserver", argv );
}


/***********************************************************************
 *           start_server
 *
 * Start a new wine server.
 */
void start_server( BOOL debug )
{
#ifdef WINE_IOS
    /* Wineserver already running as thread on iOS */
    return;
#else
    static BOOL started;  /* we only try once */
    char *argv[3];
    static char debug_flag[] = "-d";

    if (!started)
    {
        int status;
        pid_t pid;

        argv[1] = debug ? debug_flag : NULL;
        argv[2] = NULL;
        if (exec_wineserver( &pid, argv )) fatal_error( "could not exec wineserver\n" );
        waitpid( pid, &status, 0 );
        status = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        if (status == 2) return;  /* server lock held by someone else, will retry later */
        if (status) exit(status);  /* server failed */
        started = TRUE;
    }
#endif
}


#ifdef SO_DLLS_SUPPORTED

/* adjust an array of pointers to make them into RVAs */
static inline void fixup_rva_ptrs( void *array, BYTE *base, unsigned int count )
{
    BYTE **src = array;
    DWORD *dst = array;

    for ( ; count; count--, src++, dst++) *dst = *src ? *src - base : 0;
}

/* fixup an array of RVAs by adding the specified delta */
static inline void fixup_rva_dwords( DWORD *ptr, int delta, unsigned int count )
{
    for ( ; count; count--, ptr++) if (*ptr) *ptr += delta;
}


/* fixup an array of name/ordinal RVAs by adding the specified delta */
static inline void fixup_rva_names( UINT_PTR *ptr, int delta )
{
    for ( ; *ptr; ptr++) if (!(*ptr & IMAGE_ORDINAL_FLAG)) *ptr += delta;
}


/* fixup RVAs in the resource directory */
static void fixup_so_resources( IMAGE_RESOURCE_DIRECTORY *dir, BYTE *root, int delta )
{
    IMAGE_RESOURCE_DIRECTORY_ENTRY *entry = (IMAGE_RESOURCE_DIRECTORY_ENTRY *)(dir + 1);
    unsigned int i;

    for (i = 0; i < dir->NumberOfNamedEntries + dir->NumberOfIdEntries; i++, entry++)
    {
        void *ptr = root + entry->OffsetToDirectory;
        if (entry->DataIsDirectory) fixup_so_resources( ptr, root, delta );
        else fixup_rva_dwords( &((IMAGE_RESOURCE_DATA_ENTRY *)ptr)->OffsetToData, delta, 1 );
    }
}

/***********************************************************************
 *           fill_builtin_image_info
 */
static void fill_builtin_image_info( void *module, struct pe_image_info *info )
{
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)module;
    const IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)((const BYTE *)dos + dos->e_lfanew);

    memset( info, 0, sizeof(*info) );
    info->base            = nt->OptionalHeader.ImageBase;
    info->entry_point     = nt->OptionalHeader.AddressOfEntryPoint;
    info->map_size        = nt->OptionalHeader.SizeOfImage;
    info->stack_size      = nt->OptionalHeader.SizeOfStackReserve;
    info->stack_commit    = nt->OptionalHeader.SizeOfStackCommit;
    info->subsystem       = nt->OptionalHeader.Subsystem;
    info->subsystem_minor = nt->OptionalHeader.MinorSubsystemVersion;
    info->subsystem_major = nt->OptionalHeader.MajorSubsystemVersion;
    info->osversion_major = nt->OptionalHeader.MajorOperatingSystemVersion;
    info->osversion_minor = nt->OptionalHeader.MinorOperatingSystemVersion;
    info->image_charact   = nt->FileHeader.Characteristics;
    info->dll_charact     = nt->OptionalHeader.DllCharacteristics;
    info->machine         = nt->FileHeader.Machine;
    info->contains_code   = TRUE;
    info->wine_builtin    = TRUE;
    info->header_size     = nt->OptionalHeader.SizeOfHeaders;
    info->file_size       = nt->OptionalHeader.SizeOfImage;
    info->checksum        = nt->OptionalHeader.CheckSum;
}

/*************************************************************************
 *		map_so_dll
 *
 * Map a builtin dll in memory and fixup RVAs.
 */
static NTSTATUS map_so_dll( const IMAGE_NT_HEADERS *nt_descr, HMODULE module )
{
    static const char builtin_signature[32] = "Wine builtin DLL";
    IMAGE_DATA_DIRECTORY *dir;
    IMAGE_DOS_HEADER *dos;
    IMAGE_NT_HEADERS *nt;
    IMAGE_SECTION_HEADER *sec;
    BYTE *addr = (BYTE *)module;
    DWORD code_start, code_end, data_start, data_end;
    DWORD align_mask = nt_descr->OptionalHeader.SectionAlignment - 1;
    int delta, nb_sections = 2;  /* code + data */
    unsigned int i;

    code_start = (sizeof(IMAGE_DOS_HEADER)
                  + sizeof(builtin_signature)
                  + sizeof(IMAGE_NT_HEADERS)
                  + nb_sections * sizeof(IMAGE_SECTION_HEADER)
                  + align_mask) & ~align_mask;

    if (anon_mmap_fixed( addr, code_start, PROT_READ | PROT_WRITE, 0 ) != addr) return STATUS_NO_MEMORY;

    dos = (IMAGE_DOS_HEADER *)addr;
    nt  = (IMAGE_NT_HEADERS *)((BYTE *)(dos + 1) + sizeof(builtin_signature));
    sec = (IMAGE_SECTION_HEADER *)(nt + 1);

    /* build the DOS and NT headers */

    dos->e_magic    = IMAGE_DOS_SIGNATURE;
    dos->e_cblp     = 0x90;
    dos->e_cp       = 3;
    dos->e_cparhdr  = (sizeof(*dos) + 0xf) / 0x10;
    dos->e_minalloc = 0;
    dos->e_maxalloc = 0xffff;
    dos->e_ss       = 0x0000;
    dos->e_sp       = 0x00b8;
    dos->e_lfanew   = sizeof(*dos) + sizeof(builtin_signature);
    memcpy( dos + 1, builtin_signature, sizeof(builtin_signature) );

    *nt = *nt_descr;

    delta      = (const BYTE *)nt_descr - addr;
    data_start = delta & ~align_mask;
#ifdef __APPLE__
    {
        Dl_info dli;
        unsigned long data_size;
        /* need the mach_header, not the PE header, to give to getsegmentdata(3) */
        dladdr(addr, &dli);
        code_end   = getsegmentdata(dli.dli_fbase, "__DATA", &data_size) - addr;
        data_end   = (code_end + data_size + align_mask) & ~align_mask;
    }
#else
    code_end   = data_start;
    data_end   = (nt->OptionalHeader.SizeOfImage + delta + align_mask) & ~align_mask;
#endif

    fixup_rva_ptrs( &nt->OptionalHeader.AddressOfEntryPoint, addr, 1 );

    nt->FileHeader.NumberOfSections                = nb_sections;
    nt->OptionalHeader.BaseOfCode                  = code_start;
#ifndef _WIN64
    nt->OptionalHeader.BaseOfData                  = data_start;
#endif
    nt->OptionalHeader.SizeOfCode                  = code_end - code_start;
    nt->OptionalHeader.SizeOfInitializedData       = data_end - data_start;
    nt->OptionalHeader.SizeOfUninitializedData     = 0;
    nt->OptionalHeader.SizeOfImage                 = data_end;
    nt->OptionalHeader.ImageBase                   = (ULONG_PTR)addr;

    /* build the code section */

    memcpy( sec->Name, ".text", sizeof(".text") );
    sec->SizeOfRawData = code_end - code_start;
    sec->Misc.VirtualSize = sec->SizeOfRawData;
    sec->VirtualAddress   = code_start;
    sec->PointerToRawData = code_start;
    sec->Characteristics  = (IMAGE_SCN_CNT_CODE | IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ);
    sec++;

    /* build the data section */

    memcpy( sec->Name, ".data", sizeof(".data") );
    sec->SizeOfRawData = data_end - data_start;
    sec->Misc.VirtualSize = sec->SizeOfRawData;
    sec->VirtualAddress   = data_start;
    sec->PointerToRawData = data_start;
    sec->Characteristics  = (IMAGE_SCN_CNT_INITIALIZED_DATA |
                             IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_READ);
    sec++;

    for (i = 0; i < nt->OptionalHeader.NumberOfRvaAndSizes; i++)
        fixup_rva_dwords( &nt->OptionalHeader.DataDirectory[i].VirtualAddress, delta, 1 );

    /* build the import directory */

    dir = &nt->OptionalHeader.DataDirectory[IMAGE_FILE_IMPORT_DIRECTORY];
    if (dir->Size)
    {
        IMAGE_IMPORT_DESCRIPTOR *imports = (IMAGE_IMPORT_DESCRIPTOR *)(addr + dir->VirtualAddress);

        while (imports->Name)
        {
            fixup_rva_dwords( &imports->OriginalFirstThunk, delta, 1 );
            fixup_rva_dwords( &imports->Name, delta, 1 );
            fixup_rva_dwords( &imports->FirstThunk, delta, 1 );
            if (imports->OriginalFirstThunk)
                fixup_rva_names( (UINT_PTR *)(addr + imports->OriginalFirstThunk), delta );
            if (imports->FirstThunk)
                fixup_rva_names( (UINT_PTR *)(addr + imports->FirstThunk), delta );
            imports++;
        }
    }

    /* build the resource directory */

    dir = &nt->OptionalHeader.DataDirectory[IMAGE_FILE_RESOURCE_DIRECTORY];
    if (dir->Size)
    {
        void *ptr = addr + dir->VirtualAddress;
        fixup_so_resources( ptr, ptr, delta );
    }

    /* build the export directory */

    dir = &nt->OptionalHeader.DataDirectory[IMAGE_FILE_EXPORT_DIRECTORY];
    if (dir->Size)
    {
        IMAGE_EXPORT_DIRECTORY *exports = (IMAGE_EXPORT_DIRECTORY *)(addr + dir->VirtualAddress);

        fixup_rva_dwords( &exports->Name, delta, 1 );
        fixup_rva_dwords( &exports->AddressOfFunctions, delta, 1 );
        fixup_rva_dwords( &exports->AddressOfNames, delta, 1 );
        fixup_rva_dwords( &exports->AddressOfNameOrdinals, delta, 1 );
        fixup_rva_dwords( (DWORD *)(addr + exports->AddressOfNames), delta, exports->NumberOfNames );
        fixup_rva_ptrs( addr + exports->AddressOfFunctions, addr, exports->NumberOfFunctions );
    }

    /* build the delay import directory */

    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT];
    if (dir->Size)
    {
        IMAGE_DELAYLOAD_DESCRIPTOR *imports = (IMAGE_DELAYLOAD_DESCRIPTOR *)(addr + dir->VirtualAddress);

        while (imports->DllNameRVA)
        {
            fixup_rva_dwords( &imports->DllNameRVA, delta, 1 );
            fixup_rva_dwords( &imports->ModuleHandleRVA, delta, 1 );
            fixup_rva_dwords( &imports->ImportAddressTableRVA, delta, 1 );
            fixup_rva_dwords( &imports->ImportNameTableRVA, delta, 1 );
            fixup_rva_dwords( &imports->BoundImportAddressTableRVA, delta, 1 );
            fixup_rva_dwords( &imports->UnloadInformationTableRVA, delta, 1 );
            fixup_rva_names( (UINT_PTR *)(addr + imports->ImportNameTableRVA), delta );
            imports++;
        }
    }

    return STATUS_SUCCESS;
}

/***********************************************************************
 *           dlopen_dll
 */
static NTSTATUS dlopen_dll( const char *so_name, UNICODE_STRING *nt_name, void **ret_module,
                            struct pe_image_info *image_info, BOOL prefer_native )
{
    void *module, *handle;
    const IMAGE_NT_HEADERS *nt;

    handle = dlopen( so_name, RTLD_NOW );
    if (!handle)
    {
        WARN( "failed to load .so lib %s: %s\n", debugstr_a(so_name), dlerror() );
        return STATUS_INVALID_IMAGE_FORMAT;
    }

    if (!(nt = dlsym( handle, "__wine_spec_nt_header" )))
    {
        ERR( "invalid .so library %s, too old?\n", debugstr_a(so_name));
        return STATUS_INVALID_IMAGE_FORMAT;
    }

    module = (HMODULE)((nt->OptionalHeader.ImageBase + 0xffff) & ~0xffff);
    if (get_builtin_so_handle( module ))  /* already loaded */
    {
        fill_builtin_image_info( module, image_info );
        *ret_module = module;
        dlclose( handle );
        return STATUS_SUCCESS;
    }

    if (map_so_dll( nt, module ))
    {
        dlclose( handle );
        return STATUS_NO_MEMORY;
    }

    fill_builtin_image_info( module, image_info );
    if (prefer_native && (image_info->dll_charact & IMAGE_DLLCHARACTERISTICS_PREFER_NATIVE))
    {
        TRACE( "%s has prefer-native flag, ignoring builtin\n", debugstr_a(so_name) );
        dlclose( handle );
        return STATUS_IMAGE_ALREADY_LOADED;
    }

    if (virtual_create_builtin_view( module, nt_name, image_info, handle ))
    {
        dlclose( handle );
        return STATUS_NO_MEMORY;
    }
    *ret_module = module;
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           load_so_dll
 */
static NTSTATUS load_so_dll( void *args )
{
    static const WCHAR soW[] = {'.','s','o',0};
    struct load_so_dll_params *params = args;
    UNICODE_STRING *nt_name = &params->nt_name;
    OBJECT_ATTRIBUTES attr;
    UNICODE_STRING true_nt_name;
    struct pe_image_info info;
    char *unix_name;
    NTSTATUS status;
    DWORD len;

    if (get_load_order( nt_name ) == LO_DISABLED) return STATUS_DLL_NOT_FOUND;
    InitializeObjectAttributes( &attr, nt_name, OBJ_CASE_INSENSITIVE, 0, 0 );
    if (!get_nt_and_unix_names( &attr, &true_nt_name, &unix_name, FILE_OPEN, FALSE ))
    {
        /* remove .so extension from Windows name */
        len = nt_name->Length / sizeof(WCHAR);
        if (len > 3 && !wcsicmp( nt_name->Buffer + len - 3, soW )) nt_name->Length -= 3 * sizeof(WCHAR);

        status = dlopen_dll( unix_name, nt_name, params->module, &info, FALSE );
    }
    else status = STATUS_DLL_NOT_FOUND;

    free( unix_name );
    free( true_nt_name.Buffer );
    return status;
}

/* check if the library is the correct architecture */
/* only returns false for a valid library of the wrong arch */
static int check_library_arch( int fd )
{
#ifdef __APPLE__
    struct  /* Mach-O header */
    {
        unsigned int magic;
        unsigned int cputype;
    } header;

    if (read( fd, &header, sizeof(header) ) != sizeof(header)) return 1;
    if (header.magic != 0xfeedface) return 1;
    if (sizeof(void *) == sizeof(int)) return !(header.cputype >> 24);
    else return (header.cputype >> 24) == 1; /* CPU_ARCH_ABI64 */
#else
    struct  /* ELF header */
    {
        unsigned char magic[4];
        unsigned char class;
        unsigned char data;
        unsigned char version;
    } header;

    if (read( fd, &header, sizeof(header) ) != sizeof(header)) return 1;
    if (memcmp( header.magic, "\177ELF", 4 )) return 1;
    if (header.version != 1 /* EV_CURRENT */) return 1;
#ifdef WORDS_BIGENDIAN
    if (header.data != 2 /* ELFDATA2MSB */) return 1;
#else
    if (header.data != 1 /* ELFDATA2LSB */) return 1;
#endif
    if (sizeof(void *) == sizeof(int)) return header.class == 1; /* ELFCLASS32 */
    else return header.class == 2; /* ELFCLASS64 */
#endif
}

/***********************************************************************
 *           open_builtin_so_file
 */
static NTSTATUS open_builtin_so_file( char *name, OBJECT_ATTRIBUTES *attr, void **module,
                                      SECTION_IMAGE_INFORMATION *image_info, USHORT search_machine,
                                      USHORT load_machine, BOOL prefer_native )
{
    NTSTATUS status = STATUS_DLL_NOT_FOUND;
    int fd;
    char *end = name + strlen( name );

    if (search_machine != current_machine) return status;
    if (load_machine && load_machine != current_machine) return status;

    *module = NULL;
    strcpy( end, ".so" );
    if ((fd = open( name, O_RDONLY )) == -1) goto done;

    if (check_library_arch( fd ))
    {
        struct pe_image_info info;

        status = dlopen_dll( name, attr->ObjectName, module, &info, prefer_native );
        if (!status) virtual_fill_image_information( &info, image_info );
        else if (status != STATUS_IMAGE_ALREADY_LOADED)
        {
            ERR( "failed to load .so lib %s\n", debugstr_a(name) );
            status = STATUS_PROCEDURE_NOT_FOUND;
        }
    }
    else status = STATUS_NOT_SUPPORTED;

    close( fd );
 done:
    *end = 0;
    return status;
}

/***********************************************************************
 *           open_main_image_so_file
 */
static NTSTATUS open_main_image_so_file( const char *name, UNICODE_STRING *nt_name, void **module,
                                         SECTION_IMAGE_INFORMATION *image_info )
{
    struct pe_image_info pe_info;
    NTSTATUS status;

    /* remove .so extension from Windows name */
    if (nt_name->Length > 3 * sizeof(WCHAR))
    {
        static const WCHAR soW[] = {'.','s','o',0};
        WCHAR *p = nt_name->Buffer + nt_name->Length / sizeof(WCHAR);
        if (!wcsicmp( p - 3, soW ))
        {
            p[-3] = 0;
            nt_name->Length -= 3 * sizeof(WCHAR);
        }
    }
    status = dlopen_dll( name, nt_name, module, &pe_info, FALSE );
    if (!status) virtual_fill_image_information( &pe_info, image_info );
    return status;
}

extern NTSTATUS unwind_builtin_dll( void *args );
extern void unix_init_startup_info(void); /* env_ios.c — renamed from init_startup_info to avoid linker collision with win32u/window.c */

#else /* SO_DLLS_SUPPORTED */

static NTSTATUS open_builtin_so_file( char *name, OBJECT_ATTRIBUTES *attr, void **module,
                                      SECTION_IMAGE_INFORMATION *image_info, USHORT search_machine,
                                      USHORT load_machine, BOOL prefer_native )
{
    return STATUS_DLL_NOT_FOUND;
}

static NTSTATUS open_main_image_so_file( const char *name, UNICODE_STRING *nt_name, void **module,
                                         SECTION_IMAGE_INFORMATION *image_info )
{
    return STATUS_INVALID_IMAGE_FORMAT;
}

/* Forward declaration — find_builtin_dll is defined below */
static NTSTATUS find_builtin_dll( UNICODE_STRING *nt_name, ANSI_STRING *exp_name, void **module,
                                  SIZE_T *size_ptr, SECTION_IMAGE_INFORMATION *image_info,
                                  ULONG_PTR limit_low, ULONG_PTR limit_high, USHORT search_machine,
                                  USHORT load_machine, BOOL prefer_native, off_t offset );

static NTSTATUS load_so_dll( void *args )
{
    /* iOS: no .so files, but search WINEDLLPATH for PE builtins */
    struct load_so_dll_params *params = args;
    SECTION_IMAGE_INFORMATION info;
    SIZE_T size;
    return find_builtin_dll( &params->nt_name, NULL, params->module, &size, &info,
                             0, 0, current_machine, 0, FALSE, 0 );
}

static NTSTATUS unwind_builtin_dll( void *args )
{
    return STATUS_UNSUCCESSFUL;
}

#endif /* SO_DLLS_SUPPORTED */


#ifdef WINE_IOS
volatile uint64_t g_wine_unix_call_count = 0;

static NTSTATUS ios_wrap_unix_call(int index, void *args, unixlib_entry_t real_func)
{
    g_wine_unix_call_count++;
    /* X3c probe: trace the first unix calls of a mixed-mode child (the one
     * kind with a private ntdll) — its PE loader exits DLL_NOT_FOUND with
     * zero syscalls and no debug trace ever reaching the log. dbg_write
     * payloads are echoed so the PE side's own messages surface. */
    {
        static int ios_ecx_traced;
        if (ios_ecx_traced < 24 && ios_cur_ntdll_funcs())
        {
            static const char *ios_ecx_names[] = { "load_so_dll", "unwind_builtin_dll",
                "dbg_write", "server_call", "fd_to_handle", "handle_to_fd",
                "spawnvp", "time_precise", "push_jit_aliases" };
            int n = __sync_fetch_and_add(&ios_ecx_traced, 1);
            NTSTATUS st;
            if (index == 2)
            {
                struct { const char *str; unsigned int len; } *p = args;
                dprintf(2, "[ecx-trace] #%d dbg_write: %.*s", n,
                        p->len > 200 ? 200 : (int)p->len, p->str);
            }
            else if (index == 0)
            {
                struct load_so_dll_params *p = args;
                char nm[128]; int i, len = p->nt_name.Length / 2;
                if (len > 127) len = 127;
                for (i = 0; i < len; i++) nm[i] = (char)p->nt_name.Buffer[i];
                nm[len] = 0;
                dprintf(2, "[ecx-trace] #%d load_so_dll %s\n", n, nm);
            }
            else dprintf(2, "[ecx-trace] #%d %s(args=%p)\n", n,
                         index >= 0 && index < 9 ? ios_ecx_names[index] : "?", args);
            st = real_func(args);
            if (index != 2) dprintf(2, "[ecx-trace] #%d -> 0x%x\n", n, (unsigned)st);
            return st;
        }
    }
    return real_func(args);
}

extern NTSTATUS unixcall_ios_push_jit_aliases(void *args);  /* virtual_ios.c */
extern NTSTATUS unixcall_ios_register_hold_release(void *args);  /* ml618, virtual_ios.c */
extern NTSTATUS unixcall_ios_jit_alias_probe(void *args);        /* ml631, virtual_ios.c */
extern NTSTATUS unixcall_ios_mono_bridge_ptr(void *args);        /* ml648, virtual_ios.c */
extern NTSTATUS unixcall_ios_get_fex_arena(void *args);          /* ml800, virtual_ios.c */

static NTSTATUS ios_wrap_0(void *a) { return ios_wrap_unix_call(0, a, load_so_dll); }
static NTSTATUS ios_wrap_1(void *a) { return ios_wrap_unix_call(1, a, unwind_builtin_dll); }
static NTSTATUS ios_wrap_2(void *a) { return ios_wrap_unix_call(2, a, unixcall_wine_dbg_write); }
static NTSTATUS ios_wrap_3(void *a) { return ios_wrap_unix_call(3, a, unixcall_wine_server_call); }
static NTSTATUS ios_wrap_4(void *a) { return ios_wrap_unix_call(4, a, unixcall_wine_server_fd_to_handle); }
static NTSTATUS ios_wrap_5(void *a) { return ios_wrap_unix_call(5, a, unixcall_wine_server_handle_to_fd); }
static NTSTATUS ios_wrap_6(void *a) { return ios_wrap_unix_call(6, a, unixcall_wine_spawnvp); }
static NTSTATUS ios_wrap_7(void *a) { return ios_wrap_unix_call(7, a, system_time_precise); }
static NTSTATUS ios_wrap_8(void *a) { return ios_wrap_unix_call(8, a, unixcall_ios_push_jit_aliases); }
static NTSTATUS ios_wrap_9(void *a) { return ios_wrap_unix_call(9, a, unixcall_ios_register_hold_release); }
static NTSTATUS ios_wrap_10(void *a) { return ios_wrap_unix_call(10, a, unixcall_ios_jit_alias_probe); }
static NTSTATUS ios_wrap_11(void *a) { return ios_wrap_unix_call(11, a, unixcall_ios_mono_bridge_ptr); }
static NTSTATUS ios_wrap_12(void *a) { return ios_wrap_unix_call(12, a, unixcall_ios_get_fex_arena); }

static const unixlib_entry_t unix_call_funcs[] =
{
    ios_wrap_0, ios_wrap_1, ios_wrap_2, ios_wrap_3,
    ios_wrap_4, ios_wrap_5, ios_wrap_6, ios_wrap_7,
    ios_wrap_8, ios_wrap_9, ios_wrap_10, ios_wrap_11,   /* ml648 */
    ios_wrap_12,                                        /* ml800 */
};
#else
static const unixlib_entry_t unix_call_funcs[] =
{
    load_so_dll,
    unwind_builtin_dll,
    unixcall_wine_dbg_write,
    unixcall_wine_server_call,
    unixcall_wine_server_fd_to_handle,
    unixcall_wine_server_handle_to_fd,
    unixcall_wine_spawnvp,
    system_time_precise,
    unixcall_ios_push_jit_aliases,
    unixcall_ios_register_hold_release,
    unixcall_ios_jit_alias_probe,
    unixcall_ios_mono_bridge_ptr,   /* ml648 */
    unixcall_ios_get_fex_arena,     /* ml800 */
};
#endif


#ifdef _WIN64

static NTSTATUS wow64_load_so_dll( void *args ) { return STATUS_INVALID_IMAGE_FORMAT; }
static NTSTATUS wow64_unwind_builtin_dll( void *args ) { return STATUS_UNSUCCESSFUL; }

/* The four iOS-private entries below speak 64-bit-only argument structs
 * (host `void *` PEBs, host function pointers, 64-bit alias addresses) and
 * are spoken only by the native / ARM64EC side that owns the JIT pool.  A
 * 32-bit caller's struct has a different LAYOUT, not merely guest pointers,
 * so a +B conversion could not rescue it — refuse the call instead of
 * reading a mismatched struct and corrupting the alias tables.  The table
 * still has to be the same length as unix_call_funcs. */
static NTSTATUS wow64_ios_unsupported( void *args ) { return STATUS_NOT_SUPPORTED; }

const unixlib_entry_t unix_call_wow64_funcs[] =
{
    wow64_load_so_dll,
    wow64_unwind_builtin_dll,
    wow64_wine_dbg_write,
    wow64_wine_server_call,
    wow64_wine_server_fd_to_handle,
    wow64_wine_server_handle_to_fd,
    wow64_wine_spawnvp,
    system_time_precise,                 /* writes one LONGLONG through args */
    wow64_ios_unsupported,               /* ios_push_jit_aliases */
    wow64_ios_unsupported,               /* ios_register_hold_release */
    wow64_ios_unsupported,               /* ml631 ios_jit_alias_probe */
    wow64_ios_unsupported,               /* ml648 ios_mono_bridge_ptr */
    wow64_ios_unsupported,               /* ml800 ios_get_fex_arena */
};

#endif  /* _WIN64 */


static inline char *prepend( char *buffer, const char *str, size_t len )
{
    return memcpy( buffer - len, str, len );
}

static inline char *prepend_build_dir_path( char *ptr, const char *ext, const char *arch_dir,
                                            const char *top_dir, const char *build_dir )
{
    char *name = ptr;
    unsigned int namelen = strlen(name), extlen = strlen(ext);

    if (namelen > extlen && !strcmp( name + namelen - extlen, ext )) namelen -= extlen;
    ptr = prepend( ptr, arch_dir, strlen(arch_dir) );
    ptr = prepend( ptr, name, namelen );
    ptr = prepend( ptr, top_dir, strlen(top_dir) );
    ptr = prepend( ptr, build_dir, strlen(build_dir) );
    return ptr;
}


/***********************************************************************
 *	open_dll_file
 *
 * Open a file for a new dll. Helper for open_builtin_pe_file.
 */
static NTSTATUS open_dll_file( const char *name, OBJECT_ATTRIBUTES *attr, HANDLE *mapping )
{
    LARGE_INTEGER size;
    NTSTATUS status;
    HANDLE handle;

    if ((status = open_unix_file( &handle, name, GENERIC_READ | SYNCHRONIZE, attr, 0,
                                  FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
                                  FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE, NULL, 0 )))
    {
        if (status != STATUS_OBJECT_PATH_NOT_FOUND && status != STATUS_OBJECT_NAME_NOT_FOUND)
        {
            /* if the file exists but failed to open, report the error */
            struct stat st;
            if (!stat( name, &st )) return status;
        }
        /* otherwise continue searching */
        return STATUS_DLL_NOT_FOUND;
    }

    size.QuadPart = 0;
    status = NtCreateSection( mapping, STANDARD_RIGHTS_REQUIRED | SECTION_QUERY |
                              SECTION_MAP_READ | SECTION_MAP_EXECUTE,
                              NULL, &size, PAGE_EXECUTE_READ, SEC_IMAGE, handle );
    NtClose( handle );
    return status;
}


/***********************************************************************
 *           open_builtin_pe_file
 */
static NTSTATUS open_builtin_pe_file( const char *name, OBJECT_ATTRIBUTES *attr, void **module,
                                      SIZE_T *size, SECTION_IMAGE_INFORMATION *image_info,
                                      ULONG_PTR limit_low, ULONG_PTR limit_high,
                                      WORD machine, BOOL prefer_native, off_t offset )
{
    NTSTATUS status;
    HANDLE mapping;

    *module = NULL;
    status = open_dll_file( name, attr, &mapping );
    if (!status)
    {
        status = virtual_map_builtin_module( mapping, module, size, image_info,
                                             limit_low, limit_high, machine, prefer_native, offset );
        NtClose( mapping );
    }
    return status;
}


/***********************************************************************
 *           find_builtin_dll
 */
static NTSTATUS find_builtin_dll( UNICODE_STRING *nt_name, ANSI_STRING *exp_name, void **module,
                                  SIZE_T *size_ptr, SECTION_IMAGE_INFORMATION *image_info,
                                  ULONG_PTR limit_low, ULONG_PTR limit_high, USHORT search_machine,
                                  USHORT load_machine, BOOL prefer_native, off_t offset )
{
    unsigned int i, pos, len, namepos = 0, maxlen = 0;
    char *ptr = NULL, *file, *ext = NULL;
    const char *pe_dir = get_pe_dir( search_machine );
    const char *so_dir = get_so_dir( current_machine );
    const char *pe_build_dir = build_dir;
    OBJECT_ATTRIBUTES attr;
    NTSTATUS status = STATUS_DLL_NOT_FOUND;
    BOOL found_image = FALSE;

    InitializeObjectAttributes( &attr, nt_name, 0, 0, NULL );

    if (!exp_name || !exp_name->Length)
    {
        len = nt_name->Length / sizeof(WCHAR);
        for (i = 0; i < len; i++)
            if (nt_name->Buffer[i] == '/' || nt_name->Buffer[i] == '\\') namepos = i + 1;
        len -= namepos;
        if (!len) return STATUS_DLL_NOT_FOUND;
    }
    else len = exp_name->Length;

    if (build_dir)
    {
        if (alt_build_dir && search_machine == get_alt_machine( current_machine ))
            pe_build_dir = alt_build_dir;
        maxlen = max( strlen(build_dir), strlen(pe_build_dir) ) + sizeof("/programs/") + len;
    }
    maxlen = max( maxlen, dll_path_maxlen + 1 ) + len + sizeof("/aarch64-windows") + sizeof(".so");

    if (!(file = malloc( maxlen ))) return STATUS_NO_MEMORY;

    pos = maxlen - len - sizeof(".so");
    if (!exp_name || !exp_name->Length)
    {
        /* we don't want to depend on the current codepage here */
        for (i = 0; i < len; i++)
        {
            if (nt_name->Buffer[namepos + i] > 127) goto done;
            file[pos + i] = (char)nt_name->Buffer[namepos + i];
        }
    }
    else memcpy( file + pos, exp_name->Buffer, len );

    for (i = 0; i < len; i++)
    {
        if (file[pos + i] >= 'A' && file[pos + i] <= 'Z') file[pos + i] += 'a' - 'A';
        else if (file[pos + i] == '.') ext = file + pos + i;
    }
    file[pos + len] = 0;
    file[--pos] = '/';

    TRACE( "looking for %s for file %s\n", debugstr_a(file + pos + 1), debugstr_us(nt_name) );

    if (build_dir)
    {
        /* try as a dll */
        ptr = prepend_build_dir_path( file + pos, ".dll", pe_dir, "/dlls", pe_build_dir );
        status = open_builtin_pe_file( ptr, &attr, module, size_ptr, image_info,
                                       limit_low, limit_high, load_machine, prefer_native, offset );
        ptr = prepend_build_dir_path( file + pos, ".dll", "", "/dlls", build_dir );
        if (status != STATUS_DLL_NOT_FOUND) goto done;
        status = open_builtin_so_file( ptr, &attr, module, image_info,
                                       search_machine, load_machine, prefer_native );
        if (status != STATUS_DLL_NOT_FOUND) goto done;

        /* now as a program */
        ptr = prepend_build_dir_path( file + pos, ".exe", pe_dir, "/programs", pe_build_dir );
        status = open_builtin_pe_file( ptr, &attr, module, size_ptr, image_info,
                                       limit_low, limit_high, load_machine, prefer_native, offset );
        ptr = prepend_build_dir_path( file + pos, ".exe", "", "/programs", build_dir );
        if (status != STATUS_DLL_NOT_FOUND) goto done;
        status = open_builtin_so_file( ptr, &attr, module, image_info,
                                       search_machine, load_machine, prefer_native );
        if (status != STATUS_DLL_NOT_FOUND) goto done;
    }

    for (i = 0; dll_paths[i]; i++)
    {
        ptr = file + pos;
        ptr = prepend( ptr, pe_dir, strlen(pe_dir) );
        ptr = prepend( ptr, dll_paths[i], strlen(dll_paths[i]) );
        status = open_builtin_pe_file( ptr, &attr, module, size_ptr, image_info, limit_low, limit_high,
                                       load_machine, prefer_native, offset );
        /* use so dir for unix lib */
        ptr = file + pos;
        ptr = prepend( ptr, so_dir, strlen(so_dir) );
        ptr = prepend( ptr, dll_paths[i], strlen(dll_paths[i]) );
        if (status != STATUS_DLL_NOT_FOUND) goto done;
        status = open_builtin_so_file( ptr, &attr, module, image_info,
                                       search_machine, load_machine, prefer_native );
        if (status != STATUS_DLL_NOT_FOUND) goto done;
        ptr = prepend( file + pos, dll_paths[i], strlen(dll_paths[i]) );
        status = open_builtin_pe_file( ptr, &attr, module, size_ptr, image_info, limit_low, limit_high,
                                       load_machine, prefer_native, offset );
        if (status == STATUS_NOT_SUPPORTED)
        {
            found_image = TRUE;
            continue;
        }
        if (status != STATUS_DLL_NOT_FOUND) goto done;
        status = open_builtin_so_file( ptr, &attr, module, image_info,
                                       search_machine, load_machine, prefer_native );
        if (status == STATUS_NOT_SUPPORTED) found_image = TRUE;
        else if (status != STATUS_DLL_NOT_FOUND) goto done;
    }

    if (found_image) status = STATUS_NOT_SUPPORTED;
    WARN( "cannot find builtin library for %s\n", debugstr_us(nt_name) );
done:
    if (NT_SUCCESS(status) && ext)
    {
        strcpy( ext, ".so" );
        set_builtin_unixlib_name( *module, ptr );
    }
    free( file );
    return status;
}


/***********************************************************************
 *           load_builtin
 *
 * Load the builtin dll if specified by load order configuration.
 * Return STATUS_IMAGE_ALREADY_LOADED if we should keep the native one that we have found.
 */
NTSTATUS load_builtin( const struct pe_image_info *image_info, UNICODE_STRING *nt_name,
                       ANSI_STRING *exp_name, USHORT machine, SECTION_IMAGE_INFORMATION *info,
                       void **module, SIZE_T *size, ULONG_PTR limit_low, ULONG_PTR limit_high,
                       off_t offset )
{
#ifdef WINE_IOS
    /* iOS: still respect WINEDLLOVERRIDES=name= (LO_DISABLED) so users can
     * refuse to load specific DLLs (e.g. steamclient64 — packed unpacker
     * blows up Wine's loader). The original short-circuit below skips the
     * builtin .so search; we keep that, just gate it on the override. */
    {
        enum loadorder lo = get_load_order( nt_name );
        if (lo == LO_DISABLED)
        {
            TRACE( "iOS: %s disabled by WINEDLLOVERRIDES\n", debugstr_us(nt_name) );
            return STATUS_DLL_NOT_FOUND;
        }
    }
    /* On iOS, all PE DLLs are in the prefix (system32 symlinks to bundle).
     * Skip the builtin .so search — it causes mmap failures on iOS and
     * corrupts file descriptors.  Just tell the caller to use the PE file. */
    return STATUS_IMAGE_ALREADY_LOADED;
#else
    NTSTATUS status;
    USHORT search_machine = image_info->machine;
    enum loadorder loadorder = get_load_order( nt_name );

    if (loadorder == LO_DISABLED) return STATUS_DLL_NOT_FOUND;

    if (image_info->wine_builtin)
    {
        if (loadorder == LO_NATIVE) return STATUS_DLL_NOT_FOUND;
        loadorder = LO_BUILTIN_NATIVE;  /* load builtin, then fallback to the file we found */
    }
    else if (image_info->wine_fakedll)
    {
        TRACE( "%s is a fake Wine dll\n", debugstr_us(nt_name) );
        if (loadorder == LO_NATIVE) return STATUS_DLL_NOT_FOUND;
        loadorder = LO_BUILTIN;  /* builtin with no fallback since mapping a fake dll is not useful */
    }

    if (ios_is_arm64ec_cur() && image_info->is_hybrid && search_machine == IMAGE_FILE_MACHINE_AMD64)
        search_machine = current_machine;

    switch (loadorder)
    {
    case LO_NATIVE:
    case LO_NATIVE_BUILTIN:
        return STATUS_IMAGE_ALREADY_LOADED;
    case LO_BUILTIN:
        return find_builtin_dll( nt_name, exp_name, module, size, info, limit_low, limit_high,
                                 search_machine, machine, FALSE, offset );
    default:
        status = find_builtin_dll( nt_name, exp_name, module, size, info, limit_low, limit_high,
                                   search_machine, machine, (loadorder == LO_DEFAULT), offset );
        if (status == STATUS_DLL_NOT_FOUND || status == STATUS_NOT_SUPPORTED)
            return STATUS_IMAGE_ALREADY_LOADED;
        return status;
    }
#endif
}


/***********************************************************************
 *           load_unixlib_by_name
 */
NTSTATUS load_unixlib_by_name( const UNICODE_STRING *nt_name, void **handle_ret )
{
    unsigned int i, pos, namepos, maxlen = 0;
    unsigned int len = nt_name->Length / sizeof(WCHAR);
    const char *so_dir = get_so_dir( current_machine );
    char *ptr = NULL, *file, *ext = NULL;
    void *handle = NULL;

    if (!len) return STATUS_DLL_NOT_FOUND;

    for (i = namepos = 0; i < len; i++)
        if (nt_name->Buffer[i] == '/' || nt_name->Buffer[i] == '\\') break;

    if (i < len)  /* explicit path */
    {
        UNICODE_STRING true_nt_name;
        OBJECT_ATTRIBUTES attr;

        InitializeObjectAttributes( &attr, (UNICODE_STRING *)nt_name, 0, 0, NULL );
        if (!get_nt_and_unix_names( &attr, &true_nt_name, &file, FILE_OPEN, FALSE ))
            handle = dlopen( file, RTLD_NOW );
        free( true_nt_name.Buffer );
        goto done;
    }

    if (build_dir) maxlen = strlen(build_dir) + sizeof("/dlls/") + len;
    maxlen = max( maxlen, dll_path_maxlen + 1 ) + len + sizeof("/aarch64-unix") + sizeof(".so");

    if (!(file = malloc( maxlen ))) return STATUS_NO_MEMORY;

    pos = maxlen - len - 4;
    /* we don't want to depend on the current codepage here */
    for (i = 0; i < len; i++)
    {
        if (nt_name->Buffer[namepos + i] > 127) goto done;
        file[pos + i] = (char)nt_name->Buffer[namepos + i];
        if (file[pos + i] >= 'A' && file[pos + i] <= 'Z') file[pos + i] += 'a' - 'A';
        else if (file[pos + i] == '.') ext = file + pos + i;
    }
    file[pos + len] = 0;
    file[--pos] = '/';
    if (!ext) ext = file + pos + len;

    if (build_dir)
    {
        ptr = prepend_build_dir_path( file + pos, ".so", "", "/dlls", build_dir );
        strcpy( ext, ".so" );
        if ((handle = dlopen( ptr, RTLD_NOW ))) goto done;
    }

    strcpy( ext, ".so" );
    for (i = 0; dll_paths[i]; i++)
    {
        ptr = prepend( file + pos, so_dir, strlen(so_dir) );
        ptr = prepend( ptr, dll_paths[i], strlen(dll_paths[i]) );
        if ((handle = dlopen( ptr, RTLD_NOW ))) goto done;

        ptr = prepend( file + pos, dll_paths[i], strlen(dll_paths[i]) );
        if ((handle = dlopen( ptr, RTLD_NOW ))) goto done;
    }

 done:
    free( file );
    if (!handle) return STATUS_DLL_NOT_FOUND;
    *handle_ret = handle;
    return STATUS_SUCCESS;
}


/***************************************************************************
 *	get_machine_wow64_dir
 *
 * cf. GetSystemWow64Directory2.
 */
static const WCHAR *get_machine_wow64_dir( WORD machine )
{
    static const WCHAR system32[] = {'\\','?','?','\\','C',':','\\','w','i','n','d','o','w','s','\\','s','y','s','t','e','m','3','2','\\',0};
    static const WCHAR syswow64[] = {'\\','?','?','\\','C',':','\\','w','i','n','d','o','w','s','\\','s','y','s','w','o','w','6','4','\\',0};
    static const WCHAR sysarm32[] = {'\\','?','?','\\','C',':','\\','w','i','n','d','o','w','s','\\','s','y','s','a','r','m','3','2','\\',0};

    if (machine == native_machine) machine = IMAGE_FILE_MACHINE_TARGET_HOST;

    switch (machine)
    {
    case IMAGE_FILE_MACHINE_TARGET_HOST: return system32;
    case IMAGE_FILE_MACHINE_I386:        return syswow64;
    case IMAGE_FILE_MACHINE_ARMNT:       return sysarm32;
    default: return NULL;
    }
}


/***************************************************************************
 *	is_builtin_path
 *
 * Check if path is inside a system directory, to support loading builtins
 * when the corresponding file doesn't exist yet.
 */
BOOL is_builtin_path( const UNICODE_STRING *path, WORD *machine )
{
    unsigned int i, len = path->Length / sizeof(WCHAR), dirlen;
    const WCHAR *sysdir, *p = path->Buffer;

    /* only fake builtin existence during prefix bootstrap */
    if (!is_prefix_bootstrap) return FALSE;

    for (i = 0; i < supported_machines_count; i++)
    {
        sysdir = get_machine_wow64_dir( supported_machines[i] );
        if (!sysdir) continue;
        dirlen = wcslen( sysdir );
        if (len <= dirlen) continue;
        if (wcsnicmp( p, sysdir, dirlen )) continue;
        /* check for remaining path components */
        for (p += dirlen, len -= dirlen; len; p++, len--) if (*p == '\\') return FALSE;
        *machine = supported_machines[i];
        return TRUE;
    }
    return FALSE;
}


/***********************************************************************
 *           open_main_image
 */
static NTSTATUS open_main_image( UNICODE_STRING *nt_name, void **module, SECTION_IMAGE_INFORMATION *info,
                                 enum loadorder loadorder, USHORT machine )
{
    OBJECT_ATTRIBUTES attr;
    SIZE_T size = 0;
    char *unix_name;
    NTSTATUS status;
    HANDLE mapping;
    UNICODE_STRING true_nt_name;

    if (loadorder == LO_DISABLED) NtTerminateProcess( GetCurrentProcess(), STATUS_DLL_NOT_FOUND );

    InitializeObjectAttributes( &attr, nt_name, OBJ_CASE_INSENSITIVE, 0, NULL );
    if (get_nt_and_unix_names( &attr, &true_nt_name, &unix_name, FILE_OPEN, FALSE ))
    {
        dprintf(2, "[main-exe] get_nt_and_unix_names FAILED for main image\n");
        return STATUS_DLL_NOT_FOUND;
    }

    status = open_dll_file( unix_name, &attr, &mapping );
    dprintf(2, "[main-exe] open_dll_file('%s') = 0x%x\n", unix_name, (unsigned)status);
    if (!status)
    {
        status = virtual_map_module( mapping, module, &size, info, 0, 0, machine );
        dprintf(2, "[main-exe] virtual_map_module = 0x%x Machine=0x%x chars=0x%x\n",
                (unsigned)status, info->Machine, info->ImageCharacteristics);
        if (status == STATUS_IMAGE_MACHINE_TYPE_MISMATCH && info->ComPlusNativeReady)
        {
            info->Machine = native_machine;
            status = STATUS_SUCCESS;
        }
        NtClose( mapping );
    }
    else if (status == STATUS_INVALID_IMAGE_NOT_MZ && loadorder != LO_NATIVE)
    {
        status = open_main_image_so_file( unix_name, attr.ObjectName, module, info );
    }
    free( unix_name );
    free( true_nt_name.Buffer );
    return status;
}


/***********************************************************************
 *           load_main_exe
 */
NTSTATUS load_main_exe( UNICODE_STRING *nt_name, USHORT load_machine, void **module )
{
    enum loadorder loadorder = get_load_order( nt_name );
    unsigned int status;
    SIZE_T size;
    USHORT search_machine;

    status = open_main_image( nt_name, module, &main_image_info, loadorder, load_machine );
    if (status != STATUS_DLL_NOT_FOUND) return status;

    /* if path is in system dir, we can load the builtin even if the file itself doesn't exist */
    if (loadorder != LO_NATIVE && is_builtin_path( nt_name, &search_machine ))
    {
        status = find_builtin_dll( nt_name, NULL, module, &size, &main_image_info, 0, 0,
                                   search_machine, load_machine, FALSE, 0 );
        dprintf(2, "[main-exe] builtin-path retry: find_builtin_dll(search_machine=0x%x) = 0x%x Machine=0x%x\n",
                search_machine, (unsigned)status, main_image_info.Machine);
    }
    return status;
}


/***********************************************************************
 *           load_start_exe
 *
 * Load start.exe as main image.
 */
NTSTATUS load_start_exe( UNICODE_STRING *nt_name, void **module )
{
    static const WCHAR startW[] = {'s','t','a','r','t','.','e','x','e',0};
    unsigned int status;
    SIZE_T size;
    WCHAR *image = malloc( sizeof("\\??\\C:\\windows\\system32\\start.exe") * sizeof(WCHAR) );

    wcscpy( image, get_machine_wow64_dir( current_machine ));
    wcscat( image, startW );
    init_unicode_string( nt_name, image );
    status = find_builtin_dll( nt_name, NULL, module, &size, &main_image_info, 0, 0, current_machine, 0, FALSE, 0 );
    if (!NT_SUCCESS(status))
    {
        MESSAGE( "wine: failed to load start.exe: %x\n", status );
        NtTerminateProcess( GetCurrentProcess(), status );
    }
    return status;
}

static ULONG_PTR find_ordinal_export( HMODULE module, const IMAGE_EXPORT_DIRECTORY *exports, DWORD ordinal )
{
    const DWORD *functions = (const DWORD *)((BYTE *)module + exports->AddressOfFunctions);

    if (ordinal >= exports->NumberOfFunctions) return 0;
    if (!functions[ordinal]) return 0;
    return (ULONG_PTR)module + functions[ordinal];
}

static ULONG_PTR find_named_export( HMODULE module, const IMAGE_EXPORT_DIRECTORY *exports,
                                    const char *name )
{
    const WORD *ordinals = (const WORD *)((BYTE *)module + exports->AddressOfNameOrdinals);
    const DWORD *names = (const DWORD *)((BYTE *)module + exports->AddressOfNames);
    int min = 0, max = exports->NumberOfNames - 1;

    while (min <= max)
    {
        int res, pos = (min + max) / 2;
        char *ename = (char *)module + names[pos];
        if (!(res = strcmp( ename, name ))) return find_ordinal_export( module, exports, ordinals[pos] );
        if (res > 0) max = pos - 1;
        else min = pos + 1;
    }
    return 0;
}

static inline void *get_rva( void *module, ULONG_PTR addr )
{
    return (BYTE *)module + addr;
}

static const void *get_module_data_dir( HMODULE module, ULONG dir, ULONG *size )
{
    const IMAGE_NT_HEADERS *nt = get_rva( module, ((IMAGE_DOS_HEADER *)module)->e_lfanew );
    const IMAGE_DATA_DIRECTORY *data;

    if (nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC)
        data = &((const IMAGE_NT_HEADERS64 *)nt)->OptionalHeader.DataDirectory[dir];
    else if (nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR32_MAGIC)
        data = &((const IMAGE_NT_HEADERS32 *)nt)->OptionalHeader.DataDirectory[dir];
    else
        return NULL;
    if (!data->VirtualAddress || !data->Size) return NULL;
    if (size) *size = data->Size;
    return get_rva( module, data->VirtualAddress );
}

/***********************************************************************
 *           load_ntdll_functions
 */
#ifdef WINE_IOS
/* S1 pseudo-processes: locations of the dispatcher slots in ntdll's PE
 * .data (unix-side view). Saved so wine_ios_child_main can verify (and
 * repair) the slots inside a child's fresh ntdll copy. */
void **ios_ntdll_syscall_dispatcher_ptr = NULL;
void **ios_ntdll_unix_call_dispatcher_ptr = NULL;
unixlib_handle_t *ios_ntdll_unixlib_handle_ptr = NULL;
#endif

static void load_ntdll_functions( HMODULE module )
{
    void **p__wine_syscall_dispatcher;
    void **p__wine_unix_call_dispatcher;
    void **p__wine_unix_call_dispatcher_arm64ec = NULL;
    unixlib_handle_t *p__wine_unixlib_handle;
    const IMAGE_EXPORT_DIRECTORY *exports;
    unsigned int *pios_teb_tsd_offset;

    exports = get_module_data_dir( module, IMAGE_DIRECTORY_ENTRY_EXPORT, NULL );
    assert( exports );

#define GET_FUNC(name) \
    if (!(p##name = (void *)find_named_export( module, exports, #name ))) \
        ERR( "%s not found\n", #name )

    GET_FUNC( DbgUiRemoteBreakin );
    GET_FUNC( KiRaiseUserExceptionDispatcher );
    GET_FUNC( KiUserExceptionDispatcher );
    GET_FUNC( KiUserApcDispatcher );
    GET_FUNC( KiUserCallbackDispatcher );
    GET_FUNC( LdrInitializeThunk );
    GET_FUNC( LdrSystemDllInitBlock );
    GET_FUNC( RtlUserThreadStart );
    GET_FUNC( __wine_ctrl_routine );
    GET_FUNC( __wine_syscall_dispatcher );
    GET_FUNC( __wine_unix_call_dispatcher );
    GET_FUNC( __wine_unixlib_handle );
    if (is_arm64ec())
    {
        GET_FUNC( __wine_unix_call_dispatcher_arm64ec );
        GET_FUNC( KiUserEmulationDispatcher );
    }
    *p__wine_syscall_dispatcher = __wine_syscall_dispatcher;
    *p__wine_unixlib_handle = (UINT_PTR)unix_call_funcs;
#ifdef WINE_IOS
    /* Publish the discovered raw TSD slot offset so ARM64EC modules (FEX)
     * import one authoritative value instead of hardcoding a slot. This runs
     * after the discovery in the init path above, so the offset is already
     * known and non-zero. */
    /* ml800: this publish is already generic — it runs from load_ntdll() for
     * whichever native PE ntdll this session loaded (aarch64-windows or
     * arm64ec-windows) and is NOT gated on is_arm64ec(). What it cannot do is
     * write into an export the PE does not have, and the shipped
     * aarch64-windows/ntdll.dll (PE timestamp 2026-08-02, SizeOfImage 0xf0000)
     * predates ntdll.spec's `ios_teb_tsd_offset` line: its export table jumps
     * straight from p_ios_jit_reverse_translate_addr (1451) to
     * __wine_unixlib_handle (1452), while arm64ec (1460) and i386 (1475) both
     * carry it. A 32-bit MAIN image runs on that aarch64 ntdll, so the WoW64
     * CPU module's GetProcAddress returns NULL and it refuses to start.
     *
     * The old GET_FUNC here reported that as a bare "not found", which is
     * indistinguishable from the dozens of other optional-export lines. Say
     * what is missing, in which module, and what breaks because of it. */
    {
        extern int ios_teb_tls_slot_offset;
        pios_teb_tsd_offset = (unsigned int *)find_named_export( module, exports, "ios_teb_tsd_offset" );
        if (pios_teb_tsd_offset)
        {
            *pios_teb_tsd_offset = (unsigned int)ios_teb_tls_slot_offset;
            dprintf( 2, "[teb-tsd] published offset=0x%x to ntdll export at %p (module %p)\n",
                     *pios_teb_tsd_offset, pios_teb_tsd_offset, module );
        }
        else
            dprintf( 2, "[teb-tsd] FATAL-FOR-WOW64: native ntdll at %p does NOT export "
                        "ios_teb_tsd_offset (slot offset 0x%x stays unpublished). The WoW64 CPU "
                        "module refuses to run without it; rebuild this PE ntdll from "
                        "dlls/ntdll/ntdll.spec, which already declares the export.\n",
                     module, (unsigned int)ios_teb_tls_slot_offset );
    }
    /* ml797: hand the FEX arena to the PE side as plain data. It cannot travel
     * as an environment variable -- its consumer runs before any CRT or TEB
     * exists. Publishing zero is normal and means "no arena"; the emulator then
     * selects its own band exactly as before. */
    {
        extern ULONG_PTR ios_fex_arena_base_unix, ios_fex_arena_end_unix;
        ULONG_PTR *pbase = (ULONG_PTR *)find_named_export( module, exports, "ios_fex_arena_base" );
        ULONG_PTR *pend  = (ULONG_PTR *)find_named_export( module, exports, "ios_fex_arena_end" );
        if (pbase && pend)
        {
            *pbase = ios_fex_arena_base_unix;
            *pend  = ios_fex_arena_end_unix;
            ERR("[fex-arena] ml800 legacy ntdll-global write (NOT the live channel; the "
                "dispatcher now uses unix_ios_get_fex_arena) base=%p end=%p%s\n",
                (void *)*pbase, (void *)*pend,
                *pbase ? "" : " (no arena reserved this run -- emulator selects its own band)");
        }
        else ERR("[fex-arena] ml797 channel BROKEN: ntdll exports ios_fex_arena_base/end NOT FOUND "
                 "(base=%p end=%p) -- the arena can never reach the emulator\n", pbase, pend);
    }
    ERR("syscall_dispatcher: p=%p *p=%p (unix func=%p)\n",
        p__wine_syscall_dispatcher, *p__wine_syscall_dispatcher, __wine_syscall_dispatcher);
    ERR("unix_call_dispatcher: p=%p *p=%p\n",
        p__wine_unix_call_dispatcher, __wine_unix_call_dispatcher);
#endif
    if (p__wine_unix_call_dispatcher_arm64ec)
    {
        /* redirect __wine_unix_call_dispatcher to __wine_unix_call_dispatcher_arm64ec */
        /* iOS-Madeira NOTE 2026-07-04: attempts 1-4 at de-faulting this slot
         * (~100 Mach faults/present) used a hand-encoded x18-restore stub at
         * pool rx_base+0x1000: (2) unmarked pool VA → routed into the x86
         * emulator by the icall checker; (3) same, observed directly
         * (State.rip = stub); (4) EC-marked stub → unix calls ran but a
         * thread hard-stuck at unix_call_dispatcher+0x60 burning 100% CPU.
         * The "frame contract" theory recorded then is WRONG — static
         * analysis (2026-07-04) shows direct entry is safe by construction:
         * the iOS dispatcher entry self-restores x18 from TPIDRRO_EL0 TLS,
         * and the `stp x30,x9(NZCV)` at [frame+0x100] implicitly ZEROES
         * restore_flags (0x10c) on every entry, so the return path is
         * per-call clean. The syscall-dispatcher slot has always held the
         * native unix address (fault-free direct entry at scale) — the
         * unix-call path is architecturally identical. Attempt 4's real
         * defects: an orphan non-module stub (no EC/SEH metadata, not
         * reverse-translatable, hand-assembled encodings) in BOTH slot
         * copies. Round 7 below instead uses the POOL ALIAS OF THE REAL EC
         * THUNK — the exact code the Mach redirect already lands on in the
         * working baseline, making post-entry state bit-identical to it. */
        *p__wine_unix_call_dispatcher = *p__wine_unix_call_dispatcher_arm64ec;
        *p__wine_unix_call_dispatcher_arm64ec = __wine_unix_call_dispatcher;
    }
    else *p__wine_unix_call_dispatcher = __wine_unix_call_dispatcher;

#ifdef WINE_IOS
    /* iOS: install JIT-translation hook into PE-side ntdll's
     * arm64ec_redirect_ptr. Without this, every IAT entry / redirected
     * entry-point holds a unix .text address, which iOS denies execute.
     * After the hook is set, redirect_ptr returns JIT-pool aliases. */
    {
        extern void *ios_jit_translate_addr(void *addr);
        extern void ios_jit_sync_write(void *addr, size_t size);
        /* Use dprintf to fd 2 (madeira-log) to bypass any ERR-channel filter. */
        dprintf( 2, "XLATE-HOOK enter: module=%p exports=%p\n",
                 module, exports );
        void **p_xlate = (void **)find_named_export( module, exports,
                                                     "p_ios_jit_translate_addr" );
        dprintf( 2, "XLATE-HOOK after find: p_xlate=%p is_arm64ec=%d\n",
                 p_xlate, is_arm64ec() );
        if (p_xlate)
        {
            *p_xlate = (void *)ios_jit_translate_addr;
            dprintf( 2, "XLATE-HOOK installed p_ios_jit_translate_addr=%p at %p\n",
                     ios_jit_translate_addr, p_xlate );
            ios_jit_sync_write( p_xlate, sizeof(void*) );
        }
        else dprintf( 2, "XLATE-HOOK p_ios_jit_translate_addr export NOT FOUND\n" );

        /* Reverse hook: pool alias → PE VA, used by PE ntdll's
         * virtual_unwind so exception walks over pool-executing frames
         * find their function tables (registered at PE VAs). */
        {
            extern void *ios_jit_reverse_translate_addr(const void *addr);
            void **p_xlate_rev = (void **)find_named_export( module, exports,
                                                             "p_ios_jit_reverse_translate_addr" );
            if (p_xlate_rev)
            {
                *p_xlate_rev = (void *)ios_jit_reverse_translate_addr;
                dprintf( 2, "XLATE-HOOK-REV installed p_ios_jit_reverse_translate_addr=%p at %p\n",
                         ios_jit_reverse_translate_addr, p_xlate_rev );
                ios_jit_sync_write( p_xlate_rev, sizeof(void*) );
            }
            else dprintf( 2, "XLATE-HOOK-REV export NOT FOUND\n" );
        }
    }

    /* Sync dispatcher pointers to JIT pool .data copy.
     * PE code in JIT pool reads from JIT .data (relocated addresses),
     * but we just wrote the dispatchers to original .data above. */
    {
        extern void ios_jit_sync_write(void *addr, size_t size);
        ios_jit_sync_write(p__wine_syscall_dispatcher, sizeof(void*));
        ios_jit_sync_write(p__wine_unix_call_dispatcher, sizeof(void*));
        ios_jit_sync_write(p__wine_unixlib_handle, sizeof(UINT_PTR));
        /* arm64ec ntdll has a separate slot for __wine_unix_call_arm64ec —
         * the thunk reads from there. Without syncing this to the JIT copy,
         * the PE-side thunk reads its OWN address back and infinite-loops. */
        if (p__wine_unix_call_dispatcher_arm64ec) {
            ios_jit_sync_write(p__wine_unix_call_dispatcher_arm64ec, sizeof(void*));
            ERR("synced arm64ec unix_call_dispatcher slot @ %p = %p\n",
                p__wine_unix_call_dispatcher_arm64ec, *p__wine_unix_call_dispatcher_arm64ec);
        }

        /* Verify: read back from JIT pool to confirm sync worked */
        {
            extern void *ios_jit_translate_addr(void *addr);
            /* The JIT pool copy of these pointers - PE code reads from here */
            void *jit_syscall_p = ios_jit_translate_addr(p__wine_syscall_dispatcher);
            void *jit_unixcall_p = ios_jit_translate_addr(p__wine_unix_call_dispatcher);
            void *jit_handle_p = ios_jit_translate_addr(p__wine_unixlib_handle);

            ERR("JIT .data verify:\n");
            ERR("  syscall_disp: orig@%p=0x%llx, jit@%p=0x%llx\n",
                p__wine_syscall_dispatcher, (unsigned long long)*(uint64_t*)p__wine_syscall_dispatcher,
                jit_syscall_p, (unsigned long long)*(uint64_t*)jit_syscall_p);
            ERR("  unix_call_disp: orig@%p=0x%llx, jit@%p=0x%llx\n",
                p__wine_unix_call_dispatcher, (unsigned long long)*(uint64_t*)p__wine_unix_call_dispatcher,
                jit_unixcall_p, (unsigned long long)*(uint64_t*)jit_unixcall_p);
            ERR("  unixlib_handle: orig@%p=0x%llx, jit@%p=0x%llx\n",
                p__wine_unixlib_handle, (unsigned long long)*(uint64_t*)p__wine_unixlib_handle,
                jit_handle_p, (unsigned long long)*(uint64_t*)jit_handle_p);
        }
        ERR("synced dispatchers to JIT .data\n");

        /* S1: remember the slot locations for child-copy verification */
        ios_ntdll_syscall_dispatcher_ptr = p__wine_syscall_dispatcher;
        ios_ntdll_unix_call_dispatcher_ptr = p__wine_unix_call_dispatcher;
        ios_ntdll_unixlib_handle_ptr = p__wine_unixlib_handle;
    }

    /* iOS-Madeira Round 7 (2026-07-04): de-fault the unix-call path.
     * Pool-executing EC callers read this slot and `blr` its value. With
     * the baseline PE VA they exec-fault (~100 Mach round trips/present,
     * ~0.5ms wall each = the bulk of the gameplay frame); the Mach handler
     * then redirects pc to the thunk's pool alias. Point the slot at that
     * pool alias DIRECTLY: same destination, no fault. The only machine-
     * state differences vs the fault path are the dead x16 value and the
     * handler's side effects (x18 fix — the dispatcher entry re-derives
     * x18 from TLS anyway; stale-VA telemetry — irrelevant here).
     * The pool address must be in the EC bitmap or checked indirect calls
     * route it into the x86 emulator (= attempts 2/3); the ntdll pool
     * image copy is normally already marked at copy time, but mark
     * explicitly and bail to baseline if the bitmap isn't up. */
    if (p__wine_unix_call_dispatcher_arm64ec && !getenv("MADEIRA_NO_UNIXCALL_DIRECT"))
    {
        extern void *ios_jit_translate_addr(void *addr);
        extern void ios_jit_sync_write(void *addr, size_t size);
        extern int ios_jit_mark_ec_range(const void *addr, size_t size);
        void *thunk_pe = *p__wine_unix_call_dispatcher;  /* __wine_unix_call_arm64ec PE VA */
        void *thunk_pool = ios_jit_translate_addr(thunk_pe);

        if (thunk_pool != thunk_pe && ios_jit_mark_ec_range(thunk_pool, 16))
        {
            *p__wine_unix_call_dispatcher = thunk_pool;
            ios_jit_sync_write(p__wine_unix_call_dispatcher, sizeof(void*));
            dprintf(2, "UNIXCALL-DIRECT: slot @ %p -> pool thunk %p (was PE %p)\n",
                    p__wine_unix_call_dispatcher, thunk_pool, thunk_pe);
        }
        else
            dprintf(2, "UNIXCALL-DIRECT: SKIPPED (pool=%p pe=%p) — keeping faulting baseline\n",
                    thunk_pool, thunk_pe);
    }
#endif
#undef GET_FUNC
}


/***********************************************************************
 *           load_ntdll_wow64_functions
 */
static void load_ntdll_wow64_functions( HMODULE module )
{
    const IMAGE_EXPORT_DIRECTORY *exports;
    /* WOW64_DESIGN.md §2/§3: every p* entry of LdrSystemDllInitBlock ends up
     * in a 32-bit CONTEXT (Eip/Pc for LdrInitializeThunk, the Ki*Dispatchers,
     * RtlUserThreadStart), so it must hold a GUEST address.  find_named_export
     * returns module + rva, i.e. HOST, so subtract B.  The one host-valued
     * member is ntdll_handle, and by the same rule it is published as the
     * guest base too: wow64.dll adds B back before using it as an HMODULE.
     * Outside a window wow_base is 0 and this is the classic identity.
     *
     * stage C review F5: the conversion must be NULL-preserving.
     * find_named_export() returns 0 for an export this ntdll does not have
     * (RtlpFreezeTimeBias and RtlpQueryProcessDebugInformationRemote are
     * genuinely absent in Wine's i386 ntdll), and a plain `- wow_base` would
     * publish -B there instead of the 0 that "not present" means. */
    ULONG_PTR wow_base = ios_wow_base();
#define TO_GUEST(v) ((v) ? (ULONG_PTR)(v) - wow_base : 0)

    exports = get_module_data_dir( module, IMAGE_FILE_EXPORT_DIRECTORY, NULL );
    assert( exports );

    pLdrSystemDllInitBlock->ntdll_handle = TO_GUEST( (ULONG_PTR)module );

#define GET_FUNC(name) pLdrSystemDllInitBlock->p##name = \
        TO_GUEST( find_named_export( module, exports, #name ) )
    GET_FUNC( KiUserApcDispatcher );
    GET_FUNC( KiUserCallbackDispatcher );
    GET_FUNC( KiUserExceptionDispatcher );
    GET_FUNC( LdrInitializeThunk );
    GET_FUNC( LdrSystemDllInitBlock );
    GET_FUNC( RtlUserThreadStart );
    GET_FUNC( RtlpFreezeTimeBias );
    GET_FUNC( RtlpQueryProcessDebugInformationRemote );
#undef GET_FUNC
#undef TO_GUEST

    /* host pointer: the unix side calls through this one directly */
    p__wine_ctrl_routine = (void *)find_named_export( module, exports, "__wine_ctrl_routine" );

#ifdef _WIN64
    {
        unixlib_handle_t *p__wine_unixlib_handle = (void *)find_named_export( module, exports,
                                                                              "__wine_unixlib_handle" );
        *p__wine_unixlib_handle = (UINT_PTR)unix_call_wow64_funcs;
    }
#endif

    /* also set the 32-bit LdrSystemDllInitBlock (guest address -> host).
     * Guarded: pLdrSystemDllInitBlock is now 0 if the 32-bit ntdll does not
     * export it, and writing at wow_base + 0 would scribble on guest page 0. */
    if (pLdrSystemDllInitBlock->pLdrSystemDllInitBlock)
        memcpy( (void *)((ULONG_PTR)pLdrSystemDllInitBlock->pLdrSystemDllInitBlock + wow_base),
                pLdrSystemDllInitBlock, sizeof(*pLdrSystemDllInitBlock) );
    else
        ERR( "[wow-window] 32-bit ntdll has no LdrSystemDllInitBlock export — "
             "its copy of the init block will stay zero\n" );
}


/***********************************************************************
 *           redirect_arm64ec_rva
 *
 * Redirect an address through the arm64ec redirection table.
 */
ULONG_PTR redirect_arm64ec_rva( void *base, ULONG_PTR rva, const IMAGE_ARM64EC_METADATA *metadata )
{
    const IMAGE_ARM64EC_REDIRECTION_ENTRY *map = get_rva( base, metadata->RedirectionMetadata );
    int min = 0, max = metadata->RedirectionMetadataCount - 1;

    while (min <= max)
    {
        int pos = (min + max) / 2;
        if (map[pos].Source == rva) return map[pos].Destination;
        if (map[pos].Source < rva) min = pos + 1;
        else max = pos - 1;
    }
    return rva;
}


/***********************************************************************
 *           redirect_ntdll_functions
 *
 * Redirect ntdll functions on arm64ec.
 */
static void redirect_ntdll_functions( HMODULE module )
{
    const IMAGE_LOAD_CONFIG_DIRECTORY *loadcfg;
    const IMAGE_ARM64EC_METADATA *metadata;

    if (!(loadcfg = get_module_data_dir( module, IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG, NULL ))) return;
    if (!(metadata = (void *)loadcfg->CHPEMetadataPointer)) return;
#define REDIRECT(name) \
    p##name = get_rva( module, redirect_arm64ec_rva( module, (char *)p##name - (char *)module, metadata ))
    REDIRECT( DbgUiRemoteBreakin );
    REDIRECT( KiRaiseUserExceptionDispatcher );
    REDIRECT( KiUserExceptionDispatcher );
    REDIRECT( KiUserApcDispatcher );
    REDIRECT( KiUserCallbackDispatcher );
    REDIRECT( KiUserEmulationDispatcher );
    REDIRECT( LdrInitializeThunk );
    REDIRECT( RtlUserThreadStart );
#undef REDIRECT
}


#ifdef WINE_IOS
/***********************************************************************
 * X3c: private ARM64EC ntdll for a cross-arch child pseudo-process.
 *
 * An AMD64 child under an aarch64 session cannot use the session ntdll
 * (no EC syscall thunks / KiUserEmulationDispatcher / load_arm64ec_module),
 * and it cannot share another image's .data anyway. Map the arm64ec build
 * as a SECOND ntdll image at a fresh VA: the standard map pipeline
 * (map_image_into_view → update_arm64ec_ranges → mprotect_exec) gives it a
 * pool copy, EC bitmap ranges, alias registration and x18 patching exactly
 * like any child-loaded DLL (proven by X1's per-child ucrtbase). The image
 * is child-unique, so no per-child copy pass is needed — but its dispatcher
 * slots must be wired the same way load_ntdll_functions does for the
 * session image (including the Round-7 EC unix-call swap), with every
 * PE-.data write synced into the pool copy.
 */
static int ios_load_child_ec_ntdll( PEB *child_peb )
{
    static WCHAR path[] = {'\\','?','?','\\','C',':','\\','w','i','n','d','o','w','s','\\',
                           's','y','s','t','e','m','3','2','\\','n','t','d','l','l','.','d','l','l',0};
    extern void ios_jit_sync_write(void *addr, size_t size);
    extern void *ios_jit_translate_addr(void *addr);
    extern void *ios_arm64ec_bitmap_base(void);
    const char *pe_dir = get_pe_dir( IMAGE_FILE_MACHINE_AMD64 );  /* owner-aware → /arm64ec-windows */
    unsigned int status;
    SECTION_IMAGE_INFORMATION info;
    OBJECT_ATTRIBUTES attr;
    UNICODE_STRING str;
    struct ios_ntdll_funcs funcs = { NULL };
    const IMAGE_EXPORT_DIRECTORY *exports;
    void *module;
    SIZE_T size = 0;
    char *name = NULL;

    init_unicode_string( &str, path );
    InitializeObjectAttributes( &attr, &str, 0, 0, NULL );

    if (build_dir) asprintf( &name, "%s%s/ntdll.dll", ntdll_dir, pe_dir );
    else asprintf( &name, "%s%s/ntdll.dll", dll_dir, pe_dir );

    dprintf(2, "[ec-child-ntdll] loading %s for peb=%p\n", name, (void *)child_peb);
    status = open_builtin_pe_file( name, &attr, &module, &size, &info, 0, 0,
                                   IMAGE_FILE_MACHINE_AMD64, FALSE, 0 );
    if (status == STATUS_IMAGE_NOT_AT_BASE) status = virtual_relocate_module( module );
    if (status)
    {
        dprintf(2, "[ec-child-ntdll] FAILED to load %s: 0x%x\n", name, status);
        free( name );
        return -1;
    }
    free( name );
    dprintf(2, "[ec-child-ntdll] mapped at %p size=0x%lx Machine=0x%x\n",
            module, (unsigned long)size, info.Machine);

    exports = get_module_data_dir( module, IMAGE_DIRECTORY_ENTRY_EXPORT, NULL );
    if (!exports)
    {
        dprintf(2, "[ec-child-ntdll] no export directory!\n");
        return -1;
    }

    {
        void **p__wine_syscall_dispatcher;
        void **p__wine_unix_call_dispatcher;
        void **p__wine_unix_call_dispatcher_arm64ec;
        unixlib_handle_t *p__wine_unixlib_handle;
        unsigned int *pios_teb_tsd_offset;

#define EC_GET(dst, sym) \
        if (!((dst) = (void *)find_named_export( module, exports, sym ))) \
            dprintf(2, "[ec-child-ntdll] export %s NOT FOUND\n", sym)

        EC_GET( funcs.LdrInitializeThunk,              "LdrInitializeThunk" );
        EC_GET( funcs.RtlUserThreadStart,              "RtlUserThreadStart" );
        EC_GET( funcs.KiUserExceptionDispatcher,       "KiUserExceptionDispatcher" );
        EC_GET( funcs.KiUserApcDispatcher,             "KiUserApcDispatcher" );
        EC_GET( funcs.KiUserCallbackDispatcher,        "KiUserCallbackDispatcher" );
        EC_GET( funcs.KiUserEmulationDispatcher,       "KiUserEmulationDispatcher" );
        EC_GET( funcs.KiRaiseUserExceptionDispatcher,  "KiRaiseUserExceptionDispatcher" );
        EC_GET( funcs.DbgUiRemoteBreakin,              "DbgUiRemoteBreakin" );
        EC_GET( p__wine_syscall_dispatcher,            "__wine_syscall_dispatcher" );
        EC_GET( p__wine_unix_call_dispatcher,          "__wine_unix_call_dispatcher" );
        EC_GET( p__wine_unix_call_dispatcher_arm64ec,  "__wine_unix_call_dispatcher_arm64ec" );
        EC_GET( p__wine_unixlib_handle,                "__wine_unixlib_handle" );
#undef EC_GET
        if (!funcs.LdrInitializeThunk || !p__wine_syscall_dispatcher || !p__wine_unixlib_handle)
            return -1;

        /* Same slot recipe as load_ntdll_functions for the session image. */
        *p__wine_syscall_dispatcher = __wine_syscall_dispatcher;
        *p__wine_unixlib_handle = (UINT_PTR)unix_call_funcs;
        {
            extern int ios_teb_tls_slot_offset;
            pios_teb_tsd_offset = (unsigned int *)find_named_export( module, exports,
                                                                     "ios_teb_tsd_offset" );
            if (pios_teb_tsd_offset)
            {
                *pios_teb_tsd_offset = (unsigned int)ios_teb_tls_slot_offset;
                dprintf(2, "[teb-tsd] ec-child published offset=0x%x\n", *pios_teb_tsd_offset);
            }
            else dprintf(2, "[teb-tsd] ec-child export ios_teb_tsd_offset NOT FOUND\n");
        }
        {
            /* ml797: same arena hand-off for a pseudo-process's own ntdll. */
            extern ULONG_PTR ios_fex_arena_base_unix, ios_fex_arena_end_unix;
            ULONG_PTR *pbase = (ULONG_PTR *)find_named_export( module, exports, "ios_fex_arena_base" );
            ULONG_PTR *pend  = (ULONG_PTR *)find_named_export( module, exports, "ios_fex_arena_end" );
            if (pbase && pend)
            {
                *pbase = ios_fex_arena_base_unix;
                *pend  = ios_fex_arena_end_unix;
                dprintf(2, "[fex-arena] ml797 ec-child channel WIRED base=%p end=%p\n",
                        (void *)*pbase, (void *)*pend);
            }
            else dprintf(2, "[fex-arena] ml797 ec-child exports ios_fex_arena_base/end NOT FOUND\n");
        }
        if (p__wine_unix_call_dispatcher_arm64ec)
        {
            /* Round-7 EC unix-call swap (see load_ntdll_functions). */
            *p__wine_unix_call_dispatcher = *p__wine_unix_call_dispatcher_arm64ec;
            *p__wine_unix_call_dispatcher_arm64ec = __wine_unix_call_dispatcher;
        }
        else if (p__wine_unix_call_dispatcher)
            *p__wine_unix_call_dispatcher = __wine_unix_call_dispatcher;

        /* JIT translate hooks, as for the session image. */
        {
            extern void *ios_jit_reverse_translate_addr(const void *addr);
            void **p_xlate = (void **)find_named_export( module, exports, "p_ios_jit_translate_addr" );
            void **p_xlate_rev = (void **)find_named_export( module, exports, "p_ios_jit_reverse_translate_addr" );
            if (p_xlate)     { *p_xlate = (void *)ios_jit_translate_addr;              ios_jit_sync_write( p_xlate, sizeof(void*) ); }
            else dprintf(2, "[ec-child-ntdll] p_ios_jit_translate_addr NOT FOUND\n");
            /* ml221: this used to install the reverse hook with NO log on either
             * outcome, so whether a CHILD ntdll copy got it was invisible. That matters:
             * each pseudo-process has its own cloned .data, hence its own
             * p_ios_jit_reverse_translate_addr, and if it stays NULL then
             * xlate_ios_jit_rev degrades to identity, virtual_unwind walks in JIT-pool
             * space where no function tables are registered, and the resulting garbage
             * frame trips "Exception frame is not in stack limits" -> process death. */
            if (p_xlate_rev)
            {
                *p_xlate_rev = (void *)ios_jit_reverse_translate_addr;
                ios_jit_sync_write( p_xlate_rev, sizeof(void*) );
                dprintf( 2, "[ec-child-ntdll] XLATE-REV installed at %p = %p\n",
                         p_xlate_rev, (void *)ios_jit_reverse_translate_addr );
            }
            else dprintf( 2, "[ec-child-ntdll] p_ios_jit_reverse_translate_addr NOT FOUND"
                             " -- unwind will run in pool space\n" );
        }

        /* Sync all written slots into the pool copy (PE code reads there). */
        ios_jit_sync_write( p__wine_syscall_dispatcher, sizeof(void*) );
        if (p__wine_unix_call_dispatcher) ios_jit_sync_write( p__wine_unix_call_dispatcher, sizeof(void*) );
        ios_jit_sync_write( p__wine_unixlib_handle, sizeof(UINT_PTR) );
        if (p__wine_unix_call_dispatcher_arm64ec)
            ios_jit_sync_write( p__wine_unix_call_dispatcher_arm64ec, sizeof(void*) );

        dprintf(2, "[ec-child-ntdll] syscall_disp slot %p -> pool %p\n",
                (void *)p__wine_syscall_dispatcher,
                ios_jit_translate_addr( p__wine_syscall_dispatcher ));
    }

    /* Redirect exported entry points to their EC variants (hybrid metadata),
     * mirroring redirect_ntdll_functions on the p* globals. */
    {
        const IMAGE_LOAD_CONFIG_DIRECTORY *loadcfg;
        const IMAGE_ARM64EC_METADATA *metadata;
        if ((loadcfg = get_module_data_dir( module, IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG, NULL )) &&
            (metadata = (void *)loadcfg->CHPEMetadataPointer))
        {
#define EC_REDIRECT(fld) \
            if (funcs.fld) funcs.fld = get_rva( module, redirect_arm64ec_rva( module, \
                                       (char *)funcs.fld - (char *)module, metadata ))
            EC_REDIRECT( LdrInitializeThunk );
            EC_REDIRECT( RtlUserThreadStart );
            EC_REDIRECT( KiUserExceptionDispatcher );
            EC_REDIRECT( KiUserApcDispatcher );
            EC_REDIRECT( KiUserCallbackDispatcher );
            EC_REDIRECT( KiUserEmulationDispatcher );
            EC_REDIRECT( KiRaiseUserExceptionDispatcher );
            EC_REDIRECT( DbgUiRemoteBreakin );
#undef EC_REDIRECT
        }
        else dprintf(2, "[ec-child-ntdll] no CHPE metadata — EC redirect skipped!\n");
    }

    /* The EC code bitmap is lazily created by the first hybrid AMD64 map;
     * only the creating PEB gets EcCodeBitMap set. Every EC child needs it
     * (arm64x_check_call reads TEB->Peb->EcCodeBitMap). */
    if (!child_peb->EcCodeBitMap) child_peb->EcCodeBitMap = ios_arm64ec_bitmap_base();
    dprintf(2, "[ec-child-ntdll] EcCodeBitMap=%p LdrInitializeThunk=%p (pool %p)\n",
            child_peb->EcCodeBitMap, funcs.LdrInitializeThunk,
            ios_jit_translate_addr( funcs.LdrInitializeThunk ));

    ios_set_proc_ntdll( child_peb, module, &funcs );
    return 0;
}
#endif


/***********************************************************************
 *           load_ntdll
 */
static void load_ntdll(void)
{
    static WCHAR path[] = {'\\','?','?','\\','C',':','\\','w','i','n','d','o','w','s','\\',
                           's','y','s','t','e','m','3','2','\\','n','t','d','l','l','.','d','l','l',0};
    const char *pe_dir = get_pe_dir( current_machine );
    USHORT machine = current_machine;
    unsigned int status;
    SECTION_IMAGE_INFORMATION info;
    OBJECT_ATTRIBUTES attr;
    UNICODE_STRING str;
    void *module;
    SIZE_T size = 0;
    char *name = NULL;

    init_unicode_string( &str, path );
    InitializeObjectAttributes( &attr, &str, 0, 0, NULL );

    if (build_dir) asprintf( &name, "%s%s/ntdll.dll", ntdll_dir, pe_dir );
    else asprintf( &name, "%s%s/ntdll.dll", dll_dir, pe_dir );

    if (is_arm64ec()) machine = main_image_info.Machine;
    status = open_builtin_pe_file( name, &attr, &module, &size, &info, 0, 0, machine, FALSE, 0 );
    if (status == STATUS_DLL_NOT_FOUND)
    {
        free( name );
        asprintf( &name, "%s/ntdll.dll%c.so", ntdll_dir, 0 );
        status = open_builtin_so_file( name, &attr, &module, &info, machine, 0, FALSE );
    }
    if (status == STATUS_IMAGE_NOT_AT_BASE) status = virtual_relocate_module( module );
    if (status) fatal_error( "failed to load %s error %x\n", name, status );
    free( name );
    load_ntdll_functions( module );
    if (is_arm64ec()) redirect_ntdll_functions( module );
}


/***********************************************************************
 *           map_apiset_schema
 *
 * Map <pe_dir(machine)>/apisetschema.dll and return the API_SET_NAMESPACE
 * inside the mapped view.  Split out of load_apiset_dll so the child boot
 * path can ask for a DIFFERENT machine's schema than the session's
 * `current_machine` (an i386 child under a 64-bit session needs
 * /i386-windows/apisetschema.dll, and it needs it mapped inside its own
 * guest window).  *view is the whole mapped view, for unmapping on rejection.
 */
static unsigned int map_apiset_schema( WORD machine, void **view, SIZE_T *view_size,
                                       API_SET_NAMESPACE **map_out )
{
    static WCHAR path[] = {'\\','?','?','\\','C',':','\\','w','i','n','d','o','w','s','\\',
                           's','y','s','t','e','m','3','2','\\',
                           'a','p','i','s','e','t','s','c','h','e','m','a','.','d','l','l',0};
    const char *pe_dir = get_pe_dir( machine );
    const IMAGE_NT_HEADERS *nt;
    const IMAGE_SECTION_HEADER *sec;
    API_SET_NAMESPACE *map;
    OBJECT_ATTRIBUTES attr;
    UNICODE_STRING str;
    unsigned int status;
    HANDLE handle, mapping;
    SIZE_T size;
    char *name = NULL;
    void *ptr;
    UINT i;

    *view = NULL;
    *view_size = 0;
    *map_out = NULL;

    init_unicode_string( &str, path );
    InitializeObjectAttributes( &attr, &str, 0, 0, NULL );

    if (build_dir) asprintf( &name, "%s/dlls/apisetschema%s/apisetschema.dll", build_dir, pe_dir );
    else asprintf( &name, "%s%s/apisetschema.dll", dll_dir, pe_dir );
    status = open_unix_file( &handle, name, GENERIC_READ | SYNCHRONIZE, &attr, 0,
                             FILE_SHARE_READ | FILE_SHARE_DELETE, FILE_OPEN,
                             FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE, NULL, 0 );
    free( name );

    if (!status)
    {
        status = NtCreateSection( &mapping, STANDARD_RIGHTS_REQUIRED | SECTION_QUERY | SECTION_MAP_READ,
                                  NULL, NULL, PAGE_READONLY, SEC_COMMIT, handle );
        NtClose( handle );
    }
    if (!status)
    {
        /* map_section() passes user_space_wow_limit as zero_bits; inside a
         * windowed (32-bit) pseudo-process ios_wow_translate_limits turns that
         * guest ceiling into [B, B+limit], which is what puts the view inside
         * the guest window.  Outside a window it is an ordinary host mapping. */
        status = map_section( mapping, &ptr, &size, PAGE_READONLY );
        NtClose( mapping );
    }
    if (status) return status;

    *view = ptr;
    *view_size = size;

    nt = get_rva( ptr, ((IMAGE_DOS_HEADER *)ptr)->e_lfanew );
    sec = IMAGE_FIRST_SECTION( nt );

    for (i = 0; i < nt->FileHeader.NumberOfSections; i++, sec++)
    {
        if (memcmp( (char *)sec->Name, ".apiset", 8 )) continue;
        map = (API_SET_NAMESPACE *)((char *)ptr + sec->PointerToRawData);
        if (sec->PointerToRawData < size &&
            size - sec->PointerToRawData >= sec->Misc.VirtualSize &&
            map->Version == 6 &&
            map->Size <= sec->Misc.VirtualSize)
        {
            *map_out = map;
            return STATUS_SUCCESS;
        }
        break;
    }
    NtUnmapViewOfSection( NtCurrentProcess(), ptr );
    *view = NULL;
    *view_size = 0;
    return STATUS_APISET_NOT_PRESENT;
}


/***********************************************************************
 *           load_apiset_dll
 */
static void load_apiset_dll(void)
{
    API_SET_NAMESPACE *map;
    unsigned int status;
    SIZE_T size;
    void *ptr;

    if ((status = map_apiset_schema( current_machine, &ptr, &size, &map )))
    {
        ERR( "failed to load apiset: %x\n", status );
        return;
    }
    peb->ApiSetMap = map;
    /* iOS-Madeira (WOW64_DESIGN.md §3 invariant 1): wow_peb holds
     * GUEST addresses.  When this process has no window the view is a plain
     * host mapping with no guest address at all, and PtrToUlong() would
     * publish a truncated host pointer that 32-bit ntdll would dereference in
     * get_apiset_entry().  Publish a guest address only if the view really is
     * inside the window; 0 means "no apiset", which get_apiset_entry()
     * handles as STATUS_APISET_NOT_PRESENT. */
    if (wow_peb)
        wow_peb->ApiSetMap = ios_wow_in_window( map ) ? ios_wow_guest_addr( map ) : 0;
    TRACE( "loaded apiset at %p\n", map );
}


#ifdef WINE_IOS
/***********************************************************************
 *           ios_child_load_apiset
 *
 * The child (CreateProcess) boot path never ran load_apiset_dll at all: it
 * clones the PEB of the 64-bit session process, so peb->ApiSetMap arrived as
 * an inherited host pointer and the 32-bit PEB — which is freshly zeroed
 * memory, not part of the sizeof(PEB) clone — kept ApiSetMap == 0.  The
 * 32-bit ntdll's get_apiset_entry() then reports STATUS_APISET_NOT_PRESENT
 * for every `api-ms-win-*` import, each one is retried as a real DLL file,
 * and loader_init fails the whole process with STATUS_DLL_NOT_FOUND.
 *
 * Two maps, two namespaces, one per half of the process:
 *   - peb->ApiSetMap   (HOST pointer) is what the 64-bit half — wow64.dll,
 *     the CPU DLL, every aarch64 module — consults.  The clone from the
 *     session PEB is a live view in this one shared address space, so it is
 *     reusable; it is only re-mapped when it is missing or not a v6 schema.
 *   - wow_peb->ApiSetMap (GUEST address) is what 32-bit code consults, and it
 *     must be the CHILD's machine's schema, mapped inside the child's own
 *     [B, B+4G) window.  map_section()'s user_space_wow_limit ceiling is what
 *     places it there (same mechanism the 32-bit MAIN path relies on).
 *
 * Must run after unix_init_startup_info() (which publishes wow_peb and the
 * guest ceiling) and before server_init_process_done().
 */
static void ios_child_load_apiset( WORD machine )
{
    API_SET_NAMESPACE *map;
    unsigned int status;
    SIZE_T size;
    void *ptr;

    /* --- 64-bit half ------------------------------------------------- */
    {
        const API_SET_NAMESPACE *cur = peb->ApiSetMap;

        /* Nothing is mapped below iOS's 4 GB __PAGEZERO, so a non-zero
         * sub-4 GB value is a truncated/guest pointer, never a host map. */
        if (!cur || (ULONG_PTR)cur < IOS_WOW_WINDOW_SIZE || cur->Version != 6)
        {
            if ((status = map_apiset_schema( native_machine, &ptr, &size, &map )))
                ERR( "[wow-apiset] child has no usable 64-bit apiset map (inherited %p) and "
                     "re-mapping the %04x schema failed: %x — api-ms-win-* names will not "
                     "resolve for the 64-bit half of this process\n",
                     peb->ApiSetMap, native_machine, status );
            else
            {
                peb->ApiSetMap = map;
                dprintf( STDERR_FILENO, "[wow-apiset] child 64-bit schema re-mapped at host %p\n", map );
            }
        }
    }

    /* --- 32-bit half -------------------------------------------------- */
    if (is_machine_64bit( machine )) return;

    if (!wow_peb)
    {
        ERR( "[wow-apiset] FAILED: i386 child has no 32-bit PEB (wow_peb=NULL) — every "
             "api-ms-win-* import will fail with STATUS_DLL_NOT_FOUND\n" );
        dprintf( STDERR_FILENO, "[wow-apiset] FAILED: i386 child has no wow_peb\n" );
        return;
    }
    if ((status = map_apiset_schema( machine, &ptr, &size, &map )))
    {
        ERR( "[wow-apiset] FAILED: cannot map %s/apisetschema.dll for the i386 child: %x — "
             "every api-ms-win-* import will fail with STATUS_DLL_NOT_FOUND\n",
             get_pe_dir( machine ), status );
        dprintf( STDERR_FILENO, "[wow-apiset] FAILED: map_apiset_schema(%04x) = 0x%x\n",
                 machine, status );
        wow_peb->ApiSetMap = 0;
        return;
    }
    if (!ios_wow_in_window( map ))
    {
        /* Publishing PtrToUlong(host) here is what invariant 1 forbids: the
         * guest would dereference a truncated host pointer.  Refuse loudly and
         * leave 0 (= STATUS_APISET_NOT_PRESENT) instead. */
        ERR( "[wow-apiset] FAILED: the i386 child's schema landed OUTSIDE its guest window "
             "(host %p, window %p, guest ceiling %p) — refusing to publish a truncated host "
             "pointer; api-ms-win-* imports will fail\n",
             map, (void *)ios_wow_base(), (void *)user_space_wow_limit );
        dprintf( STDERR_FILENO, "[wow-apiset] FAILED: schema host %p outside window %p\n",
                 map, (void *)ios_wow_base() );
        NtUnmapViewOfSection( NtCurrentProcess(), ptr );
        wow_peb->ApiSetMap = 0;
        return;
    }
    wow_peb->ApiSetMap = ios_wow_guest_addr( map );
    dprintf( STDERR_FILENO, "[wow-apiset] child i386 schema mapped at host %p = guest 0x%x "
             "(view %p+%p, wow_peb=%p)\n",
             map, (unsigned)wow_peb->ApiSetMap, ptr, (void *)size, wow_peb );
    ERR( "[wow-apiset] child i386 schema mapped at host %p = guest %08x\n",
         map, (unsigned)wow_peb->ApiSetMap );
}
#endif /* WINE_IOS */


/***********************************************************************
 *           load_wow64_ntdll
 */
static void load_wow64_ntdll( USHORT machine )
{
    static const WCHAR ntdllW[] = {'n','t','d','l','l','.','d','l','l',0};
    SECTION_IMAGE_INFORMATION info;
    UNICODE_STRING nt_name;
    void *module;
    unsigned int status;
    SIZE_T size;
    const WCHAR *wow64_dir;
    WCHAR *path;

    if (machine == current_machine) return;
    if (!(wow64_dir = get_machine_wow64_dir( machine ))) return;

    path = malloc( sizeof("\\??\\C:\\windows\\system32\\ntdll.dll") * sizeof(WCHAR) );
    wcscpy( path, wow64_dir );
    wcscat( path, ntdllW );
    init_unicode_string( &nt_name, path );
    status = find_builtin_dll( &nt_name, NULL, &module, &size, &info, 0, 0, machine, 0, FALSE, 0 );
    if (status == STATUS_IMAGE_NOT_AT_BASE) status = virtual_relocate_module( module );
    if (status) fatal_error( "failed to load %s error %x\n", debugstr_w(path), status );
    load_ntdll_wow64_functions( module );
    TRACE("loaded %s at %p\n", debugstr_w(path), module );
    free( path );
}


/***********************************************************************
 *           get_image_address
 */
static ULONG_PTR get_image_address(void)
{
#ifdef HAVE_GETAUXVAL
    ULONG_PTR size, num, phdr_addr = getauxval( AT_PHDR );
    ElfW(Phdr) *phdr;

    if (!phdr_addr) return 0;
    phdr = (ElfW(Phdr) *)phdr_addr;
    size = getauxval( AT_PHENT );
    num = getauxval( AT_PHNUM );
    while (num--)
    {
        if (phdr->p_type == PT_PHDR) return phdr_addr - phdr->p_offset;
        phdr = (ElfW(Phdr) *)((char *)phdr + size);
    }
#elif defined(__APPLE__) && defined(TASK_DYLD_INFO)
    struct task_dyld_info dyld_info;
    mach_msg_type_number_t size = TASK_DYLD_INFO_COUNT;

    if (task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&dyld_info, &size) == KERN_SUCCESS)
        return dyld_info.all_image_info_addr;
#endif
    return 0;
}

/***********************************************************************
 *           start_main_thread
 */
extern void ios_reserve_fex_arena(void);  /* ml756, virtual_ios.c */

static void start_main_thread(void)
{
#ifdef WINE_IOS
#define WINE_IOS_LOG(msg) do { os_log(OS_LOG_DEFAULT, "[Wine init] " msg); } while(0)
#else
#define WINE_IOS_LOG(msg)
#endif
#ifdef WINE_IOS
    /* Device-run fix: reserve this pseudo-process's guest window BEFORE the
     * first TEB, when the MAIN image is 32-bit.  Only wine_ios_child_main did
     * this before, so a 32-bit MAIN image (`wine hello-x86.exe`) ran with no
     * window — the image landed outside [B,B+4G) and build_wow64_parameters'
     * 2GB ceiling was unmappable below 4GB (assert !status).  The machine is
     * not known unix-side until unix_init_startup_info (after this point), so
     * the app publishes it in ios_main_image_i386.  The window is reserved
     * unbound/owner=this thread here; virtual_alloc_first_teb resolves it via
     * the owner fallback so the TEB block and PEB land inside it, and we bind
     * it to the PEB right after.  A 64-bit main image leaves the flag 0 and is
     * completely unaffected. */
    if (ios_main_image_i386)
    {
        NTSTATUS wst = ios_wow_window_reserve();
        if (wst)
        {
            /* Do NOT continue windowless: with B=0 the i386 image lands outside
             * any window, every guest pointer conversion is wrong, and boot
             * walks into the assert in build_wow64_parameters (env_ios.c).
             * fatal_error() is this file's startup-failure path and, on iOS,
             * pthread_exit()s just this pseudo-process's thread — pseudo-
             * processes are threads in one Mach task, so exit()/abort() would
             * take the whole app down with them. */
            dprintf( STDERR_FILENO,
                     "[wow-window] main-process reserve FAILED 0x%x — a 32-bit main image "
                     "cannot run without a guest window; terminating this process\n",
                     (unsigned)wst );
            fatal_error( "no WoW64 guest window for the 32-bit main image (status %x)\n",
                         (unsigned)wst );
        }
        else
            dprintf( STDERR_FILENO, "[wow-window] main-process window reserved (i386 main image)\n" );
    }
#endif
    WINE_IOS_LOG("virtual_alloc_first_teb...");
    TEB *teb = virtual_alloc_first_teb();
    WINE_IOS_LOG("virtual_alloc_first_teb done");
#ifdef WINE_IOS
    /* the PEB now exists (virtual_alloc_first_teb set the global `peb` and
     * teb->Peb); bind the window so every later ios_wow_base() lookup resolves
     * through the PEB (image map, build_wow64_parameters, 32-bit stack). */
    if (ios_main_image_i386 && ios_wow_base()) ios_wow_window_bind( peb );
#endif

#ifdef WINE_IOS
    /* Create TLS key for TEB storage BEFORE any PE loading.
     * The x18 binary patcher needs ios_teb_tls_slot_offset when generating
     * trampolines during mprotect_exec, which happens during load_ntdll. */
    {
        extern pthread_key_t ios_teb_tls_key;
        extern int ios_teb_tls_slot_offset;
        extern int ios_teb_tls_key_created;
        uintptr_t tsd_base;
        int slot = -1;

        if (!ios_teb_tls_key_created)
        {
            pthread_key_create(&ios_teb_tls_key, NULL);
            ios_teb_tls_key_created = 1;
        }

        __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd_base));
        tsd_base &= ~7ULL;

        /* Discover which raw TSD slot backs our key by writing a sentinel
         * through pthread_setspecific and looking for it.
         *
         * We used to skip this and simply write the TEB into slot 275, then
         * "discover" 275 by scanning for the TEB -- a scan that could only
         * ever find our own graffiti. 275 is a DYNAMIC pthread key that we do
         * not own: whoever calls pthread_key_create first gets it, and the
         * winner varies by device and by which frameworks have loaded. On an
         * M4 iPad the key went to something in the Metal stack brought up by
         * the first nextDrawable, which reset the slot to NULL; every x18
         * trampoline then loaded TEB=0 and the process died on TEB->PEB.
         *
         * Scanning for a sentinel rather than for the TEB matters: the TEB is
         * already reachable through wine's own teb_key, so a TEB scan can
         * match a slot we do not own. The sentinel is unique to this probe. */
        {
            void *const sentinel = (void *)(uintptr_t)0x5445425F534C4F54ULL; /* "TEB_SLOT" */
            pthread_setspecific(ios_teb_tls_key, sentinel);
            for (int s = 0; s < 512; s++)
            {
                if (*(void **)(tsd_base + s * 8) == sentinel) { slot = s; break; }
            }
            pthread_setspecific(ios_teb_tls_key, teb);
        }

        /* The slot must now hold the TEB, via the same base the trampolines
         * will use. Anything else and we do not understand the layout. */
        if (slot >= 0 && *(void **)(tsd_base + slot * 8) == teb)
        {
            ios_teb_tls_slot_offset = slot * 8;
            WINE_IOS_LOG("TEB TLS slot found");
            dprintf(STDERR_FILENO, "[teb-tsd] key=%d offset=0x%x verified=1 tsd_base=%p teb=%p\n",
                    (int)ios_teb_tls_key, ios_teb_tls_slot_offset, (void *)tsd_base, teb);
        }
        else
        {
            /* Never fall back to a fixed slot. A wrong offset is not a
             * degraded mode -- it is a guaranteed TEB=0 fault in every
             * patched module, arbitrarily far from here. */
            dprintf(STDERR_FILENO,
                    "[teb-tsd] FATAL: pthread key %d has no direct raw TSD slot "
                    "(sentinel slot=%d, tsd_base=%p, teb=%p)\n",
                    (int)ios_teb_tls_key, slot, (void *)tsd_base, teb);
            abort();
        }
    }
#endif
    WINE_IOS_LOG("signal_init_threading...");
    signal_init_threading();
    WINE_IOS_LOG("dbg_init...");
    dbg_init();
    WINE_IOS_LOG("server_init_process...");
    startup_info_size = server_init_process();
    WINE_IOS_LOG("server_init_process done");
    WINE_IOS_LOG("virtual_map_user_shared_data...");
    virtual_map_user_shared_data();
    WINE_IOS_LOG("init_cpu_info...");
    init_cpu_info();
    WINE_IOS_LOG("init_files...");
    init_files();
    WINE_IOS_LOG("init_startup_info...");
    unix_init_startup_info();
    *(ULONG_PTR *)&peb->CloudFileFlags = get_image_address();
    set_load_order_app_name( main_wargv[0] );
    WINE_IOS_LOG("init_thread_stack...");
    init_thread_stack( teb, 0, 0, 0 );
    /* iOS-Madeira: NAMED, and created through the same helper every child
     * pseudo-process uses.  wineserver handle tables are per pseudo-process, so
     * an anonymous handle created here would name a different object (or
     * nothing) in every later process that falls back to it — the same class of
     * bug as the GDI shared section.  See ios_default_keyed_event() in
     * wine/dlls/ntdll/unix/sync.c; the name is the one Windows uses. */
    keyed_event = ios_default_keyed_event();
    /* ml756: take FEX's host arena BEFORE any PE module is placed.
     *
     * This is the whole point of the placeholder: once guest DLLs start
     * loading they will occupy whatever FEX later wants, and no amount of
     * probing afterwards can reclaim it. Everything above -- server_init_process,
     * virtual_map_user_shared_data, init_thread_stack -- is already done, so
     * Wine's VM bookkeeping can record the view; load_ntdll() below is the
     * first PE placement. */
    WINE_IOS_LOG("ios_reserve_fex_arena...");
    ios_reserve_fex_arena();
    /* ml997: the guest jumbo holdback runs AFTER the arena, never before.
     * rdr65 held 9216 MB at jit-pool-init and the arena then found nothing in 9
     * candidates ("ml774 NO ARENA RESERVED"), which cost FEX its private band
     * and produced 683 failed 64KB RWX CodeBuffer allocations. The arena is
     * small and must win; the holdback takes what is left. */
    {
        extern void ios_jumbo_holdback_init( void );
        ios_jumbo_holdback_init();
    }

    WINE_IOS_LOG("load_ntdll...");
    load_ntdll();
    WINE_IOS_LOG("load_wow64_ntdll...");
    load_wow64_ntdll( main_image_info.Machine );
    WINE_IOS_LOG("load_apiset_dll...");
    load_apiset_dll();
    WINE_IOS_LOG("server_init_process_done...");
    server_init_process_done();
}

#ifdef __ANDROID__

#ifndef WINE_JAVA_CLASS
#define WINE_JAVA_CLASS "org/winehq/wine/WineActivity"
#endif

DECLSPEC_EXPORT JavaVM *java_vm = NULL;
DECLSPEC_EXPORT jobject java_object = 0;
DECLSPEC_EXPORT unsigned short java_gdt_sel = 0;

/* main Wine initialisation */
static jstring wine_init_jni( JNIEnv *env, jobject obj, jobjectArray cmdline, jobjectArray environment )
{
    char **argv;
    char *str;
    char error[1024];
    int i, argc, length;

    /* get the command line array */

    argc = (*env)->GetArrayLength( env, cmdline );
    for (i = length = 0; i < argc; i++)
    {
        jobject str_obj = (*env)->GetObjectArrayElement( env, cmdline, i );
        length += (*env)->GetStringUTFLength( env, str_obj ) + 1;
    }

    argv = malloc( (argc + 1) * sizeof(*argv) + length );
    str = (char *)(argv + argc + 1);
    for (i = 0; i < argc; i++)
    {
        jobject str_obj = (*env)->GetObjectArrayElement( env, cmdline, i );
        length = (*env)->GetStringUTFLength( env, str_obj );
        (*env)->GetStringUTFRegion( env, str_obj, 0,
                                    (*env)->GetStringLength( env, str_obj ), str );
        argv[i] = str;
        str[length] = 0;
        str += length + 1;
    }
    argv[argc] = NULL;

    /* set the environment variables */

    if (environment)
    {
        int count = (*env)->GetArrayLength( env, environment );
        for (i = 0; i < count - 1; i += 2)
        {
            jobject var_obj = (*env)->GetObjectArrayElement( env, environment, i );
            jobject val_obj = (*env)->GetObjectArrayElement( env, environment, i + 1 );
            const char *var = (*env)->GetStringUTFChars( env, var_obj, NULL );

            if (val_obj)
            {
                const char *val = (*env)->GetStringUTFChars( env, val_obj, NULL );
                setenv( var, val, 1 );
                if (!strcmp( var, "LD_LIBRARY_PATH" ))
                {
                    void (*update_func)( const char * ) = dlsym( RTLD_DEFAULT,
                                                                 "android_update_LD_LIBRARY_PATH" );
                    if (update_func) update_func( val );
                }
                else if (!strcmp( var, "WINEDEBUGLOG" ))
                {
                    int fd = open( val, O_WRONLY | O_CREAT | O_APPEND, 0666 );
                    if (fd != -1)
                    {
                        dup2( fd, 2 );
                        close( fd );
                    }
                }
                (*env)->ReleaseStringUTFChars( env, val_obj, val );
            }
            else unsetenv( var );

            (*env)->ReleaseStringUTFChars( env, var_obj, var );
        }
    }

    java_object = (*env)->NewGlobalRef( env, obj );

    main_argc = argc;
    main_argv = argv;

    init_paths();
    init_environment();

#ifdef __i386__
    {
        unsigned short java_fs;
        __asm__( "mov %%fs,%0" : "=r" (java_fs) );
        if (!(java_fs & 4)) java_gdt_sel = java_fs;
        __asm__( "mov %0,%%fs" :: "r" (0) );
        start_main_thread();
        __asm__( "mov %0,%%fs" :: "r" (java_fs) );
    }
#else
    start_main_thread();
#endif
    return (*env)->NewStringUTF( env, error );
}

jint JNI_OnLoad( JavaVM *vm, void *reserved )
{
    static const JNINativeMethod method =
    {
        "wine_init", "([Ljava/lang/String;[Ljava/lang/String;)Ljava/lang/String;", wine_init_jni
    };

    JNIEnv *env;
    jclass class;

    virtual_init();

    java_vm = vm;
    if ((*vm)->AttachCurrentThread( vm, &env, NULL ) != JNI_OK) return JNI_ERR;
    if (!(class = (*env)->FindClass( env, WINE_JAVA_CLASS ))) return JNI_ERR;
    (*env)->RegisterNatives( env, class, &method, 1 );
    return JNI_VERSION_1_6;
}

#endif  /* __ANDROID__ */

#ifdef __APPLE__
static void *apple_wine_thread( void *arg )
{
    start_main_thread();
    return NULL;
}

/***********************************************************************
 *           apple_create_wine_thread
 *
 * Spin off a secondary thread to complete Wine initialization, leaving
 * the original thread for the Mac frameworks.
 *
 * Invoked as a CFRunLoopSource perform callback.
 */
static void apple_create_wine_thread( void *arg )
{
    pthread_t thread;
    pthread_attr_t attr;

    pthread_attr_init( &attr );
    pthread_attr_setdetachstate( &attr, PTHREAD_CREATE_JOINABLE );
    if (pthread_create( &thread, &attr, apple_wine_thread, NULL )) exit(1);
    pthread_attr_destroy( &attr );
}


/***********************************************************************
 *           apple_main_thread
 *
 * Park the process's original thread in a Core Foundation run loop for
 * use by the Mac frameworks, especially receiving and handling
 * distributed notifications.  Spin off a new thread for the rest of the
 * Wine initialization.
 */
static void apple_main_thread(void)
{
    CFRunLoopSourceContext source_context = { 0 };
    CFRunLoopSourceRef source;

    if (!pthread_main_np()) return;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    /* Multi-processing Services can get confused about the main thread if the
     * first time it's used is on a secondary thread.  Use it here to make sure
     * that doesn't happen. */
    MPTaskIsPreemptive(MPCurrentTaskID());
#pragma clang diagnostic pop

    /* Give ourselves the best chance of having the distributed notification
     * center scheduled on this thread's run loop.  In theory, it's scheduled
     * in the first thread to ask for it. */
    CFNotificationCenterGetDistributedCenter();

    /* We use this run loop source for two purposes.  First, a run loop exits
     * if it has no more sources scheduled.  So, we need at least one source
     * to keep the run loop running.  Second, although it's not critical, it's
     * preferable for the Wine initialization to not proceed until we know
     * the run loop is running.  So, we signal our source immediately after
     * adding it and have its callback spin off the Wine thread. */
    source_context.perform = apple_create_wine_thread;
    source = CFRunLoopSourceCreate( NULL, 0, &source_context );
    CFRunLoopAddSource( CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes );
    CFRunLoopSourceSignal( source );
    CFRelease( source );
    CFRunLoopRun(); /* Should never return, except on error. */
}
#endif  /* __APPLE__ */


#if defined(__linux__) && !defined(__ANDROID__) && (defined(__i386__) || defined(__arm__))

static void check_vmsplit( void *stack )
{
    if (stack < (void *)0x80000000)
    {
        /* if the stack is below 0x80000000, assume we can safely try a munmap there */
        if (munmap( (void *)0x80000000, 1 ) == -1 && errno == EINVAL)
            ERR( "Warning: memory above 0x80000000 doesn't seem to be accessible.\n"
                 "Wine requires a 3G/1G user/kernel memory split to work properly.\n" );
    }
}

static int pre_exec(void)
{
    int temp;

    check_vmsplit( &temp );
    return 1;  /* we have a preloader on x86/arm */
}

#elif (defined(__FreeBSD__) || defined (__FreeBSD_kernel__) || defined(__DragonFly__))

static int pre_exec(void)
{
    struct rlimit rl;

    rl.rlim_cur = 0x02000000;
    rl.rlim_max = 0x02000000;
    setrlimit( RLIMIT_DATA, &rl );
    return 1;
}

#elif defined(__APPLE__)

static int pre_exec(void)
{
    if (build_dir)
    {
        char *path = getenv( "DYLD_LIBRARY_PATH" );
        if (path) asprintf( &path, "%s/dlls/ntdll:%s/dlls/win32u:%s", build_dir, build_dir, path );
        else asprintf( &path, "%s/dlls/ntdll:%s/dlls/win32u", build_dir, build_dir );
        setenv( "DYLD_LIBRARY_PATH", path, 1 );
        return 1;
    }
#ifdef HAVE_WINE_PRELOADER
    return 1;
#else
    return 0;
#endif
}

#else

static int pre_exec(void)
{
#ifdef HAVE_WINE_PRELOADER
    return 1;  /* we have a preloader */
#else
    return 0;  /* no exec needed */
#endif
}

#endif


static void reexec_loader( int argc, char *argv[], char *extra_arg )
{
    WORD machine = current_machine;
    char **new_argv;

    /* have to exec if we have a preloader, or an argument, or if we are the initial wrapper */
    if (!pre_exec() && !extra_arg && dlsym( RTLD_DEFAULT, "wine_main_preload_info" )) return;

    if (extra_arg)
    {
        new_argv = malloc( (argc + 3) * sizeof(*argv) );
        memcpy( new_argv + 3, argv + 1, argc * sizeof(*argv) );
        new_argv[2] = extra_arg;
    }
    else
    {
        new_argv = malloc( (argc + 2) * sizeof(*argv) );
        memcpy( new_argv + 2, argv + 1, argc * sizeof(*argv) );
    }

    /* default to 32-bit loader to support 32-bit prefixes */
    if (machine == IMAGE_FILE_MACHINE_AMD64) machine = IMAGE_FILE_MACHINE_I386;

    loader_exec( new_argv, machine );
    fatal_error( "could not exec the wine loader\n" );
}

/***********************************************************************
 *           check_command_line
 *
 * Check if command line is one that needs to be handled specially.
 */
static void check_command_line( int argc, char *argv[] )
{
    char *basename;
    static const char usage[] =
        "Usage: wine PROGRAM [ARGUMENTS...]   Run the specified program\n"
        "       wine --help                   Display this help and exit\n"
        "       wine --version                Output version information and exit";

    if ((basename = strrchr( argv[0], '/' ))) basename++;
    else basename = argv[0];

    if (strcmp( basename, "wine" )) /* check if there's a builtin exe corresponding to the base name */
    {
        const char *pe_dir = get_pe_dir( current_machine );
        char *exe;

        if (build_dir)
        {
            asprintf( &exe, "%s/programs/%s%s/%s.exe", build_dir, basename, pe_dir, basename );
            if (!access( exe, R_OK )) reexec_loader( argc, argv, basename );
            free( exe );
        }
        else
        {
            for (int i = 0; dll_paths[i]; i++)
            {
                asprintf( &exe, "%s%s/%s.exe", dll_paths[i], pe_dir, basename );
                if (!access( exe, R_OK )) reexec_loader( argc, argv, basename );
                free( exe );
            }
        }
    }

    if (argc <= 1)
    {
        fprintf( stderr, "%s\n", usage );
        exit(1);
    }
    if (!strcmp( argv[1], "--help" ))
    {
        printf( "%s\n", usage );
        exit(0);
    }
    if (!strcmp( argv[1], "--version" ))
    {
        printf( "%s\n", wine_build );
        exit(0);
    }

    reexec_loader( argc, argv, NULL );
}


#ifdef WINE_IOS
/***********************************************************************
 *           wine_ios_child_main
 *
 * Entry point for child Wine "processes" on iOS.
 * Instead of fork+exec, the parent creates a thread that calls this.
 * Does a minimal subset of __wine_main/start_main_thread init.
 */
extern size_t server_init_process_child( int child_fd_socket );

DECLSPEC_EXPORT void wine_ios_child_main( int argc, char *argv[], int child_fd_socket )
{
    /* set by the spawner (process_ios.c) and updated as this child boots, so a
     * failure anywhere on the path names the stage exactly once */
    extern _Thread_local const char *ios_child_boot_stage;
    extern _Thread_local WORD ios_child_main_machine;
    TEB *teb;
    PEB *child_peb;
    NTSTATUS status;

    dprintf(STDERR_FILENO, "[Wine child] wine_ios_child_main: argc=%d argv[1]=%s fd=%d\n",
            argc, argc > 1 ? argv[1] : "(none)", child_fd_socket);

    /* WOW64_DESIGN.md §2: every early-return below used to be a bare dprintf,
     * so a child that died during bring-up produced no ERR at all and the
     * parent simply never saw a process appear.  CHILD_STAGE() names the stage
     * the child is in; CHILD_BOOT_FAIL() is the single exit that reports it. */
#define CHILD_STAGE(s)  (ios_child_boot_stage = (s))
#define CHILD_BOOT_FAIL(fmt, ...)                                                       \
    do {                                                                                \
        dprintf( STDERR_FILENO, "[Wine child] BOOT FAILED at stage '%s': " fmt,          \
                 ios_child_boot_stage, ##__VA_ARGS__ );                                  \
        ERR( "[Wine child] boot FAILED at stage '%s' for %s: " fmt,                      \
             ios_child_boot_stage, argc > 1 ? argv[1] : "?", ##__VA_ARGS__ );            \
        return;                                                                         \
    } while (0)
    CHILD_STAGE( "entry" );

    /* X1 recon: EC-ness is currently session-wide (main_image_info /
     * current_machine are shared ntdll-unix globals). Log what this child
     * inherits — an AMD64 child under an ARM64 session (or vice versa)
     * resolves the WRONG pe_dir / dll set until these go per-process. */
    dprintf(STDERR_FILENO, "[x64-child] session: is_arm64ec=%d main_machine=0x%x current_machine=0x%x exe=%s\n",
            is_arm64ec(), main_image_info.Machine, current_machine,
            argc > 1 ? argv[1] : "?");

    /* WOW64_DESIGN.md §2: a 32-bit child gets its own [B, B+4G) guest window,
     * reserved HERE — before the TEB/PEB pair, because that pair has to live
     * inside it (guest code reads TEB32->Self, TEB32->Peb and the 32-bit
     * process parameters as guest addresses < 4 GB).  ios_child_main_machine
     * is published by the parent's spawn path; unix_init_startup_info, the
     * usual source of the machine, only runs much further down.  The window
     * is bound to the child's PEB as soon as that exists. */
    {
        int child_is_i386 = ios_child_main_machine &&
                            !is_machine_64bit( ios_child_main_machine );

        /* One line with everything needed to tell "this child is 32-bit and got
         * a window" from "the spawner never told us the machine" and from "the
         * one window slot was already gone" — the three shapes a silent
         * desktop-launched 32-bit child can have. */
        if (child_is_i386)
        {
            CHILD_STAGE( "guest-window-reserve" );
            status = ios_wow_window_reserve();
            dprintf(STDERR_FILENO, "[Wine child] i386 image %s machine=0x%x window=%p reserve=0x%x\n",
                    argc > 1 ? argv[1] : "(none)", ios_child_main_machine,
                    (void *)ios_wow_base(), (unsigned)status);
            ERR( "[Wine child] i386 image %s machine=%04x window=%p reserve=%x\n",
                 argc > 1 ? argv[1] : "(none)", ios_child_main_machine,
                 (void *)ios_wow_base(), (unsigned)status );
            if (status)
                CHILD_BOOT_FAIL( "guest window reserve returned 0x%x — a 32-bit child "
                                 "cannot start without one (the furniture band holds very "
                                 "few 4GB-aligned slots; see [wow-window] lines above)\n",
                                 (unsigned)status );
        }
        else
            dprintf(STDERR_FILENO, "[Wine child] 64-bit image %s machine=0x%x (no guest window)\n",
                    argc > 1 ? argv[1] : "(none)", ios_child_main_machine);
    }

    /* Allocate a new TEB for this child "process" thread */
    CHILD_STAGE( "virtual_alloc_teb" );
    status = virtual_alloc_teb( &teb );
    if (status)
        CHILD_BOOT_FAIL( "virtual_alloc_teb returned 0x%x\n", (unsigned)status );

    /* Allocate a SEPARATE PEB for this child "process".
     * Without this, parent and child share peb->Ldr (module list),
     * causing corruption when both PE loaders modify it. */
    if (ios_wow_base())
    {
        /* WOW64_DESIGN.md §2: a 32-bit child's PEB pair must be guest-
         * addressable — PEB32 sits at child_peb + page_size and the guest
         * reads it through TEB32->Peb.  Allocating through Wine (rather than
         * a raw mmap) both places it in this process's window and registers a
         * view there, so nothing else can be placed on top of it. */
        SIZE_T peb_size = 0x4000;

        CHILD_STAGE( "windowed-peb-alloc" );
        child_peb = NULL;
        status = NtAllocateVirtualMemory( NtCurrentProcess(), (void **)&child_peb, limit_4g - 1,
                                          &peb_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
        if (status)
            CHILD_BOOT_FAIL( "windowed PEB alloc returned 0x%x (window %p)\n",
                             (unsigned)status, (void *)ios_wow_base() );
        memset( child_peb, 0, 0x4000 );
    }
    else
    {
        CHILD_STAGE( "peb-mmap" );
        child_peb = mmap( NULL, 0x4000, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANON, -1, 0 );
        if (child_peb == MAP_FAILED)
            CHILD_BOOT_FAIL( "PEB mmap failed, errno=%d\n", errno );
    }
    /* Copy parent PEB — share heap, locks, etc. Clear LdrData so the child's
     * LdrInitializeThunk builds a fresh module list instead of traversing
     * the parent's (which crashes due to x18=0 zero-page corruption).
     * With shared JIT pool (same addresses), __ulock_wait works correctly.
     *
     * Clone from the INITIAL process's PEB, not the drifting global: child
     * init leaves `peb` pointed at that child (by design, see end of this
     * function), so the SECOND child used to inherit the FIRST child's
     * LIVE PEB — regedit cloned winemine's and crashed dispatching its
     * first window-proc callback (2026-07-06, blr x22=NULL from
     * KiUserCallbackDispatcher's chain). Spawns are serialized by the
     * parent's CreateProcess wait, so the one-time capture is safe. */
    {
        static PEB *ios_initial_peb;
        if (!ios_initial_peb) ios_initial_peb = peb;
        dprintf(STDERR_FILENO, "[Wine child] cloning PEB from initial %p (global peb=%p)\n",
                ios_initial_peb, peb);
        memcpy( child_peb, ios_initial_peb, sizeof(PEB) );
        /* Copy the debug channel table too. dbg_init() writes it at
         * peb + 2*page_size (0x2000) in the SESSION peb only; PE-side
         * __wine_dbg_get_channel_flags reads it from the CURRENT peb at the
         * same offset. Default flags live in the TERMINATOR entry, so a
         * zeroed region means default=0 = ALL channels (even err) silently
         * off. Session-copy children dodge this by inheriting the already-
         * initialized debug_options pointer in ntdll .data, but a freshly
         * mapped EC ntdll re-derives it from its own peb and goes mute. */
        {
            struct dbg_channel { unsigned char flags; char name[15]; };
            const struct dbg_channel *src = (const struct dbg_channel *)((char *)ios_initial_peb + 0x2000);
            unsigned int nb = 0;
            while (nb < 255 && src[nb].name[0]) nb++;
            memcpy( (char *)child_peb + 0x2000, src, (nb + 1) * sizeof(*src) );
            dprintf(STDERR_FILENO, "[Wine child] dbg-channel table copied: %u entries, default flags=0x%x\n",
                    nb, src[nb].flags);
        }
    }
    child_peb->LdrData = NULL;            /* child builds fresh module list */
    child_peb->ImageBaseAddress = NULL;    /* set by init_startup_info */
    child_peb->ProcessParameters = NULL;   /* set by init_startup_info */
    /* Clear locks/bitmaps that reference the parent's CRITICAL_SECTIONs.
     * The child's LdrInitializeThunk (running against its own ntdll .data
     * copy) creates fresh ones. Without clearing, child and parent would
     * contend on shared CS state. */
    child_peb->LoaderLock = NULL;
    child_peb->FastPebLock = NULL;
    child_peb->TlsBitmap = NULL;
    child_peb->TlsBitmapBits[0] = 0;
    child_peb->TlsBitmapBits[1] = 0;
    /* Point child's TEB to the new PEB */
    teb->Peb = child_peb;
    /* WOW64_DESIGN.md §2: the window now has an owner, so every later
     * ios_wow_base()/ios_wow_base_for_peb() lookup resolves through the PEB
     * (including from other threads and from NtQueryInformationProcess). */
    CHILD_STAGE( "window-bind" );
    ios_wow_window_bind( child_peb );
    /* init_teb ran before the child PEB existed, so TEB32->Peb still points at
     * the CREATOR's PEB (which is outside this window — a truncated host
     * address, i.e. garbage to guest code).  Repoint it now.
     *
     * This runs in the gap between ios_wow_window_bind() above and the
     * pthread_setspecific( ios_teb_tls_key, teb ) further down, so this thread
     * cannot yet resolve its own PEB and the window is found only through the
     * slot's owner thread (see ios_wow_slot_current()).  Assert that it IS
     * found: with base 0 ios_wow_guest_addr() silently truncates the host
     * pointer and writes exactly the garbage this repoint exists to remove. */
    {
        WOW_TEB *wow_teb = get_wow_teb( teb );
        ULONG_PTR wow_base = ios_wow_base();

        if (wow_teb && !wow_base)
            CHILD_BOOT_FAIL( "the guest window is not resolvable while repointing TEB32->Peb "
                             "(child_peb=%p) — TEB32->Peb would be a truncated host pointer\n",
                             child_peb );
        if (wow_teb)
            wow_teb->Peb = ios_wow_guest_addr( (char *)child_peb + page_size );
    }

    dprintf(STDERR_FILENO, "[Wine child] teb=%p child_peb=%p (parent_peb=%p)\n",
            teb, child_peb, peb);

    /* Set TEB key so NtCurrentTeb() works on this thread */
    pthread_setspecific( teb_key, teb );

    /* Store TEB in patcher TLS slot so TPIDRRO_EL0-based trampolines work */
    {
        extern pthread_key_t ios_teb_tls_key;
        pthread_setspecific( ios_teb_tls_key, teb );
    }

    /* Confirm the TEB is visible at the discovered raw slot, which is what the
     * x18 trampolines in the child's ntdll copy load. Without it every patched
     * x18 access on this thread reads TEB=0 and faults (S1 first-run storm:
     * 60k+ UNHANDLED at addr=<TEB field offset>, x17=0). */
    {
        extern int ios_teb_tls_slot_offset;
        uintptr_t tsd_base;
        void *raw;
        __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd_base));
        tsd_base &= ~7ULL;
        raw = ios_teb_tls_slot_offset ? *(void **)(tsd_base + ios_teb_tls_slot_offset) : NULL;
        dprintf(STDERR_FILENO, "[teb-tsd] child raw=%p pthread=%p %s\n",
                raw, teb, raw == teb ? "MATCH" : "MISMATCH");
    }

    /* Switch global peb to child's PEB for the duration of child init.
     * The parent thread is blocked in NtWaitForSingleObject at this point. */
    {
        PEB *parent_peb = peb;
        peb = child_peb;

        /* Set up main_argc/argv for this child (these are globals, but parent is blocked) */
        main_argc = argc;
        main_argv = argv;

        /* Register with wineserver using the child's socketfd */
        CHILD_STAGE( "server_init_process_child" );
        startup_info_size = server_init_process_child( child_fd_socket );

        /* init_startup_info — reads startup info from wineserver, loads the
         * child's PE. It OVERWRITES the main_image_info global with the
         * child's exe info; snapshot the session's and restore it after
         * registering the child's copy in the per-process identity registry
         * (X3: an AMD64 child must not flip is_arm64ec() for the whole
         * session — parent threads run concurrently). Everything on THIS
         * thread reads identity owner-aware from here on. */
        {
            SECTION_IMAGE_INFORMATION session_image_info = main_image_info;
            /* WOW64_DESIGN.md §3: `wow_peb` is a SESSION global, and init_peb()
             * (env_ios.c) only ever WRITES it — for a 32-bit image — so it
             * stays pointing at the previous 32-bit pseudo-process when a
             * 64-bit child boots next.  init_peb's `if (wow_peb)` block then
             * ran for that 64-bit child: it called ios_wow_map_user_shared_data
             * and build_wow64_parameters, whose limit_2g ceiling was NOT
             * translated into a window (this child has none), so the
             * allocation was attempted below 4 GB, returned STATUS_NO_MEMORY,
             * and `assert( !status )` (env_ios.c:1934) aborted — which on iOS
             * is an abort() inside the one shared Mach task.  Observed on
             * device: a console-subsystem i386 child's conhost.exe died this
             * way and NtCreateUserProcess returned c00000e5.
             * Clearing it here makes the derivation per-process: init_peb
             * re-publishes it for a 32-bit child, and if it comes back NULL
             * this child is 64-bit and the 32-bit sibling's value (still live
             * and blocked in NtCreateUserProcess) is restored. */
            WOW_PEB *saved_wow_peb = wow_peb;

            wow_peb = NULL;
            CHILD_STAGE( "unix_init_startup_info" );
            unix_init_startup_info();
            if (!wow_peb && saved_wow_peb)
            {
                dprintf( STDERR_FILENO, "[wow-peb] 64-bit child kept out of the WoW64 branch; "
                         "restoring the session wow_peb=%p\n", saved_wow_peb );
                wow_peb = saved_wow_peb;
            }
            ios_register_proc_ident( child_peb, &main_image_info );
            main_image_info = session_image_info;
        }
        dprintf(STDERR_FILENO, "[Wine child] PE loaded: Machine=0x%x TransferAddress=%p ImageBase=%p\n",
                ios_cur_image_info()->Machine, ios_cur_image_info()->TransferAddress, peb->ImageBaseAddress);
        if (!is_machine_64bit( ios_cur_image_info()->Machine ))
            ERR( "[Wine child] i386 image mapped: base=%p transfer=%p window=%p guest_base=%p\n",
                 peb->ImageBaseAddress, ios_cur_image_info()->TransferAddress,
                 (void *)ios_wow_base(),
                 (void *)(ULONG_PTR)ios_wow_guest_addr( peb->ImageBaseAddress ) );

        /* Set DLL load order for child's exe */
        *(ULONG_PTR *)&peb->CloudFileFlags = get_image_address();
        set_load_order_app_name( main_wargv[0] );

        /* Set up thread stack.  The status was dropped on the floor before: a
         * failed 32-bit stack allocation (the window is the only place one can
         * come from) left the child booting with TEB32 stack fields at 0 and
         * faulting on its first guest push, with nothing said about it. */
        CHILD_STAGE( "init_thread_stack" );
        if ((status = init_thread_stack( teb, 0, 0, 0 )))
            CHILD_BOOT_FAIL( "init_thread_stack returned 0x%x (window %p, guest ceiling %p)\n",
                             (unsigned)status, (void *)ios_wow_base(),
                             (void *)user_space_wow_limit );

        /* WOW64_DESIGN.md §2: a 32-bit child needs its own i386 ntdll mapped
         * (and LdrSystemDllInitBlock filled with GUEST addresses) exactly as
         * start_main_thread does for the session's main process.  The child
         * boot path never did this — there had never been a 32-bit child. */
        if (!is_machine_64bit( ios_cur_image_info()->Machine ))
        {
            CHILD_STAGE( "load_wow64_ntdll" );
            load_wow64_ntdll( ios_cur_image_info()->Machine );
            ERR( "[Wine child] i386 ntdll bound: ntdll_handle=%p LdrInitializeThunk=%p (guest)\n",
                 (void *)(ULONG_PTR)pLdrSystemDllInitBlock->ntdll_handle,
                 (void *)(ULONG_PTR)pLdrSystemDllInitBlock->pLdrInitializeThunk );
        }

        /* start_main_thread runs load_apiset_dll() right after load_wow64_ntdll;
         * the child path never did, so every `api-ms-win-*` import of every
         * module this child loads failed.  Same position, but per-machine and
         * window-aware (see ios_child_load_apiset). */
        CHILD_STAGE( "load_apiset" );
        ios_child_load_apiset( ios_cur_image_info()->Machine );

        /* X3c: a cross-arch child (AMD64 exe, non-EC session) cannot run on
         * the session's aarch64 ntdll at all — load the ARM64EC build as a
         * private second image instead of copying the session image. The
         * fresh image needs no per-child copy (nobody else uses its .data);
         * the standard map pipeline gave it pool/EC/x18 treatment. */
        if (ios_cur_image_info()->Machine == IMAGE_FILE_MACHINE_AMD64 && !is_arm64ec())
        {
            CHILD_STAGE( "load_child_ec_ntdll" );
            if (ios_load_child_ec_ntdll( child_peb ) != 0)
                CHILD_BOOT_FAIL( "EC ntdll load failed — a cross-arch child cannot start\n" );
        }
        else
        /* S1: per-child ntdll copy. The child cannot share the parent's
         * ntdll .data (module list / loader lock / hash table collide), so
         * copy the whole ntdll image into a fresh pool slot owned by this
         * child's PEB. Owner-aware translation (this thread's TEB->Peb is
         * already child_peb, and the TSD slot is set above) routes the
         * child's ntdll faults + sync writes to its own copy; every other
         * module falls back to the shared parent copies. */
        {
            extern int ios_jit_copy_module_for_child(void *module_addr, void *child_peb);
            extern void *ios_jit_translate_addr(void *addr);
            extern void ios_jit_sync_write(void *addr, size_t size);

            if (ios_jit_copy_module_for_child(pLdrInitializeThunk, child_peb) != 0)
            {
                dprintf(STDERR_FILENO, "[Wine child] ntdll copy FAILED — falling back to SHARED ntdll (module lists will collide!)\n");
            }
            else
            {
                /* Verify from this (child) thread: translation must now hit
                 * the child copy, and the dispatcher slots inside it must
                 * hold sane values (inherited via the copy + pool sweep). */
                void *jit_ldr = ios_jit_translate_addr(pLdrInitializeThunk);
                dprintf(STDERR_FILENO, "[Wine child] LdrInitializeThunk %p -> child copy %p\n",
                        pLdrInitializeThunk, jit_ldr);
                if (ios_ntdll_syscall_dispatcher_ptr)
                {
                    uint64_t *slot = ios_jit_translate_addr(ios_ntdll_syscall_dispatcher_ptr);
                    dprintf(STDERR_FILENO, "[Wine child] child syscall_disp slot %p = 0x%llx (unix func %p)\n",
                            slot, (unsigned long long)*slot, __wine_syscall_dispatcher);
                    if (*slot != (uint64_t)(uintptr_t)__wine_syscall_dispatcher)
                    {
                        *ios_ntdll_syscall_dispatcher_ptr = (void *)(uintptr_t)__wine_syscall_dispatcher;
                        ios_jit_sync_write(ios_ntdll_syscall_dispatcher_ptr, sizeof(void*));
                        dprintf(STDERR_FILENO, "[Wine child]   -> repaired syscall dispatcher slot\n");
                    }
                }
                if (ios_ntdll_unix_call_dispatcher_ptr)
                {
                    uint64_t *slot = ios_jit_translate_addr(ios_ntdll_unix_call_dispatcher_ptr);
                    dprintf(STDERR_FILENO, "[Wine child] child unix_call_disp slot %p = 0x%llx\n",
                            slot, (unsigned long long)*slot);
                }
                if (ios_ntdll_unixlib_handle_ptr)
                {
                    uint64_t *slot = ios_jit_translate_addr(ios_ntdll_unixlib_handle_ptr);
                    dprintf(STDERR_FILENO, "[Wine child] child unixlib_handle slot %p = 0x%llx (want %p)\n",
                            slot, (unsigned long long)*slot, (void *)unix_call_funcs);
                    if (*slot != (uint64_t)(uintptr_t)unix_call_funcs)
                    {
                        *ios_ntdll_unixlib_handle_ptr = (UINT_PTR)unix_call_funcs;
                        ios_jit_sync_write(ios_ntdll_unixlib_handle_ptr, sizeof(UINT_PTR));
                        dprintf(STDERR_FILENO, "[Wine child]   -> repaired unixlib handle slot\n");
                    }
                }
            }
        }

        /* Keep peb = child_peb through server_init_process_done, because:
         * 1. server_init_process_done sends PEB address to wineserver
         * 2. It calls signal_start_thread which never returns
         * The parent thread is blocked in NtWaitForSingleObject during this time.
         * After PE code starts, peb stays as child_peb on this thread.
         * The parent will unblock and its PE code uses NtCurrentTeb()->Peb (correct).
         * Note: parent's unix-side peb references may see child_peb, but after
         * init there are very few unix-side peb references. */
        (void)parent_peb;  /* suppress unused warning */
    }

    /* Finalize init and enter PE code (calls signal_start_thread, never returns) */
    CHILD_STAGE( "server_init_process_done" );
    server_init_process_done();

    /* Never reaches here — server_init_process_done calls signal_start_thread */
    CHILD_STAGE( "after-server_init_process_done" );
#undef CHILD_STAGE
#undef CHILD_BOOT_FAIL
}
#endif


/***********************************************************************
 *           __wine_main
 *
 * Main entry point called by the wine loader.
 */
DECLSPEC_EXPORT void __wine_main( int argc, char *argv[] )
{
    main_argc = argc;
    main_argv = argv;

    init_paths();
#ifndef WINE_IOS
    if (!getenv( "WINELOADERNOEXEC" ) || argc <= 1) check_command_line( argc, argv );
    unsetenv( "WINELOADERNOEXEC" );
#endif

#ifdef RLIMIT_NOFILE
    set_max_limit( RLIMIT_NOFILE );
#endif
#ifdef RLIMIT_AS
    set_max_limit( RLIMIT_AS );
#endif
#ifdef RLIMIT_NICE
    set_max_limit( RLIMIT_NICE );
#endif

    virtual_init();
    init_environment();

#if defined(__APPLE__) && !defined(WINE_IOS)
    apple_main_thread();
#endif
    start_main_thread();
}
