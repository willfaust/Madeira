/*
 * Window classes functions
 *
 * Copyright 1993, 1996, 2003 Alexandre Julliard
 * Copyright 1995 Martin von Loewis
 * Copyright 1998 Juergen Schmied (jsch)
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

#include <pthread.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ntstatus.h"
#include "win32u_private.h"
#include "ntuser_private.h"
#include "wine/server.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(class);
WINE_DECLARE_DEBUG_CHANNEL(win);

SYSTEM_BASIC_INFORMATION system_info;

#define MAX_ATOM_LEN  255
#define IS_INTATOM(x) (((ULONG_PTR)(x) >> 16) == 0)

#define MAX_WINPROCS  4096
#define WINPROC_PROC16  ((void *)1)  /* placeholder for 16-bit window procs */

typedef struct tagCLASS
{
    struct list  entry;         /* Entry in class list */
    BOOL         local;         /* Local class? */
    WNDPROC      winproc;       /* Window procedure */
    struct dce  *dce;           /* Opaque pointer to class DCE */
    HICON        hIcon;         /* Default icon */
    HICON        hIconSm;       /* Default small icon */
    HICON        hIconSmIntern; /* Internal small icon, derived from hIcon */
    HCURSOR      hCursor;       /* Default cursor */
    HBRUSH       hbrBackground; /* Default background */
    struct client_menu_name menu_name; /* Default menu name */
    const shared_object_t *shared; /* class object in session shared memory */
} CLASS;

/* Built-in class descriptor */
struct builtin_class_descr
{
    const char *name;    /* class name */
    UINT       style;    /* class style */
    INT        extra;     /* window extra bytes */
    ULONG_PTR  cursor;    /* cursor id */
    HBRUSH     brush;     /* brush or system color */
    enum ntuser_client_procs proc;
};

typedef struct tagWINDOWPROC
{
    WNDPROC  procA;    /* ANSI window proc */
    WNDPROC  procW;    /* Unicode window proc */
} WINDOWPROC;

static WINDOWPROC winproc_array[MAX_WINPROCS];
static UINT winproc_used = NTUSER_NB_PROCS;
static pthread_mutex_t winproc_lock = PTHREAD_MUTEX_INITIALIZER;

static struct list class_list = LIST_INIT( class_list );

HINSTANCE user32_module = 0;

/* iOS-Madeira (Thing B root cause): win32u is a single shared instance
 * across pseudo-processes, but the head of winproc_array (the builtin
 * class procs installed by NtUserInitializeClientPfnArrays) and
 * user32_module are PER-PROCESS state on real Windows — every user32
 * instance that boots overwrote them for the whole session. When an
 * x64 child (cube) loaded its sysx64 user32, the session's aarch64
 * builtin wndprocs were replaced by x64 pointers into the child's
 * image; explorer's next builtin-class window (taskbar button)
 * dispatched WM_NCCREATE into x64 code on a session thread → ExitToX64
 * with no FEX thread state → branch-to-1 zero-page crawl (the taskbar
 * wedge). Fix = S1 registry pattern: per-PEB client-proc tables,
 * resolved on the dispatching thread. Builtin CLASS objects stay
 * session-global (they store index handles, arch-neutral); only the
 * handle→pointer resolution becomes owner-aware. Readers are
 * lock-free: slots fully written before the count is published. */
struct ios_client_procs
{
    void      *peb;                          /* NULL = free slot */
    WINDOWPROC procs[NTUSER_NB_PROCS];
    HINSTANCE  user32_module;
};
#define IOS_MAX_CLIENT_PROCS 64
static struct ios_client_procs ios_client_procs_reg[IOS_MAX_CLIENT_PROCS];
static int ios_client_procs_count;

static struct ios_client_procs *ios_client_procs_for_peb(void)
{
    void *peb = NtCurrentTeb()->Peb;
    int i, n = ios_client_procs_count;
    for (i = 0; i < n; i++)
        if (ios_client_procs_reg[i].peb == peb) return &ios_client_procs_reg[i];
    return NULL;
}

/* Redirect a builtin winproc_array entry to the current process's
 * table. Handle identity (proc_to_handle offsets) stays on
 * winproc_array; only value reads go through this. */
static WINDOWPROC *ios_resolve_builtin( WINDOWPROC *ptr )
{
    if (ptr && ptr != WINPROC_PROC16 &&
        (size_t)(ptr - winproc_array) < NTUSER_NB_PROCS)
    {
        struct ios_client_procs *entry = ios_client_procs_for_peb();
        if (entry) return &entry->procs[ptr - winproc_array];
    }
    return ptr;
}

static HINSTANCE ios_cur_user32_module(void)
{
    struct ios_client_procs *entry = ios_client_procs_for_peb();
    return entry ? entry->user32_module : user32_module;
}

/* find an existing winproc for a given function and type */
/* FIXME: probably should do something more clever than a linear search */
static WINDOWPROC *find_winproc( WNDPROC func, BOOL ansi )
{
    unsigned int i;
    /* iOS-Madeira: match builtin procs against the CURRENT process's
     * table (the raw pointer being registered lives in that process's
     * user32); the returned pointer stays on winproc_array so
     * proc_to_handle identity is preserved. */
    struct ios_client_procs *entry = ios_client_procs_for_peb();
    const WINDOWPROC *builtin = entry ? entry->procs : winproc_array;

    for (i = 0; i < NTUSER_NB_PROCS; i++)
    {
        /* match either proc, some apps confuse A and W */
        if (builtin[i].procA != func && builtin[i].procW != func) continue;
        return &winproc_array[i];
    }
    for ( ; i < winproc_used; i++)
    {
        if (ansi && winproc_array[i].procA != func) continue;
        if (!ansi && winproc_array[i].procW != func) continue;
        return &winproc_array[i];
    }
    return NULL;
}

/* iOS-Madeira ml1360: a 32-bit program's winproc handle (0xffffNNNN) can
 * reach win32u with its guest window base added.  The WoW64 thunks for
 * CallWindowProc (win_proc_params.func) and RegisterClass (lpfnWndProc)
 * convert those fields as guest addresses, so 0xffff0036 arrives as
 * B + 0xffff0036.  get_winproc_ptr() then does not recognise it as a handle,
 * win32u hands it back as a plain procedure, the conversion back to 32 bits
 * yields 0xffff0036 again, and user32 calls it as code.  Device log prev 15:
 * FEX "NoExec instruction in entry block: FFFF0036" inside the webhelper's
 * window callback, then 6770 "dispatch_user_callback ignoring exception"
 * lines as every message to the login window was dropped.  The top 64 KB of
 * a 32-bit address space never holds code, so a value of that form inside
 * the caller's window is the handle.  MADEIRA_WINPROC_HANDLE=0 disables. */
extern ULONG_PTR ios_wow_base(void);
static WNDPROC ios_winproc_handle_arg( WNDPROC proc )
{
    static int enabled = -1;
    static unsigned int reported;
    ULONG_PTR value = (ULONG_PTR)proc, base;

    if (!(value >> 32)) return proc;
    base = ios_wow_base();
    if (!base || value - base > 0xffffffffu || (value - base) >> 16 != WINPROC_HANDLE) return proc;
    if (enabled < 0)
    {
        const char *env = getenv( "MADEIRA_WINPROC_HANDLE" );
        enabled = !env || strcmp( env, "0" );
    }
    if (__atomic_load_n( &reported, __ATOMIC_RELAXED ) < 8 &&
        __atomic_fetch_add( &reported, 1, __ATOMIC_RELAXED ) < 8)
        fprintf( stderr, "[winproc-handle] ml1360 guest=%#lx handle=%#lx enabled=%d\n",
                 (unsigned long)value, (unsigned long)(value - base), enabled );
    return enabled ? (WNDPROC)(value - base) : proc;
}

/* return the window proc for a given handle, or NULL for an invalid handle,
 * or WINPROC_PROC16 for a handle to a 16-bit proc. */
static WINDOWPROC *get_winproc_ptr( WNDPROC handle )
{
    UINT index;
    handle = ios_winproc_handle_arg( handle );
    index = LOWORD(handle);
    if ((ULONG_PTR)handle >> 16 != WINPROC_HANDLE) return NULL;
    if (index >= MAX_WINPROCS) return WINPROC_PROC16;
    if (index >= winproc_used) return NULL;
    return &winproc_array[index];
}

/* create a handle for a given window proc */
static inline WNDPROC proc_to_handle( WINDOWPROC *proc )
{
    return (WNDPROC)(ULONG_PTR)((proc - winproc_array) | (WINPROC_HANDLE << 16));
}

/* allocate and initialize a new winproc */
static inline WINDOWPROC *alloc_winproc_ptr( WNDPROC func, BOOL ansi )
{
    WINDOWPROC *proc;

    /* check if the function is already a win proc */
    if (!func) return NULL;
    if ((proc = get_winproc_ptr( func ))) return proc;

    pthread_mutex_lock( &winproc_lock );

    /* check if we already have a winproc for that function */
    if (!(proc = find_winproc( func, ansi )))
    {
        if (winproc_used < MAX_WINPROCS)
        {
            proc = &winproc_array[winproc_used++];
            if (ansi) proc->procA = func;
            else proc->procW = func;
            TRACE_(win)( "allocated %p for %c %p (%d/%d used)\n",
                         proc_to_handle(proc), ansi ? 'A' : 'W', func,
                         winproc_used, MAX_WINPROCS );
        }
        else WARN_(win)( "too many winprocs, cannot allocate one for %p\n", func );
    }
    else TRACE_(win)( "reusing %p for %p\n", proc_to_handle(proc), func );

    pthread_mutex_unlock( &winproc_lock );
    return proc;
}

/**********************************************************************
 *	     alloc_winproc
 *
 * Allocate a window procedure for a window or class.
 *
 * Note that allocated winprocs are never freed; the idea is that even if an app creates a
 * lot of windows, it will usually only have a limited number of window procedures, so the
 * array won't grow too large, and this way we avoid the need to track allocations per window.
 */
WNDPROC alloc_winproc( WNDPROC func, BOOL ansi )
{
    WINDOWPROC *proc;

    if (!(proc = alloc_winproc_ptr( func, ansi ))) return func;
    if (proc == WINPROC_PROC16) return func;
    return proc_to_handle( proc );
}

/* Get a window procedure pointer that can be passed to the Windows program. */
WNDPROC get_winproc( WNDPROC proc, BOOL ansi )
{
    WINDOWPROC *ptr = ios_resolve_builtin( get_winproc_ptr( proc ));

    if (!ptr || ptr == WINPROC_PROC16) return proc;
    if (ansi)
    {
        if (ptr->procA) return ptr->procA;
        return proc;
    }
    else
    {
        if (ptr->procW) return ptr->procW;
        return proc;
    }
}

/* Return the window procedure type, or the default value if not a winproc handle. */
BOOL is_winproc_unicode( WNDPROC proc, BOOL def_val )
{
    WINDOWPROC *ptr = ios_resolve_builtin( get_winproc_ptr( proc ));

    if (!ptr) return def_val;
    if (ptr == WINPROC_PROC16) return FALSE;  /* 16-bit is always A */
    if (ptr->procA && ptr->procW) return def_val;  /* can be both */
    return ptr->procW != NULL;
}

void get_winproc_params( struct win_proc_params *params, BOOL fixup_ansi_dst )
{
    /* iOS-Madeira: resolve builtin procs against the DISPATCHING
     * process — this is the call that fed explorer an x64 wndproc. */
    WINDOWPROC *proc = ios_resolve_builtin( get_winproc_ptr( params->func ));

    if (!proc)
    {
        params->procW = params->procA = NULL;
    }
    else if (proc == WINPROC_PROC16)
    {
        params->procW = params->procA = WINPROC_PROC16;
    }
    else
    {
        params->procA = proc->procA;
        params->procW = proc->procW;

        if (fixup_ansi_dst)
        {
            if (params->ansi)
            {
                if (params->procA) params->ansi_dst = TRUE;
                else if (params->procW) params->ansi_dst = FALSE;
            }
            else
            {
                if (params->procW) params->ansi_dst = FALSE;
                else if (params->procA) params->ansi_dst = TRUE;
            }
        }
    }

    if (!params->procA) params->procA = params->func;
    if (!params->procW) params->procW = params->func;
}

DLGPROC get_dialog_proc( DLGPROC ret, BOOL ansi )
{
    WINDOWPROC *proc;

    if (!(proc = ios_resolve_builtin( get_winproc_ptr( (WNDPROC)ret )))) return ret;
    if (proc == WINPROC_PROC16) return WINPROC_PROC16;
    return (DLGPROC)(ansi ? proc->procA : proc->procW);
}

static void init_user(void)
{
    /* iOS-Madeira (WOW64_DESIGN.md §3 invariant 2): gdi_init() -> font_init()
     * dereferences Peb->AnsiCodePageData / OemCodePageData /
     * UnicodeCaseTableData.  In a 32-bit process those three PEB64 fields were
     * written by the guest's own ntdll with the WoW64 identity conversion, so
     * they hold GUEST addresses; repair them before the first native read.
     * Defined in build/ntdll-unix/env_ios.c (same image); no-op for a 64-bit
     * process.  RtlInitCodePageTable() also guards itself. */
    extern void ios_wow_fixup_peb64_ptrs(void);
    ios_wow_fixup_peb64_ptrs();

    NtQuerySystemInformation( SystemBasicInformation, &system_info, sizeof(system_info), NULL );

    init_startup_info();
    shared_session_init();
    gdi_init();
    sysparams_init();
    winstation_init();
    register_desktop_class();
}

/***********************************************************************
 *	     NtUserInitializeClientPfnArrays   (win32u.@)
 */
NTSTATUS WINAPI NtUserInitializeClientPfnArrays( const ntuser_client_func_ptr *client_procsA,
                                                 const ntuser_client_func_ptr *client_procsW,
                                                 const ntuser_client_func_ptr *client_workers,
                                                 HINSTANCE user_module )
{
    static pthread_once_t init_once = PTHREAD_ONCE_INIT;
    void *peb = NtCurrentTeb()->Peb;
    struct ios_client_procs *entry = NULL;
    int slot, n;
    UINT i;

    /* iOS-Madeira: install into THIS pseudo-process's table instead of
     * clobbering the session-wide array (the Thing B taskbar wedge).
     * The first initializer (the session) also populates the legacy
     * globals as the fallback for processes that never load user32. */
    pthread_mutex_lock( &winproc_lock );
    n = ios_client_procs_count;
    for (slot = 0; slot < n; slot++)
        if (ios_client_procs_reg[slot].peb == peb) { entry = &ios_client_procs_reg[slot]; break; }
    if (!entry && n < IOS_MAX_CLIENT_PROCS) entry = &ios_client_procs_reg[n];
    if (entry)
    {
        for (i = 0; i < NTUSER_NB_PROCS; i++)
        {
            entry->procs[i].procA = client_procsA[i][0];
            entry->procs[i].procW = client_procsW[i][0];
        }
        entry->user32_module = user_module;
        if (!entry->peb)
        {
            __sync_synchronize();
            entry->peb = peb;
            __sync_synchronize();
            ios_client_procs_count = n + 1;
        }
        dprintf(2, "[pfn] peb=%p user32=%p slot=%d\n", peb, user_module,
                (int)(entry - ios_client_procs_reg));
    }
    else dprintf(2, "[pfn] registry FULL — peb=%p falls back to session procs\n", peb);
    if (!user32_module)
    {
        for (i = 0; i < NTUSER_NB_PROCS; i++)
        {
            winproc_array[i].procA = client_procsA[i][0];
            winproc_array[i].procW = client_procsW[i][0];
        }
        user32_module = user_module;
    }
    pthread_mutex_unlock( &winproc_lock );

    pthread_once( &init_once, init_user );
    return STATUS_SUCCESS;
}

/***********************************************************************
 *           get_int_atom_value
 */
static ATOM get_int_atom_value( UNICODE_STRING *name )
{
    const WCHAR *ptr = name->Buffer;
    const WCHAR *end = ptr + name->Length / sizeof(WCHAR);
    UINT ret = 0;

    if (IS_INTRESOURCE(ptr)) return LOWORD(ptr);

    if (*ptr++ != '#') return 0;
    while (ptr < end)
    {
        if (*ptr < '0' || *ptr > '9') return 0;
        ret = ret * 10 + *ptr++ - '0';
        if (ret >= MAXINTATOM) return 0;
    }
    return ret;
}

atom_t wine_server_add_atom( void *req, UNICODE_STRING *str )
{
    atom_t atom;
    if (!(atom = get_int_atom_value( str ))) wine_server_add_data( req, str->Buffer, str->Length );
    return atom;
}

BOOL is_desktop_class( UNICODE_STRING *name )
{
    static const WCHAR desktopW[] = {'#','3','2','7','6','9'};
    return name->Length == sizeof(desktopW) && !wcsnicmp( name->Buffer, desktopW, ARRAY_SIZE(desktopW) );
}

BOOL is_message_class( UNICODE_STRING *name )
{
    static const WCHAR messageW[] = {'M','e','s','s','a','g','e'};
    return name->Length == sizeof(messageW) && !wcsnicmp( name->Buffer, messageW, ARRAY_SIZE(messageW) );
}

static unsigned int is_integral_atom( const WCHAR *atomstr, ULONG len, RTL_ATOM *ret_atom )
{
    RTL_ATOM atom;

    if ((ULONG_PTR)atomstr >> 16)
    {
        const WCHAR* ptr = atomstr;
        if (!len) return STATUS_OBJECT_NAME_INVALID;

        if (*ptr++ == '#')
        {
            atom = 0;
            while (ptr < atomstr + len && *ptr >= '0' && *ptr <= '9')
            {
                atom = atom * 10 + *ptr++ - '0';
            }
            if (ptr > atomstr + 1 && ptr == atomstr + len) goto done;
        }
        if (len > MAX_ATOM_LEN) return STATUS_INVALID_PARAMETER;
        return STATUS_MORE_ENTRIES;
    }
    else if ((atom = LOWORD( atomstr )) >= MAXINTATOM) return STATUS_INVALID_PARAMETER;
done:
    if (atom >= MAXINTATOM) atom = 0;
    if (!(*ret_atom = atom)) return STATUS_INVALID_PARAMETER;
    return STATUS_SUCCESS;
}

static ULONG integral_atom_name( WCHAR *buffer, ULONG len, RTL_ATOM atom )
{
    char tmp[16];
    int ret = snprintf( tmp, sizeof(tmp), "#%u", atom );

    len /= sizeof(WCHAR);
    if (len)
    {
        if (len <= ret) ret = len - 1;
        ascii_to_unicode( buffer, tmp, ret );
        buffer[ret] = 0;
    }
    return ret * sizeof(WCHAR);
}

/***********************************************************************
 *           get_class_ptr
 */
static CLASS *get_class_ptr( HWND hwnd, BOOL write_access )
{
    WND *ptr = get_win_ptr( hwnd );

    if (ptr)
    {
        if (ptr != WND_OTHER_PROCESS && ptr != WND_DESKTOP) return ptr->class;
        if (!write_access) return OBJ_OTHER_PROCESS;

        /* modifying classes in other processes is not allowed */
        if (ptr == WND_DESKTOP || is_window( hwnd ))
        {
            RtlSetLastWin32Error( ERROR_ACCESS_DENIED );
            return NULL;
        }
    }
    RtlSetLastWin32Error( ERROR_INVALID_WINDOW_HANDLE );
    return NULL;
}

static NTSTATUS get_shared_class( CLASS *class, struct object_lock *lock, const class_shm_t **class_shm )
{
    const shared_object_t *object;

    TRACE( "class %p, lock %p, class_shm %p\n", class, lock, class_shm );

    if (!(object = class->shared)) return STATUS_INVALID_HANDLE;

    if (!lock->id || !shared_object_release_seqlock( object, lock->seq ))
    {
        shared_object_acquire_seqlock( object, &lock->seq );
        /* iOS (task #21): a freed class shared object (id==0, from a dead
         * pseudo-process's class) leaves lock->id==0 forever → caller's
         * while(==PENDING) spins under user_lock → whole-desktop freeze
         * (repro: close regedit, then a Run-dialog class lookup). Fail out. */
        if (!object->id) return STATUS_INVALID_HANDLE;
        *class_shm = &object->shm.class;
        lock->id = object->id;
        return STATUS_PENDING;
    }

    return STATUS_SUCCESS;
}

static NTSTATUS get_shared_window_class( HWND hwnd, struct object_lock *lock, const class_shm_t **class_shm )
{
    const shared_object_t *object;

    TRACE( "hwnd %p, lock %p, class_shm %p\n", hwnd, lock, class_shm );

    if (lock->id) object = CONTAINING_RECORD( *class_shm, shared_object_t, shm.class );
    else
    {
        struct obj_locator locator = get_window_class_locator( hwnd );
        object = find_shared_session_object( locator.id, locator.offset );
        if (!object) return STATUS_INVALID_HANDLE;
    }

    if (!lock->id || !shared_object_release_seqlock( object, lock->seq ))
    {
        shared_object_acquire_seqlock( object, &lock->seq );
        /* iOS (task #21): freed-object guard — see get_shared_class. */
        if (!object->id) return STATUS_INVALID_HANDLE;
        *class_shm = &object->shm.class;
        lock->id = object->id;
        return STATUS_PENDING;
    }

    return STATUS_SUCCESS;
}

/***********************************************************************
 *           release_class_ptr
 */
static void release_class_ptr( CLASS *ptr )
{
    user_unlock();
}

static BOOL class_name_matches( CLASS *class, UNICODE_STRING *name )
{
    /* class name is safe to read without shared object locking as it is constant */
    const WCHAR *class_name = (WCHAR *)class->shared->shm.class.name;
    UINT len = class->shared->shm.class.name_len;
    return name->Length == len && !wcsnicmp( class_name, name->Buffer, len / sizeof(WCHAR) );
}

static UINT_PTR get_class_instance( CLASS *class )
{
    struct object_lock lock = OBJECT_LOCK_INIT;
    const class_shm_t *class_shm;
    UINT_PTR instance = 0;
    NTSTATUS status;

    while ((status = get_shared_class( class, &lock, &class_shm )) == STATUS_PENDING)
        instance = class_shm->instance;
    if (status) return 0;
    return instance;
}

static CLASS *find_class( HINSTANCE module, UNICODE_STRING *name )
{
    ULONG_PTR instance = (UINT_PTR)module;
    CLASS *class;
    int is_win16;
    /* Task #21: class_list is a SINGLE win32u global shared by every
     * pseudo-process in our single-Mach-task model (same shared-state class
     * as Thing B). A pseudo-process exiting without cleaning its class
     * entries can leave the shared list cyclic — and an unbounded walk of a
     * corrupt shared list hangs FOREVER holding user_lock, freezing the
     * whole desktop (observed: close regedit → next Run-dialog class lookup
     * spins in NtUserGetClassInfoEx). Bound the walk: a real class_list is
     * at most a few hundred entries even with many processes; >8192 = the
     * list is corrupt, so bail (as "not found") instead of hanging. This
     * makes the corruption survivable + loud rather than fatal. */
    unsigned walked = 0;
    extern int dprintf(int fd, const char *fmt, ...);

    user_lock();
    LIST_FOR_EACH_ENTRY( class, &class_list, CLASS, entry )
    {
        if (++walked > 8192)
        {
            static int logged;
            if (!logged++)
                dprintf( 2, "[class-cycle] find_class walked >8192 entries — class_list "
                         "corrupt (cyclic?), bailing to avoid user_lock hang\n" );
            break;
        }
        {
            UINT_PTR class_instance = get_class_instance( class );
            if (!class_name_matches( class, name )) continue;
            is_win16 = !(class_instance >> 16);
            if (!instance || !class->local || class_instance == instance ||
                (!is_win16 && ((class_instance & ~0xffff) == (instance & ~0xffff))))
            {
                TRACE( "%s %lx -> %p\n", debugstr_us(name), instance, class );
                return class;
            }
        }
    }
    user_unlock();
    return NULL;
}

/***********************************************************************
 *           get_class_winproc
 */
WNDPROC get_class_winproc( CLASS *class )
{
    return class->winproc;
}

/***********************************************************************
 *           get_class_dce
 */
struct dce *get_class_dce( CLASS *class )
{
    return class->dce;
}

/***********************************************************************
 *           set_class_dce
 */
struct dce *set_class_dce( CLASS *class, struct dce *dce )
{
    if (class->dce) return class->dce;  /* already set, don't change it */
    class->dce = dce;
    return dce;
}

/***********************************************************************
 *	     NtUserRegisterClassExWOW   (win32u.@)
 */
ATOM WINAPI NtUserRegisterClassExWOW( const WNDCLASSEXW *wc, UNICODE_STRING *name, UNICODE_STRING *version,
                                      struct client_menu_name *client_menu_name, DWORD fnid,
                                      DWORD flags, DWORD *wow )
{
    const BOOL is_builtin = fnid, ansi = flags;
    const shared_object_t *shared;
    struct obj_locator locator;
    HINSTANCE instance;
    HICON sm_icon = 0;
    CLASS *class;
    ATOM atom;
    BOOL ret;

    /* create the desktop window to trigger builtin class registration */
    if (!is_builtin) get_desktop_window();

    if (wc->cbSize != sizeof(*wc) || wc->cbClsExtra < 0 || wc->cbWndExtra < 0 ||
        (!is_builtin && wc->hInstance == ios_cur_user32_module()))  /* we can't register a class for user32 */
    {
         RtlSetLastWin32Error( ERROR_INVALID_PARAMETER );
         return 0;
    }
    if (!(instance = wc->hInstance)) instance = NtCurrentTeb()->Peb->ImageBaseAddress;

    TRACE( "name=%s hinst=%p style=0x%x clExtr=0x%x winExtr=0x%x\n",
           debugstr_us(name), instance, wc->style, wc->cbClsExtra, wc->cbWndExtra );

    /* Fix the extra bytes value */

    if (wc->cbClsExtra > 40)  /* Extra bytes are limited to 40 in Win32 */
        WARN( "Class extra bytes %d is > 40\n", wc->cbClsExtra);
    if (wc->cbWndExtra > 40)  /* Extra bytes are limited to 40 in Win32 */
        WARN("Win extra bytes %d is > 40\n", wc->cbWndExtra );

    if (!(class = calloc( 1, sizeof(*class) ))) return 0;

    class->local      = !is_builtin && !(wc->style & CS_GLOBALCLASS);

    SERVER_START_REQ( create_class )
    {
        req->local      = class->local;
        req->style      = wc->style;
        req->instance   = wine_server_client_ptr( instance );
        req->cls_extra  = wc->cbClsExtra;
        req->win_extra  = wc->cbWndExtra;
        req->client_ptr = wine_server_client_ptr( class );
        req->atom       = wine_server_add_atom( req, name );
        req->name_offset = version->Length / sizeof(WCHAR);
        ret = !wine_server_call_err( req );
        locator = reply->locator;
        atom = reply->atom;
    }
    SERVER_END_REQ;
    if (!ret)
    {
        free( class );
        return 0;
    }

    if (!(shared = find_shared_session_object( locator.id, locator.offset )))
    {
        ERR( "Failed to get shared session object for window class\n" );
        SERVER_START_REQ( destroy_class )
        {
            req->instance = wine_server_client_ptr( instance );
            wine_server_add_data( req, name->Buffer, name->Length );
            wine_server_call( req );
        }
        SERVER_END_REQ;
        free( class );
        return 0;
    }

    /* Other non-null values must be set by caller */
    if (wc->hIcon && !wc->hIconSm)
        sm_icon = CopyImage( wc->hIcon, IMAGE_ICON,
                             get_system_metrics( SM_CXSMICON ),
                             get_system_metrics( SM_CYSMICON ),
                             LR_COPYFROMRESOURCE );

    user_lock();
    if (class->local) list_add_head( &class_list, &class->entry );
    else list_add_tail( &class_list, &class->entry );

    TRACE( "name=%s->%s atom=%04x wndproc=%p hinst=%p bg=%p style=%08x clsExt=%d winExt=%d class=%p\n",
           debugstr_w(wc->lpszClassName), debugstr_us(name), atom, wc->lpfnWndProc, instance,
           wc->hbrBackground, wc->style, wc->cbClsExtra, wc->cbWndExtra, class );

    class->hIcon         = wc->hIcon;
    class->hIconSm       = wc->hIconSm;
    class->hIconSmIntern = sm_icon;
    class->hCursor       = wc->hCursor;
    class->hbrBackground = wc->hbrBackground;
    class->winproc       = alloc_winproc( wc->lpfnWndProc, ansi );
    if (client_menu_name) class->menu_name = *client_menu_name;
    class->shared        = shared;
    release_class_ptr( class );
    return atom;
}

/***********************************************************************
 *	     NtUserUnregisterClass   (win32u.@)
 */
BOOL WINAPI NtUserUnregisterClass( UNICODE_STRING *name, HINSTANCE instance,
                                   struct client_menu_name *client_menu_name )
{
    struct list drawables = LIST_INIT( drawables );
    CLASS *class = NULL;

    /* create the desktop window to trigger builtin class registration */
    get_desktop_window();

    SERVER_START_REQ( destroy_class )
    {
        req->instance = wine_server_client_ptr( instance );
        req->atom     = wine_server_add_atom( req, name );
        if (!wine_server_call_err( req )) class = wine_server_get_ptr( reply->client_ptr );
    }
    SERVER_END_REQ;
    if (!class) return FALSE;

    TRACE( "%p\n", class );

    user_lock();
    if (class->dce) free_dce( class->dce, 0, &drawables );
    list_remove( &class->entry );
    if (class->hbrBackground > (HBRUSH)(COLOR_GRADIENTINACTIVECAPTION + 1))
        NtGdiDeleteObjectApp( class->hbrBackground );
    *client_menu_name = class->menu_name;
    NtUserDestroyCursor( class->hIconSmIntern, 0 );
    free( class );
    user_unlock();

    release_opengl_drawables( &drawables );
    return TRUE;
}

/***********************************************************************
 *	     NtUserGetClassInfo   (win32u.@)
 */
ATOM WINAPI NtUserGetClassInfoEx( HINSTANCE instance, UNICODE_STRING *name, WNDCLASSEXW *wc,
                                  struct client_menu_name *menu_name, BOOL ansi )
{
    struct object_lock lock = OBJECT_LOCK_INIT;
    const class_shm_t *class_shm;
    NTSTATUS status;
    CLASS *class;
    ATOM atom = 0;

    /* create the desktop window to trigger builtin class registration */
    if (!is_desktop_class( name ) && !is_message_class( name )) get_desktop_window();

    if (!(class = find_class( instance, name ))) return 0;

    while ((status = get_shared_class( class, &lock, &class_shm )) == STATUS_PENDING)
    {
        if (wc)
        {
            wc->style         = class_shm->style;
            wc->lpfnWndProc   = get_winproc( class->winproc, ansi );
            wc->cbClsExtra    = class_shm->cls_extra;
            wc->cbWndExtra    = class_shm->win_extra;
            wc->hInstance     = (instance == ios_cur_user32_module()) ? 0 : instance;
            wc->hIcon         = class->hIcon;
            wc->hIconSm       = class->hIconSm ? class->hIconSm : class->hIconSmIntern;
            wc->hCursor       = class->hCursor;
            wc->hbrBackground = class->hbrBackground;
            wc->lpszMenuName  = ansi ? (const WCHAR *)class->menu_name.nameA : class->menu_name.nameW;
            wc->lpszClassName = name->Buffer;
        }
        atom = class_shm->atom;
    }
    /* iOS-Madeira ml1090: THIS RETURN LEAKED THE USER LOCK, AND THE LEAK KILLED
     * THE SESSION.
     *
     * find_class() returns with the USER lock HELD (release_class_ptr drops
     * it), and upstream's `if (status) return 0;` drops out without releasing.
     * Upstream that path is unreachable: get_shared_class only fails when
     * class->shared is NULL, which a registered class never has.
     *
     * It is reachable HERE because this port added the freed-shared-object
     * guard to get_shared_class/get_shared_window_class above (`if
     * (!object->id) return STATUS_INVALID_HANDLE`) — and that guard exists
     * precisely because class_list is a SINGLE win32u list shared by every
     * pseudo-process, so a process that dies without unregistering leaves
     * entries whose shared object has been freed (id == 0). Any later class
     * lookup that walks onto one of those entries used to spin forever; since
     * the guard it returns an error — through this return, with the lock still
     * held.
     *
     * What that cost on device (logs 75 and 78, two unrelated titles): the
     * very next win32u entry point on the same thread hit user_check_not_lock,
     * which asserted, and the abort could not unwind the mutex — so the
     * session-wide USER lock was left held by a thread that was being killed
     * and every other pseudo-process's message pump parked in
     * __psynch_mutexwait for the rest of the run. Black screen, [frame] n=0.
     *
     * user_check_not_lock() now recovers rather than aborting, but the leak
     * itself is the bug: release the lock on every exit, as every other caller
     * of find_class/get_class_ptr in this file already does. */
    if (status)
    {
        release_class_ptr( class );
        return 0;
    }

    if (menu_name) *menu_name = class->menu_name;
    release_class_ptr( class );
    return atom;
}

/***********************************************************************
 *	     NtUserGetAtomName   (win32u.@)
 */
ULONG WINAPI NtUserGetAtomName( ATOM atom, UNICODE_STRING *name )
{
    WCHAR buffer[MAX_ATOM_LEN];
    UINT size = 0;

    if (atom < MAXINTATOM)
    {
        if (!atom)
        {
            set_ntstatus( STATUS_INVALID_PARAMETER );
            return 0;
        }

        size = integral_atom_name( buffer, sizeof(buffer), atom );
    }
    else
    {
        SERVER_START_REQ( get_user_atom_name )
        {
            req->atom = atom;
            wine_server_set_reply( req, buffer, sizeof(buffer) );
            if (!wine_server_call_err( req ))
            {
                size = wine_server_reply_size( reply );
                buffer[size / sizeof(WCHAR)] = 0;
            }
        }
        SERVER_END_REQ;
        if (!size) return 0;
    }

    if (name->MaximumLength < sizeof(WCHAR))
    {
        RtlSetLastWin32Error( ERROR_INSUFFICIENT_BUFFER );
        return 0;
    }

    size = min( size, name->MaximumLength - sizeof(WCHAR) );
    if (size) memcpy( name->Buffer, buffer, size );
    name->Buffer[size / sizeof(WCHAR)] = 0;
    return size / sizeof(WCHAR);
}

/***********************************************************************
 *       NtUserRegisterWindowMessage   (win32u.@)
 */
ATOM WINAPI NtUserRegisterWindowMessage( UNICODE_STRING *name )
{
    unsigned int status;
    RTL_ATOM atom = 0;

    TRACE( "%s\n", debugstr_us(name) );

    if (!name)
    {
        RtlSetLastWin32Error( ERROR_INVALID_PARAMETER );
        return 0;
    }

    status = is_integral_atom( name->Buffer, name->Length / sizeof(WCHAR), &atom );
    if (status == STATUS_MORE_ENTRIES)
    {
        SERVER_START_REQ( add_user_atom )
        {
            wine_server_add_data( req, name->Buffer, name->Length );
            status = wine_server_call( req );
            atom = reply->atom;
        }
        SERVER_END_REQ;
    }

    TRACE( "%s -> %x\n", debugstr_us(name), status == STATUS_SUCCESS ? atom : 0 );
    set_ntstatus( status );
    return atom;
}

/***********************************************************************
 *	     NtUserGetClassName   (win32u.@)
 */
INT WINAPI NtUserGetClassName( HWND hwnd, BOOL real, UNICODE_STRING *name )
{
    struct object_lock lock = OBJECT_LOCK_INIT;
    const class_shm_t *class_shm;
    WCHAR buffer[MAX_ATOM_LEN];
    NTSTATUS status;
    UINT len = 0;
    int ret;

    TRACE( "%p %x %p\n", hwnd, real, name );

    if (name->MaximumLength <= sizeof(WCHAR))
    {
        RtlSetLastWin32Error( ERROR_INSUFFICIENT_BUFFER );
        return 0;
    }

    while ((status = get_shared_window_class( hwnd, &lock, &class_shm )) == STATUS_PENDING)
    {
        len = class_shm->name_len - class_shm->name_offset * sizeof(WCHAR);
        if (len) memcpy( buffer, (WCHAR *)class_shm->name + class_shm->name_offset, len );
    }

    ret = min( name->MaximumLength - sizeof(WCHAR), len );
    if (ret) memcpy( name->Buffer, buffer, ret );
    name->Buffer[ret / sizeof(WCHAR)] = 0;
    return ret / sizeof(WCHAR);
}

/* Set class info with the wine server. */
static BOOL set_server_info( HWND hwnd, INT offset, LONG_PTR newval, UINT size, ULONG_PTR *oldval )
{
    BOOL ret;

    SERVER_START_REQ( set_class_info )
    {
        req->window = wine_server_user_handle( hwnd );
        req->offset = offset;
        req->size = size;
        req->new_info = newval;
        ret = !wine_server_call_err( req );
        *oldval = reply->old_info;
    }
    SERVER_END_REQ;
    return ret;
}

static ULONG_PTR set_class_long_size( HWND hwnd, INT offset, LONG_PTR newval, UINT size, BOOL ansi )
{
    ULONG_PTR retval = 0;
    HICON small_icon = 0;
    CLASS *class;

    if (!(class = get_class_ptr( hwnd, TRUE ))) return 0;

    switch(offset)
    {
    case GCLP_MENUNAME:
        {
            struct client_menu_name *menu_name = (void *)newval;
            struct client_menu_name prev = class->menu_name;
            class->menu_name = *menu_name;
            *menu_name = prev;
            retval = 0;  /* Old value is now meaningless anyway */
            break;
        }
    case GCLP_WNDPROC:
        retval = (ULONG_PTR)get_winproc( class->winproc, ansi );
        class->winproc = alloc_winproc( (WNDPROC)newval, ansi );
        break;
    case GCLP_HBRBACKGROUND:
        retval = (ULONG_PTR)class->hbrBackground;
        class->hbrBackground = (HBRUSH)newval;
        break;
    case GCLP_HCURSOR:
        retval = (ULONG_PTR)class->hCursor;
        class->hCursor = (HCURSOR)newval;
        break;
    case GCLP_HICON:
        retval = (ULONG_PTR)class->hIcon;
        if (retval == newval) break;
        if (newval && !class->hIconSm)
        {
            release_class_ptr( class );

            small_icon = CopyImage( (HICON)newval, IMAGE_ICON,
                                    get_system_metrics( SM_CXSMICON ),
                                    get_system_metrics( SM_CYSMICON ),
                                    LR_COPYFROMRESOURCE );

            if (!(class = get_class_ptr( hwnd, TRUE )))
            {
                NtUserDestroyCursor( small_icon, 0 );
                return 0;
            }
            if (retval != HandleToUlong( class->hIcon ) || class->hIconSm)
            {
                /* someone beat us, restart */
                release_class_ptr( class );
                NtUserDestroyCursor( small_icon, 0 );
                return set_class_long_size( hwnd, offset, newval, size, ansi );
            }
        }
        if (class->hIconSmIntern) NtUserDestroyCursor( class->hIconSmIntern, 0 );
        class->hIcon = (HICON)newval;
        class->hIconSmIntern = small_icon;
        break;
    case GCLP_HICONSM:
        retval = (ULONG_PTR)class->hIconSm;
        if (retval == newval) break;
        if (retval && !newval && class->hIcon)
        {
            HICON icon = class->hIcon;
            release_class_ptr( class );

            small_icon = CopyImage( icon, IMAGE_ICON,
                                    get_system_metrics( SM_CXSMICON ),
                                    get_system_metrics( SM_CYSMICON ),
                                    LR_COPYFROMRESOURCE );

            if (!(class = get_class_ptr( hwnd, TRUE )))
            {
                NtUserDestroyCursor( small_icon, 0 );
                return 0;
            }
            if (class->hIcon != icon || !class->hIconSm)
            {
                /* someone beat us, restart */
                release_class_ptr( class );
                NtUserDestroyCursor( small_icon, 0 );
                return set_class_long_size( hwnd, offset, newval, size, ansi );
            }
        }
        if (class->hIconSmIntern) NtUserDestroyCursor( class->hIconSmIntern, 0 );
        class->hIconSm = (HICON)newval;
        class->hIconSmIntern = small_icon;
        break;
    case GCL_STYLE:
        if (!set_server_info( hwnd, offset, newval, size, &retval )) break;
        break;
    case GCL_CBWNDEXTRA:
        if (!set_server_info( hwnd, offset, newval, size, &retval )) break;
        break;
    case GCLP_HMODULE:
        if (!set_server_info( hwnd, offset, newval, size, &retval )) break;
        break;
    case GCL_CBCLSEXTRA:  /* cannot change this one */
        RtlSetLastWin32Error( ERROR_INVALID_PARAMETER );
        break;
    default:
        if (offset >= 0) set_server_info( hwnd, offset, newval, size, &retval );
        else RtlSetLastWin32Error( ERROR_INVALID_INDEX );
        break;
    }
    release_class_ptr( class );
    return retval;
}

/***********************************************************************
 *	     NtUserSetClassLong   (win32u.@)
 */
DWORD WINAPI NtUserSetClassLong( HWND hwnd, INT offset, LONG newval, BOOL ansi )
{
    return set_class_long_size( hwnd, offset, newval, sizeof(LONG), ansi );
}

/***********************************************************************
 *	     NtUserSetClassLongPtr   (win32u.@)
 */
ULONG_PTR WINAPI NtUserSetClassLongPtr( HWND hwnd, INT offset, LONG_PTR newval, BOOL ansi )
{
    return set_class_long_size( hwnd, offset, newval, sizeof(LONG_PTR), ansi );
}

/***********************************************************************
 *	     NtUserSetClassWord   (win32u.@)
 */
WORD WINAPI NtUserSetClassWord( HWND hwnd, INT offset, WORD newval )
{
    return set_class_long_size( hwnd, offset, newval, sizeof(WORD), TRUE );
}

static ULONG_PTR get_class_long_shm( HWND hwnd, INT offset, UINT size, BOOL ansi )
{
    struct object_lock lock = OBJECT_LOCK_INIT;
    const class_shm_t *class_shm;
    ULONG_PTR ret = 0;
    BOOL valid = TRUE;
    NTSTATUS status;

    while ((status = get_shared_window_class( hwnd, &lock, &class_shm )) == STATUS_PENDING)
    {
        switch (offset)
        {
        case GCW_ATOM:           ret = class_shm->atom; break;
        case GCL_STYLE:          ret = class_shm->style; break;
        case GCL_CBCLSEXTRA:     ret = class_shm->cls_extra; break;
        case GCL_CBWNDEXTRA:     ret = class_shm->win_extra; break;
        case GCLP_HMODULE:       ret = class_shm->instance; break;
        default:
            valid = offset >= 0 && offset <= (INT)(class_shm->cls_extra - size);
            if (valid) memcpy( &ret, (char *)class_shm->extra + offset, size );
            break;
        }
    }
    if (status)
    {
        RtlSetLastWin32Error( ERROR_INVALID_WINDOW_HANDLE );
        return 0;
    }
    if (!valid)
    {
        WARN( "Invalid window %p offset %d size %u\n", hwnd, offset, size );
        RtlSetLastWin32Error( ERROR_INVALID_INDEX );
        return 0;
    }

    return ret;
}

static ULONG_PTR get_class_long_size( HWND hwnd, INT offset, UINT size, BOOL ansi )
{
    CLASS *class;
    ULONG_PTR retvalue = 0;

    switch (offset)
    {
    case GCLP_HICONSM:
    case GCLP_WNDPROC:
    case GCLP_HICON:
    case GCLP_HCURSOR:
    case GCLP_HBRBACKGROUND:
    case GCLP_MENUNAME:
        break;
    default:
        return get_class_long_shm( hwnd, offset, size, ansi );
    }

    if (!(class = get_class_ptr( hwnd, FALSE ))) return 0;

    if (class == OBJ_OTHER_PROCESS)
    {
        SERVER_START_REQ( get_class_info )
        {
            req->window = wine_server_user_handle( hwnd );
            req->offset = offset;
            req->size = size;
            if (!wine_server_call_err( req ))
            {
                switch (offset)
                {
                case GCLP_HBRBACKGROUND:
                case GCLP_HCURSOR:
                case GCLP_HICON:
                case GCLP_HICONSM:
                case GCLP_WNDPROC:
                case GCLP_MENUNAME:
                    FIXME( "offset %d not supported on other process window %p\n", offset, hwnd );
                    break;
                default:
                    retvalue = reply->info;
                    break;
                }
            }
        }
        SERVER_END_REQ;
        return retvalue;
    }

    switch(offset)
    {
    case GCLP_HBRBACKGROUND:
        retvalue = (ULONG_PTR)class->hbrBackground;
        break;
    case GCLP_HCURSOR:
        retvalue = (ULONG_PTR)class->hCursor;
        break;
    case GCLP_HICON:
        retvalue = (ULONG_PTR)class->hIcon;
        break;
    case GCLP_HICONSM:
        retvalue = (ULONG_PTR)(class->hIconSm ? class->hIconSm : class->hIconSmIntern);
        break;
    case GCLP_WNDPROC:
        retvalue = (ULONG_PTR)get_winproc( class->winproc, ansi );
        break;
    case GCLP_MENUNAME:
        retvalue = ansi ? (ULONG_PTR)class->menu_name.nameA : (ULONG_PTR)class->menu_name.nameW;
        break;
    default:
        RtlSetLastWin32Error( ERROR_INVALID_INDEX );
        break;
    }
    release_class_ptr( class );
    return retvalue;
}

DWORD get_class_long( HWND hwnd, INT offset, BOOL ansi )
{
    return get_class_long_size( hwnd, offset, sizeof(DWORD), ansi );
}

ULONG_PTR get_class_long_ptr( HWND hwnd, INT offset, BOOL ansi )
{
    return get_class_long_size( hwnd, offset, sizeof(ULONG_PTR), ansi );
}

WORD get_class_word( HWND hwnd, INT offset )
{
    return get_class_long_size( hwnd, offset, sizeof(WORD), TRUE );
}

static const struct builtin_class_descr desktop_builtin_class =
{
    .name = "#32769", /* DESKTOP_CLASS_ATOM */
    .style = CS_DBLCLKS,
    .proc = NTUSER_WNDPROC_DESKTOP,
    .brush = (HBRUSH)(COLOR_BACKGROUND + 1),
};

static const struct builtin_class_descr message_builtin_class =
{
    .name = "Message",
    .proc = NTUSER_WNDPROC_MESSAGE,
};

static const struct builtin_class_descr builtin_classes[] =
{
    /* button */
    {
        .name = "Button",
        .style = CS_DBLCLKS | CS_VREDRAW | CS_HREDRAW | CS_PARENTDC,
        .proc = NTUSER_WNDPROC_BUTTON,
        .extra = sizeof(UINT) + 2 * sizeof(HANDLE),
        .cursor = IDC_ARROW,
    },
    /* combo  */
    {
        .name = "ComboBox",
        .style = CS_PARENTDC | CS_DBLCLKS | CS_HREDRAW | CS_VREDRAW,
        .proc = NTUSER_WNDPROC_COMBO,
        .extra = sizeof(void *),
        .cursor = IDC_ARROW,
    },
    /* combolbox */
    {
        .name = "ComboLBox",
        .style = CS_DBLCLKS | CS_SAVEBITS,
        .proc = NTUSER_WNDPROC_COMBOLBOX,
        .extra = sizeof(void *),
        .cursor = IDC_ARROW,
    },
    /* dialog */
    {
        .name = "#32770", /* DIALOG_CLASS_ATOM */
        .style = CS_SAVEBITS | CS_DBLCLKS,
        .proc = NTUSER_WNDPROC_DIALOG,
        .extra = DLGWINDOWEXTRA,
        .cursor = IDC_ARROW,
    },
    /* icon title */
    {
        .name = "#32772", /* ICONTITLE_CLASS_ATOM */
        .proc = NTUSER_WNDPROC_ICONTITLE,
        .cursor = IDC_ARROW,
    },
    /* IME */
    {
        .name = "IME",
        .proc = NTUSER_WNDPROC_IME,
        .extra = 2 * sizeof(LONG_PTR),
        .cursor = IDC_ARROW,
    },
    /* listbox  */
    {
        .name = "ListBox",
        .style = CS_DBLCLKS,
        .proc = NTUSER_WNDPROC_LISTBOX,
        .extra = sizeof(void *),
        .cursor = IDC_ARROW,
    },
    /* menu */
    {
        .name = "#32768", /* POPUPMENU_CLASS_ATOM */
        .style = CS_DROPSHADOW | CS_SAVEBITS | CS_DBLCLKS,
        .proc = NTUSER_WNDPROC_MENU,
        .extra = sizeof(HMENU),
        .cursor = IDC_ARROW,
        .brush = (HBRUSH)(COLOR_MENU + 1),
    },
    /* MDIClient */
    {
        .name = "MDIClient",
        .proc = NTUSER_WNDPROC_MDICLIENT,
        .extra = 2 * sizeof(void *),
        .cursor = IDC_ARROW,
        .brush = (HBRUSH)(COLOR_APPWORKSPACE + 1),
    },
    /* scrollbar */
    {
        .name = "ScrollBar",
        .style = CS_DBLCLKS | CS_VREDRAW | CS_HREDRAW | CS_PARENTDC,
        .proc = NTUSER_WNDPROC_SCROLLBAR,
        .extra = sizeof(struct scroll_bar_win_data),
        .cursor = IDC_ARROW,
    },
    /* static */
    {
        .name = "Static",
        .style = CS_DBLCLKS | CS_PARENTDC,
        .proc = NTUSER_WNDPROC_STATIC,
        .extra = 2 * sizeof(HANDLE),
        .cursor = IDC_ARROW,
    },
};

/***********************************************************************
 *           register_builtin
 *
 * Register a builtin control class.
 * This allows having both ANSI and Unicode winprocs for the same class.
 */
static void register_builtin( const struct builtin_class_descr *descr )
{
    UNICODE_STRING name, version = { .Length = 0 };
    struct client_menu_name menu_name = { 0 };
    WCHAR nameW[64];
    WNDCLASSEXW class = {
        .cbSize = sizeof(class),
        .hInstance = user32_module,
        .style = descr->style,
        .cbWndExtra = descr->extra,
        .hbrBackground = descr->brush,
        .lpfnWndProc = BUILTIN_WINPROC( descr->proc ),
    };

    if (descr->cursor)
        class.hCursor = LoadImageW( 0, (const WCHAR *)descr->cursor, IMAGE_CURSOR,
                                    0, 0, LR_SHARED | LR_DEFAULTSIZE );

    asciiz_to_unicode( nameW, descr->name );
    RtlInitUnicodeString( &name, nameW );

    if (!NtUserRegisterClassExWOW( &class, &name, &version, &menu_name, 1, 0, NULL ) && class.hCursor)
        NtUserDestroyCursor( class.hCursor, 0 );
}

static void register_builtins(void)
{
    ULONG ret_len, i;
    void *ret_ptr;

    /* 64-bit Windows use sizeof(UINT64) for all processes, while 32-bit Windows use 6 for extra
     * bytes size. Civilization II depends on the size being 6, so we use that even in wow64. */
    const struct builtin_class_descr edit_class =
    {
        .name = "Edit",
        .style = CS_DBLCLKS | CS_PARENTDC,
        .proc = NTUSER_WNDPROC_EDIT,
        .extra = sizeof(void *) == 4 || NtCurrentTeb()->WowTebOffset ? 6 : sizeof(UINT64),
        .cursor = IDC_IBEAM,
    };

    for (i = 0; i < ARRAYSIZE(builtin_classes); i++) register_builtin( &builtin_classes[i] );
    register_builtin( &edit_class );
    KeUserModeCallback( NtUserInitBuiltinClasses, NULL, 0, &ret_ptr, &ret_len );
}

/***********************************************************************
 *           register_builtin_classes
 */
void register_builtin_classes(void)
{
    /* iOS-Madeira: all pseudo-processes share this unix-side image, so a
     * pthread_once here registers the builtin classes only for the FIRST
     * process — but the wineserver tracks window classes per process, so
     * every later pseudo-process fails any builtin-control create with
     * STATUS_INVALID_HANDLE (grab_class).  Steam's update UI (STATIC/
     * BUTTON/msctls_progress32 children) was the first victim.
     * Register once per pseudo-process instead, keyed on (pid, peb) so a
     * reused PEB address or ptid alone can't false-positive.  On table
     * overflow we simply re-register: the server rejects duplicates with
     * CLASS_ALREADY_EXISTS, which register_builtin tolerates.
     * The mutex is held across register_builtins to mirror pthread_once's
     * blocking semantics for concurrent first callers (dedicated lock —
     * winproc_lock is taken inside NtUserRegisterClassExWOW). */
    static pthread_mutex_t builtin_lock = PTHREAD_MUTEX_INITIALIZER;
    static struct { DWORD pid; void *peb; } done[128];
    static unsigned int done_count;
    DWORD pid = HandleToULong( NtCurrentTeb()->ClientId.UniqueProcess );
    void *peb = NtCurrentTeb()->Peb;
    unsigned int i;

    pthread_mutex_lock( &builtin_lock );
    for (i = 0; i < done_count; i++)
    {
        if (done[i].pid == pid && done[i].peb == peb)
        {
            pthread_mutex_unlock( &builtin_lock );
            return;
        }
    }
    register_builtins();
    if (done_count < ARRAYSIZE(done))
    {
        done[done_count].pid = pid;
        done[done_count].peb = peb;
        done_count++;
    }
    else dprintf(2, "[builtin-classes] registry FULL — pid=%04x will re-register per call\n", (int)pid);
    dprintf(2, "[builtin-classes] registered builtin classes for pid=%04x peb=%p\n", (int)pid, peb);
    pthread_mutex_unlock( &builtin_lock );
}

/***********************************************************************
 *           register_desktop_class
 */
void register_desktop_class(void)
{
    register_builtin( &desktop_builtin_class );
    register_builtin( &message_builtin_class );
}
