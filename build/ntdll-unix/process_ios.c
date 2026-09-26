/*
 * NT process handling
 *
 * Copyright 1996-1998 Marcus Meissner
 * Copyright 2018, 2020 Alexandre Julliard
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

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/time.h>
#ifdef HAVE_SYS_TIMES_H
# include <sys/times.h>
#endif
#include <sys/types.h>
#include <sys/wait.h>
#ifdef HAVE_SYS_SYSCTL_H
# include <sys/sysctl.h>
#endif
#ifdef HAVE_SYS_PARAM_H
# include <sys/param.h>
#endif
#ifdef HAVE_SYS_QUEUE_H
# include <sys/queue.h>
#endif
#ifdef HAVE_SYS_USER_H
# include <sys/user.h>
#endif
#ifdef HAVE_LIBPROCSTAT_H
# include <libprocstat.h>
#endif
#include <unistd.h>
#ifdef HAVE_MACH_MACH_H
# include <mach/mach.h>
#endif

#ifdef WINE_IOS
#include <pthread.h>
#include <setjmp.h>
#endif

#include "ntstatus.h"
#include "windef.h"
#include "winternl.h"
#include "winioctl.h"
#include "ddk/ntddk.h"
#include "unix_private.h"
#include "ios_wow.h"
#include "wine/condrv.h"
#include "wine/server.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(process);


static ULONG execute_flags = MEM_EXECUTE_OPTION_DISABLE;

static UINT process_error_mode;
ULONG process_cookie = 0xdeadbeef;

static char **build_argv( const UNICODE_STRING *cmdline, int reserved )
{
    char **argv, *arg, *src, *dst;
    int argc, in_quotes = 0, bcount = 0, len = cmdline->Length / sizeof(WCHAR);

    if (!(src = malloc( len * 3 + 1 ))) return NULL;
    len = ntdll_wcstoumbs( cmdline->Buffer, len, src, len * 3, FALSE );
    src[len++] = 0;

    argc = reserved + 2 + len / 2;
    argv = malloc( argc * sizeof(*argv) + len );
    arg = dst = (char *)(argv + argc);
    argc = reserved;
    while (*src)
    {
        if ((*src == ' ' || *src == '\t') && !in_quotes)
        {
            /* skip the remaining spaces */
            while (*src == ' ' || *src == '\t') src++;
            if (!*src) break;
            /* close the argument and copy it */
            *dst++ = 0;
            argv[argc++] = arg;
            /* start with a new argument */
            arg = dst;
            bcount = 0;
        }
        else if (*src == '\\')
        {
            *dst++ = *src++;
            bcount++;
        }
        else if (*src == '"')
        {
            if ((bcount & 1) == 0)
            {
                /* Preceded by an even number of '\', this is half that
                 * number of '\', plus a '"' which we discard.
                 */
                dst -= bcount / 2;
                src++;
                if (in_quotes && *src == '"') *dst++ = *src++;
                else in_quotes = !in_quotes;
            }
            else
            {
                /* Preceded by an odd number of '\', this is half that
                 * number of '\' followed by a '"'
                 */
                dst -= bcount / 2 + 1;
                *dst++ = *src++;
            }
            bcount = 0;
        }
        else  /* a regular character */
        {
            *dst++ = *src++;
            bcount = 0;
        }
    }
    *dst = 0;
    argv[argc++] = arg;
    argv[argc] = NULL;
    return argv;
}


/***********************************************************************
 *           get_non_pe_file_info
 */
static NTSTATUS get_non_pe_file_info( int fd, struct pe_image_info *info )
{
    union
    {
        struct
        {
            unsigned char magic[4];
            unsigned char class;
            unsigned char data;
            unsigned char version;
            unsigned char ignored1[9];
            unsigned short type;
            unsigned short machine;
            unsigned char ignored2[8];
            unsigned int phoff;
            unsigned char ignored3[12];
            unsigned short phnum;
        } elf;
        struct
        {
            unsigned char magic[4];
            unsigned char class;
            unsigned char data;
            unsigned char ignored1[10];
            unsigned short type;
            unsigned short machine;
            unsigned char ignored2[12];
            unsigned __int64 phoff;
            unsigned char ignored3[16];
            unsigned short phnum;
        } elf64;
        struct
        {
            unsigned int magic;
            unsigned int cputype;
            unsigned int cpusubtype;
            unsigned int filetype;
        } macho;
        IMAGE_DOS_HEADER mz;
    } header;

    off_t pos;

    if (pread( fd, &header, sizeof(header), 0 ) != sizeof(header)) return STATUS_INVALID_IMAGE_NOT_MZ;

    if (!memcmp( header.elf.magic, "\177ELF", 4 ))
    {
        unsigned int type;
        unsigned short phnum;

        if (header.elf.version != 1 /* EV_CURRENT */) return STATUS_INVALID_IMAGE_NOT_MZ;
#ifdef WORDS_BIGENDIAN
        if (header.elf.data != 2 /* ELFDATA2MSB */) return STATUS_INVALID_IMAGE_NOT_MZ;
#else
        if (header.elf.data != 1 /* ELFDATA2LSB */) return STATUS_INVALID_IMAGE_NOT_MZ;
#endif
        switch (header.elf.machine)
        {
        case 3:   info->machine = IMAGE_FILE_MACHINE_I386; break;
        case 40:  info->machine = IMAGE_FILE_MACHINE_ARMNT; break;
        case 62:  info->machine = IMAGE_FILE_MACHINE_AMD64; break;
        case 183: info->machine = IMAGE_FILE_MACHINE_ARM64; break;
        }
        if (header.elf.type != 3 /* ET_DYN */) return STATUS_INVALID_IMAGE_NOT_MZ;
        if (header.elf.class == 2 /* ELFCLASS64 */)
        {
            pos = header.elf64.phoff;
            phnum = header.elf64.phnum;
        }
        else
        {
            pos = header.elf.phoff;
            phnum = header.elf.phnum;
        }
        while (phnum--)
        {
            if (pread( fd, &type, sizeof(type), pos ) != sizeof(type)) return STATUS_INVALID_IMAGE_NOT_MZ;
            if (type == 3 /* PT_INTERP */) return STATUS_INVALID_IMAGE_NOT_MZ;
            pos += (header.elf.class == 2) ? 56 : 32;
        }
        return STATUS_SUCCESS;
    }
    else if (header.macho.magic == 0xfeedface || header.macho.magic == 0xfeedfacf)
    {
        switch (header.macho.cputype)
        {
        case 0x00000007: info->machine = IMAGE_FILE_MACHINE_I386; break;
        case 0x01000007: info->machine = IMAGE_FILE_MACHINE_AMD64; break;
        case 0x0000000c: info->machine = IMAGE_FILE_MACHINE_ARMNT; break;
        case 0x0100000c: info->machine = IMAGE_FILE_MACHINE_ARM64; break;
        }
        if (header.macho.filetype == 8) return STATUS_SUCCESS;
    }
    else if (header.mz.e_magic == IMAGE_DOS_SIGNATURE)
    {
        IMAGE_OS2_HEADER os2;

        if (pread( fd, &os2, sizeof(os2), header.mz.e_lfanew ) != sizeof(os2))
            return STATUS_INVALID_IMAGE_PROTECT;
        if (os2.ne_magic != IMAGE_OS2_SIGNATURE) return STATUS_INVALID_IMAGE_PROTECT;
        if (os2.ne_exetyp != 2) return STATUS_INVALID_IMAGE_NE_FORMAT;
        if (os2.ne_flags & 0x8000 /* NE_FFLAGS_LIBMODULE */) return STATUS_INVALID_IMAGE_FORMAT;
        return STATUS_INVALID_IMAGE_WIN_16;
    }
    return STATUS_INVALID_IMAGE_NOT_MZ;
}


/***********************************************************************
 *           get_pe_file_info
 */
static unsigned int get_pe_file_info( OBJECT_ATTRIBUTES *attr, UNICODE_STRING *nt_name,
                                      char **unix_name, HANDLE *handle, struct pe_image_info *info )
{
    unsigned int status;
    HANDLE mapping;

    *handle = 0;
    memset( info, 0, sizeof(*info) );
    if (!(status = get_nt_and_unix_names( attr, nt_name, unix_name, FILE_OPEN, FALSE )))
    {
        status = open_unix_file( handle, *unix_name, GENERIC_READ, attr, 0,
                                 FILE_SHARE_READ | FILE_SHARE_DELETE,
                                 FILE_OPEN, FILE_SYNCHRONOUS_IO_NONALERT, NULL, 0 );
    }
    if (status)
    {
        if (is_builtin_path( attr->ObjectName, &info->machine ))
        {
            TRACE( "assuming %04x builtin for %s\n", info->machine, debugstr_us(attr->ObjectName));
            return STATUS_SUCCESS;
        }
        return status;
    }

    if (!(status = NtCreateSection( &mapping, STANDARD_RIGHTS_REQUIRED | SECTION_QUERY |
                                    SECTION_MAP_READ | SECTION_MAP_EXECUTE,
                                    NULL, NULL, PAGE_EXECUTE_READ, SEC_IMAGE, *handle )))
    {
        SERVER_START_REQ( get_mapping_info )
        {
            req->handle = wine_server_obj_handle( mapping );
            req->access = SECTION_QUERY;
            wine_server_set_reply( req, info, sizeof(*info) );
            status = wine_server_call( req );
        }
        SERVER_END_REQ;
        NtClose( mapping );
        if (info->image_charact & IMAGE_FILE_DLL) return STATUS_INVALID_IMAGE_FORMAT;
    }
    else if (status == STATUS_INVALID_IMAGE_NOT_MZ || status == STATUS_INVALID_IMAGE_WIN_16)
    {
        int unix_fd, needs_close;

        if (!server_get_unix_fd( *handle, FILE_READ_DATA, &unix_fd, &needs_close, NULL, NULL ))
        {
            status = get_non_pe_file_info( unix_fd, info );
            if (needs_close) close( unix_fd );
        }
    }
    return status;
}


/***********************************************************************
 *           get_env_size
 */
static ULONG get_env_size( const RTL_USER_PROCESS_PARAMETERS *params, char **winedebug )
{
    WCHAR *ptr = params->Environment;

    while (*ptr)
    {
        static const WCHAR WINEDEBUG[] = {'W','I','N','E','D','E','B','U','G','=',0};
        if (!*winedebug && !wcsncmp( ptr, WINEDEBUG, ARRAY_SIZE( WINEDEBUG ) - 1 ))
        {
            DWORD len = wcslen(ptr) * 3 + 1;
            if ((*winedebug = malloc( len )))
                ntdll_wcstoumbs( ptr, wcslen(ptr) + 1, *winedebug, len, FALSE );
        }
        ptr += wcslen(ptr) + 1;
    }
    ptr++;
    return (ptr - params->Environment) * sizeof(WCHAR);
}


/***********************************************************************
 *           get_unix_curdir
 */
static int get_unix_curdir( const RTL_USER_PROCESS_PARAMETERS *params )
{
    UNICODE_STRING nt_name, true_nt_name;
    OBJECT_ATTRIBUTES attr;
    NTSTATUS status;
    HANDLE handle;
    int fd = -1;
    char *unix_name;

    if (get_nt_path( params->CurrentDirectory.DosPath.Buffer, &nt_name )) return -1;
    nt_name.Length = wcslen( nt_name.Buffer ) * sizeof(WCHAR);

    InitializeObjectAttributes( &attr, &nt_name, OBJ_CASE_INSENSITIVE, 0, NULL );
    status = get_nt_and_unix_names( &attr, &true_nt_name, &unix_name, FILE_OPEN, FALSE );
    if (status) goto done;
    status = open_unix_file( &handle, unix_name, FILE_TRAVERSE | SYNCHRONIZE, &attr, 0,
                             FILE_SHARE_READ | FILE_SHARE_DELETE,
                             FILE_OPEN, FILE_SYNCHRONOUS_IO_NONALERT, NULL, 0 );
    if (status) goto done;
    wine_server_handle_to_fd( handle, FILE_TRAVERSE, &fd, NULL );
    NtClose( handle );

done:
    free( unix_name );
    free( nt_name.Buffer );
    free( true_nt_name.Buffer );
    return fd;
}


/***********************************************************************
 *           set_stdio_fd
 */
static void set_stdio_fd( int stdin_fd, int stdout_fd )
{
    int fd = -1;

    if (stdin_fd == -1 || stdout_fd == -1)
    {
        fd = open( "/dev/null", O_RDWR );
        if (stdin_fd == -1) stdin_fd = fd;
        if (stdout_fd == -1) stdout_fd = fd;
    }

    if (stdin_fd != 0) dup2( stdin_fd, 0 );
    if (stdout_fd != 1) dup2( stdout_fd, 1 );
    if (fd != -1) close( fd );
}


/***********************************************************************
 *           is_unix_console_handle
 */
static BOOL is_unix_console_handle( HANDLE handle )
{
    return !sync_ioctl( handle, IOCTL_CONDRV_IS_UNIX, NULL, 0, NULL, 0 );
}


/***********************************************************************
 *           spawn_process
 */
#ifdef WINE_IOS
/* Child process thread entry point */
extern void wine_ios_child_main( int argc, char *argv[], int child_fd_socket );

/* Thread-local exit handling (from wine_ios_exit.h) */
extern _Thread_local jmp_buf wine_ios_exit_jmpbuf;
extern _Thread_local volatile int wine_ios_exit_code;
extern _Thread_local pthread_t wine_ios_main_thread;
extern _Thread_local int wine_ios_exit_initialized;

struct ios_child_args {
    int socketfd;
    int unixdir;
    char **argv;
    int argc;
    struct pe_image_info pe_info;
};

/* WOW64_DESIGN.md §2: the machine of the child's main image, published to
 * wine_ios_child_main so it can reserve the child's [B, B+4G) guest window
 * BEFORE allocating the child's TEB/PEB pair — those must live in the window
 * (guest code reads TEB32->Self / TEB32->Peb as 32-bit guest addresses), and
 * unix_init_startup_info, which is where the machine would otherwise first be
 * known, runs long after the TEB exists.  The parent already has the image
 * info in struct ios_child_args. */
_Thread_local WORD ios_child_main_machine;

/* Where this child currently is in wine_ios_child_main (which updates it).  A
 * child that dies during bring-up used to leave no trace at all beyond a couple
 * of dprintf lines, so a failed CreateProcess from the desktop looked like
 * nothing happening; the thread entry below names the stage in one ERR. */
_Thread_local const char *ios_child_boot_stage = "not started";

static void *ios_child_thread_entry( void *arg )
{
    struct ios_child_args *args = arg;

    ios_child_main_machine = args->pe_info.machine;

    /* Use dprintf for early logging — ERR requires TEB which isn't set up yet */
    dprintf(STDERR_FILENO, "[Wine child thread] ENTRY: fd=%d, argc=%d, machine=0x%x, exe=%s\n",
            args->socketfd, args->argc, args->pe_info.machine,
            args->argc > 1 ? args->argv[1] : "(none)");

    /* Set up exit handling for this child thread */
    wine_ios_main_thread = pthread_self();
    wine_ios_exit_initialized = 1;

    if (setjmp(wine_ios_exit_jmpbuf) == 0) {
        /* Change working directory if requested */
        if (args->unixdir != -1) {
            fchdir( args->unixdir );
            close( args->unixdir );
        }

        dprintf(STDERR_FILENO, "[Wine child thread] calling wine_ios_child_main...\n");
        wine_ios_child_main( args->argc, args->argv, args->socketfd );
        /* Should not return: every return is a bring-up failure. */
        dprintf(STDERR_FILENO, "[Wine child thread] wine_ios_child_main returned unexpectedly!\n");
        ERR( "spawn_process: child %s (machine %04x) FAILED to boot at stage '%s'; "
             "CreateProcess in the parent will report failure\n",
             args->argc > 1 ? args->argv[1] : "?", args->pe_info.machine,
             ios_child_boot_stage );

        /* CRITICAL: hand the wineserver the EOF it is waiting for.
         *
         * NtCreateUserProcess blocks in NtWaitForSingleObject( process_info )
         * until the new process either finishes init_process_done or DIES.  The
         * server only learns a pseudo-process died when its side of the
         * socketpair reaches EOF — and the only remaining reference to this
         * child's end is args->socketfd (the parent closed socketfd[0] right
         * after spawn_process returned).  Leaving it open therefore wedged the
         * SPAWNER forever: a desktop double-click that failed anywhere in
         * wine_ios_child_main produced no window, no error and no return from
         * CreateProcess.  Closing it turns the same failure into a reported
         * STATUS_INTERNAL_ERROR from NtCreateUserProcess. */
        if (args->socketfd != -1)
        {
            close( args->socketfd );
            args->socketfd = -1;
        }
    } else {
        dprintf(STDERR_FILENO, "[Wine child thread] child exited with code %d\n", wine_ios_exit_code);
    }

    dprintf(STDERR_FILENO, "[Wine child thread] thread exiting cleanly\n");
    /* WOW64_DESIGN.md §2: the pseudo-process is over — give its guest window
     * back so the next 32-bit pseudo-process can adopt the slot (a launcher
     * starting the real program is the normal shape of a 32-bit title).  Must
     * run while this thread still resolves to that process (before the TEB TLS
     * slot is cleared below).
     *
     * The ORDINARY exit already did this from process_exit_wrapper, keyed by
     * the dying PEB; this call is the FALLBACK for a child that never got far
     * enough to bind its window to a PEB — a boot failure, where the only way
     * back to the slot is the owner-thread match in ios_wow_slot_current().
     * It is a no-op once the window has been released. */
    ios_wow_window_release_current();
    free( args->argv );
    free( args );

    /* Drop our TEB reference before the implicit pthread_exit. This used to
     * zero raw slot 275, which we squatted without owning: its real owner is
     * a foreign Apple key whose ObjC destructor would have run on our TEB and
     * crashed in objc_release (S0 bugs 3+7). We now only publish through our
     * own key, whose destructor is NULL, so clearing it is all that is left. */
    {
        extern pthread_key_t ios_teb_tls_key;
        pthread_setspecific( ios_teb_tls_key, NULL );
    }
    return NULL;
}
#endif

static NTSTATUS spawn_process( const RTL_USER_PROCESS_PARAMETERS *params, int socketfd,
                               int unixdir, char *winedebug, const struct pe_image_info *pe_info )
{
#ifdef WINE_IOS
    /* iOS: create a thread instead of fork+exec */
    char **argv;
    struct ios_child_args *args;
    pthread_t child_thread;
    int ret, argc;

    argv = build_argv( &params->CommandLine, 2 );
    if (!argv) return STATUS_NO_MEMORY;

    /* argv[0] and argv[1] are reserved for preloader/loader — set them */
    argv[0] = (char *)"wine";
    argv[1] = (char *)"wine";

    /* Count argc */
    for (argc = 0; argv[argc]; argc++);

    args = calloc( 1, sizeof(*args) );
    if (!args) { free( argv ); return STATUS_NO_MEMORY; }

    /* dup the socketfd — parent will close the original after we return */
    args->socketfd = dup( socketfd );
    /* dup the unixdir — parent will also close the original (iOS shares fd table) */
    args->unixdir = (unixdir != -1) ? dup( unixdir ) : -1;
    args->argv = argv;
    args->argc = argc;
    args->pe_info = *pe_info;

    if (winedebug) putenv( winedebug );

    ERR("spawn_process: creating child thread for %s (fd=%d, unixdir=%d, dup_unixdir=%d)\n",
        debugstr_us(&params->CommandLine), socketfd, unixdir, args->unixdir);

    ret = pthread_create( &child_thread, NULL, ios_child_thread_entry, args );
    if (ret) {
        ERR("spawn_process: pthread_create failed: %d\n", ret);
        free( argv );
        free( args );
        return STATUS_NO_MEMORY;
    }
    pthread_detach( child_thread );

    return STATUS_SUCCESS;
#else
    NTSTATUS status = STATUS_SUCCESS;
    int stdin_fd = -1, stdout_fd = -1;
    pid_t pid;
    char **argv;

    if (wine_server_handle_to_fd( params->hStdInput, FILE_READ_DATA, &stdin_fd, NULL ) &&
        isatty(0) && is_unix_console_handle( params->hStdInput ))
        stdin_fd = 0;

    if (wine_server_handle_to_fd( params->hStdOutput, FILE_WRITE_DATA, &stdout_fd, NULL ) &&
        isatty(1) && is_unix_console_handle( params->hStdOutput ))
        stdout_fd = 1;

    if (!(pid = fork()))  /* child */
    {
        if (!(pid = fork()))  /* grandchild */
        {
            if ((peb->ProcessParameters && params->ProcessGroupId != peb->ProcessParameters->ProcessGroupId) ||
                params->ConsoleHandle == CONSOLE_HANDLE_ALLOC ||
                params->ConsoleHandle == CONSOLE_HANDLE_ALLOC_NO_WINDOW ||
                params->ConsoleHandle == NULL)
            {
                setsid();
                set_stdio_fd( -1, -1 );  /* close stdin and stdout */
            }
            else set_stdio_fd( stdin_fd, stdout_fd );

            if (stdin_fd != -1 && stdin_fd != 0) close( stdin_fd );
            if (stdout_fd != -1 && stdout_fd != 1) close( stdout_fd );

            if (winedebug) putenv( winedebug );
            if (unixdir != -1)
            {
                fchdir( unixdir );
                close( unixdir );
            }
            argv = build_argv( &params->CommandLine, 2 );

            exec_wineloader( argv, socketfd, pe_info );
            _exit(1);
        }

        _exit(pid == -1);
    }

    if (pid != -1)
    {
        /* reap child */
        pid_t wret;
        do {
            wret = waitpid(pid, NULL, 0);
        } while (wret < 0 && errno == EINTR);
    }
    else status = STATUS_NO_MEMORY;

    if (stdin_fd != -1 && stdin_fd != 0) close( stdin_fd );
    if (stdout_fd != -1 && stdout_fd != 1) close( stdout_fd );
    return status;
#endif
}


/***********************************************************************
 *           __wine_unix_spawnvp
 */
NTSTATUS WINAPI __wine_unix_spawnvp( char * const argv[], int wait )
{
#ifdef WINE_IOS
    /* No fork/exec on iOS */
    return STATUS_NOT_SUPPORTED;
#else
    pid_t pid, wret;
    int fd[2], status, err;

#ifdef HAVE_PIPE2
    if (pipe2( fd, O_CLOEXEC ) == -1)
#endif
    {
        if (pipe(fd) == -1) return STATUS_TOO_MANY_OPENED_FILES;
        fcntl( fd[0], F_SETFD, FD_CLOEXEC );
        fcntl( fd[1], F_SETFD, FD_CLOEXEC );
    }

    if (!(pid = fork()))
    {
        /* in child */
        close( fd[0] );
        signal( SIGPIPE, SIG_DFL );
        if (!wait)
        {
            if (!(pid = fork())) execvp( argv[0], argv ); /* in grandchild */
            if (pid > 0) _exit(0); /* exit child if fork succeeded */
        }
        else execvp( argv[0], argv );

        err = errno_to_status( errno );
        write( fd[1], &err, sizeof(err) );
        _exit(1);
    }
    close( fd[1] );

    if (pid != -1)
    {
        while (pid != (wret = waitpid( pid, &status, 0 )))
            if (wret == -1 && errno != EINTR) break;

        if (read( fd[0], &err, sizeof(err) ) <= 0)  /* if we read something, exec or second fork failed */
        {
            if (pid == wret && WIFEXITED(status)) err = WEXITSTATUS(status);
            else err = 255;  /* abnormal exit with an abort or an interrupt */
        }
    }
    else err = errno_to_status( errno );

    close( fd[0] );
    return err;
#endif
}


/***********************************************************************
 *           unixcall_wine_spawnvp
 */
NTSTATUS unixcall_wine_spawnvp( void *args )
{
    struct wine_spawnvp_params *params = args;

    return __wine_unix_spawnvp( params->argv, params->wait );
}


#ifdef _WIN64
/***********************************************************************
 *		wow64_wine_spawnvp
 */
NTSTATUS wow64_wine_spawnvp( void *args )
{
    struct
    {
        ULONG argv;
        int   wait;
    } const *params32 = args;

    /* WOW64_DESIGN.md §2: the argv ARRAY is an embedded guest pointer, and so
     * is every string in it — both need +B (the outer args block is the only
     * pointer the WoW64 module converts). */
    ULONG *argv32 = ios_wow_host_ptr( params32->argv );
    unsigned int i, count = 0;
    char **argv;
    NTSTATUS ret;

    if (!argv32) return STATUS_INVALID_PARAMETER;
    while (argv32[count]) count++;
    argv = malloc( (count + 1) * sizeof(*argv) );
    if (!argv) return STATUS_NO_MEMORY;
    for (i = 0; i < count; i++) argv[i] = ios_wow_host_ptr( argv32[i] );
    argv[count] = NULL;
    ret = __wine_unix_spawnvp( argv, params32->wait );
    free( argv );
    return ret;
}
#endif

/***********************************************************************
 *           fork_and_exec
 *
 * Fork and exec a new Unix binary, checking for errors.
 */
static NTSTATUS fork_and_exec( OBJECT_ATTRIBUTES *attr, const char *unix_name, int unixdir,
                               const RTL_USER_PROCESS_PARAMETERS *params )
{
#ifdef WINE_IOS
    /* No fork on iOS */
    return STATUS_NOT_SUPPORTED;
#else
    pid_t pid;
    int fd[2], stdin_fd = -1, stdout_fd = -1;
    char **argv;
    NTSTATUS status = STATUS_SUCCESS;

#ifdef HAVE_PIPE2
    if (pipe2( fd, O_CLOEXEC ) == -1)
#endif
    {
        if (pipe(fd) == -1) return STATUS_TOO_MANY_OPENED_FILES;
        fcntl( fd[0], F_SETFD, FD_CLOEXEC );
        fcntl( fd[1], F_SETFD, FD_CLOEXEC );
    }

    if (wine_server_handle_to_fd( params->hStdInput, FILE_READ_DATA, &stdin_fd, NULL ) &&
        isatty(0) && is_unix_console_handle( params->hStdInput ))
        stdin_fd = 0;

    if (wine_server_handle_to_fd( params->hStdOutput, FILE_WRITE_DATA, &stdout_fd, NULL ) &&
        isatty(1) && is_unix_console_handle( params->hStdOutput ))
        stdout_fd = 1;

    if (!(pid = fork()))  /* child */
    {
        if (!(pid = fork()))  /* grandchild */
        {
            close( fd[0] );

            if ((peb->ProcessParameters && params->ProcessGroupId != peb->ProcessParameters->ProcessGroupId) ||
                params->ConsoleHandle == CONSOLE_HANDLE_ALLOC ||
                params->ConsoleHandle == CONSOLE_HANDLE_ALLOC_NO_WINDOW ||
                params->ConsoleHandle == NULL)
            {
                setsid();
                set_stdio_fd( -1, -1 );  /* close stdin and stdout */
            }
            else set_stdio_fd( stdin_fd, stdout_fd );

            if (stdin_fd != -1 && stdin_fd != 0) close( stdin_fd );
            if (stdout_fd != -1 && stdout_fd != 1) close( stdout_fd );

            /* Reset signals that we previously set to SIG_IGN */
            signal( SIGPIPE, SIG_DFL );

            argv = build_argv( &params->CommandLine, 0 );
            if (unixdir != -1)
            {
                fchdir( unixdir );
                close( unixdir );
            }
            execv( unix_name, argv );
        }

        if (pid <= 0)  /* grandchild if exec failed or child if fork failed */
        {
            switch (errno)
            {
            case EPERM:
            case EACCES: status = STATUS_ACCESS_DENIED; break;
            case ENOENT: status = STATUS_OBJECT_NAME_NOT_FOUND; break;
            case EMFILE:
            case ENFILE: status = STATUS_TOO_MANY_OPENED_FILES; break;
            case ENOEXEC:
            case EINVAL: status = STATUS_INVALID_IMAGE_FORMAT; break;
            default:     status = STATUS_NO_MEMORY; break;
            }
            write( fd[1], &status, sizeof(status) );
            _exit(1);
        }
        _exit(0); /* child if fork succeeded */
    }
    close( fd[1] );

    if (pid != -1)
    {
        /* reap child */
        pid_t wret;
        do {
            wret = waitpid(pid, NULL, 0);
        } while (wret < 0 && errno == EINTR);
        read( fd[0], &status, sizeof(status) );  /* if we read something, exec or second fork failed */
    }
    else status = STATUS_NO_MEMORY;

    close( fd[0] );
    if (stdin_fd != -1 && stdin_fd != 0) close( stdin_fd );
    if (stdout_fd != -1 && stdout_fd != 1) close( stdout_fd );
    return status;
#endif
}

static NTSTATUS alloc_handle_list( const PS_ATTRIBUTE *handles_attr, obj_handle_t **handles, data_size_t *handles_len )
{
    SIZE_T count, i;
    HANDLE *src;

    *handles = NULL;
    *handles_len = 0;

    if (!handles_attr) return STATUS_SUCCESS;

    count = handles_attr->Size / sizeof(HANDLE);

    if (!(*handles = calloc( sizeof(**handles), count ))) return STATUS_NO_MEMORY;

    src = handles_attr->ValuePtr;
    for (i = 0; i < count; ++i)
        (*handles)[i] = wine_server_obj_handle( src[i] );

    *handles_len = count * sizeof(**handles);

    return STATUS_SUCCESS;
}

/**********************************************************************
 *           NtCreateUserProcess  (NTDLL.@)
 */
NTSTATUS WINAPI NtCreateUserProcess( HANDLE *process_handle_ptr, HANDLE *thread_handle_ptr,
                                     ACCESS_MASK process_access, ACCESS_MASK thread_access,
                                     OBJECT_ATTRIBUTES *process_attr, OBJECT_ATTRIBUTES *thread_attr,
                                     ULONG process_flags, ULONG thread_flags,
                                     RTL_USER_PROCESS_PARAMETERS *params, PS_CREATE_INFO *info,
                                     PS_ATTRIBUTE_LIST *ps_attr )
{
    unsigned int status;
    BOOL success = FALSE;
    HANDLE file_handle, process_info = 0, process_handle = 0, thread_handle = 0;
    struct object_attributes *objattr;
    data_size_t attr_len;
    char *winedebug = NULL;
    char *unix_name = NULL;
    struct startup_info_data *startup_info = NULL;
    ULONG startup_info_size, env_size;
    int unixdir, socketfd[2] = { -1, -1 };
    struct pe_image_info pe_info;
    CLIENT_ID id;
    USHORT machine = 0;
    HANDLE parent = 0, debug = 0, token = 0;
    UNICODE_STRING nt_name, path = {0};
    OBJECT_ATTRIBUTES attr, empty_attr = { sizeof(empty_attr) };
    SIZE_T i, attr_count = (ps_attr->TotalLength - sizeof(ps_attr->TotalLength)) / sizeof(PS_ATTRIBUTE);
    const PS_ATTRIBUTE *handles_attr = NULL, *jobs_attr = NULL;
    data_size_t handles_size, jobs_size;
    obj_handle_t *handles, *jobs;

    if (thread_flags & THREAD_CREATE_FLAGS_HIDE_FROM_DEBUGGER)
    {
        WARN( "Invalid thread flags %#x.\n", thread_flags );

        return STATUS_INVALID_PARAMETER;
    }

    if (thread_flags & ~THREAD_CREATE_FLAGS_CREATE_SUSPENDED)
        FIXME( "Unsupported thread flags %#x.\n", thread_flags );

    for (i = 0; i < attr_count; i++)
    {
        switch (ps_attr->Attributes[i].Attribute)
        {
        case PS_ATTRIBUTE_PARENT_PROCESS:
            parent = ps_attr->Attributes[i].ValuePtr;
            break;
        case PS_ATTRIBUTE_DEBUG_PORT:
            debug = ps_attr->Attributes[i].ValuePtr;
            break;
        case PS_ATTRIBUTE_IMAGE_NAME:
            path.Length = ps_attr->Attributes[i].Size;
            path.Buffer = ps_attr->Attributes[i].ValuePtr;
            break;
        case PS_ATTRIBUTE_TOKEN:
            token = ps_attr->Attributes[i].ValuePtr;
            break;
        case PS_ATTRIBUTE_HANDLE_LIST:
            if (process_flags & PROCESS_CREATE_FLAGS_INHERIT_HANDLES)
                handles_attr = &ps_attr->Attributes[i];
            break;
        case PS_ATTRIBUTE_JOB_LIST:
            jobs_attr = &ps_attr->Attributes[i];
            break;
        case PS_ATTRIBUTE_MACHINE_TYPE:
            machine = ps_attr->Attributes[i].Value;
            break;
        default:
            if (ps_attr->Attributes[i].Attribute & PS_ATTRIBUTE_INPUT)
                FIXME( "unhandled input attribute %lx\n", ps_attr->Attributes[i].Attribute );
            break;
        }
    }
    if (!process_attr) process_attr = &empty_attr;

    TRACE( "%s image %s cmdline %s parent %p machine %x\n", debugstr_us( &path ),
           debugstr_us( &params->ImagePathName ), debugstr_us( &params->CommandLine ), parent, machine );
#ifdef WINE_IOS
    ERR("NtCreateUserProcess: image=%s cmdline=%s\n",
        debugstr_us( &params->ImagePathName ), debugstr_us( &params->CommandLine ));

    /* TEMP HACK (Steam S3 2026-07-10, task #29): refuse to spawn Steam's
     * minidump reporter. The reporter child hits the deep guest-exception-
     * DISPATCH wall ("exception frame is not in stack limits") and — worse —
     * its NtTerminateProcess currently takes the whole app down (open bug).
     * Steam explicitly tolerates a failed spawn ("Failed spawning steam
     * error reporter process." → continues), verified run 9. Remove once
     * (a) exception dispatch at guest faults works and (b) the pseudo-proc
     * terminate path no longer kills the session. */
    /* ml178: gldriverquery64 joins the gate for a DIFFERENT and more permanent
     * reason. It is Steam's OpenGL driver probe, and this device has no GL driver
     * at all — we render through DXMT/Metal. With MSVCR120.dll now shipped it
     * loads and resolves its whole import chain (verified ml178), gets as far as
     * querying, finds nothing, and dies on a NULL read:
     *   "Unhandled page fault on read access to 0000000000000000 ... thread 010c"
     * There is no result it could ever return here, and Steam treats a missing
     * GL probe as "no GL" and carries on — the same tolerance it shows for a
     * failed error-reporter spawn. Refusing the spawn is strictly better than
     * letting it fault. */
    /* ml410: vulkandriverquery joins for a THIRD reason. Steam ships it as a
     * 32-BIT x86 exe (vulkandriverquery64 is the 64-bit sibling); a 32-bit
     * child needs build_wow64_parameters, whose NtAllocateVirtualMemory below
     * 2GB can never succeed on iOS (4GB page zero) — assert-abort in the
     * child's init thread, then garbage execution near the TEB band (the
     * deterministic 0x73ffd65f40 crash of ml407/ml410). No 32-bit child can
     * ever work under this port; there is no Vulkan driver here anyway, and
     * Steam tolerates the refusal exactly like gldriverquery. */
    /* ml497: steamsysinfo.exe joins the gate. It faulted (c0000005 inside
     * steamsysinfo.exe+0xcb78c → crashhandler64) and, because every Windows
     * "process" here is a pseudo-process inside ONE Mach process, that fault
     * took the whole app down — NtTerminateProcess(0xffff7001) — killing the
     * login window after only its 5 blank full-window paints. That is the
     * "pure black window then crash" run shape. steamsysinfo only gathers the
     * hardware-survey blob (-query 1 -out-file <tmp>); Steam needs none of it
     * to reach or use the login UI, and tolerates a failed spawn exactly like
     * gldriverquery. Refusing it is strictly better than letting it fault. */
    {
        /* ml601: hardwareupdater joins the gate. Steam spawns
         *   bin\hardwareupdater\hardwareupdater.exe --check-for-updates
         * at ~t+94s. It is a PyInstaller binary: it unpacks _MEI6362 and drags in
         * python314.dll plus a COM init, which cost JIT-pool space (712MB/896MB
         * live when combase mapped) and pulled combase in and out of the address
         * space. Nothing about reaching or using Steam's UI needs a hardware
         * survey update check, and Steam tolerates a refused spawn exactly like
         * gldriverquery. (The db 7244 crash that this coincided with was OUR
         * ec-recheck probe reading combase's IAT after it unloaded — fixed
         * separately in loader.c; gating this simply removes the churn and the
         * pool pressure from the consistency baseline.) */
        /* iOS-Madeira ml628: UnityCrashHandler64.exe — same class as steamerrorreporter.
         *
         * It is Unity's OPTIONAL crash-reporting helper; the game runs fine without it.
         * In the ml627 run it started failing, called NtTerminateProcess(0xfffffc85), and
         * its dying primary thread (tid 0084) then entered FEX with a FEX host-arena
         * address (0x7d200006e0, band [0x7c,0x80)) as its supposed x64 target. FEX tried
         * to compile that ~786 MILLION times (real_compiles=785,940,296, cache_hits=184,
         * hit_rate 0%), pinning a core forever.
         *
         * ⚠️ That spin was in the HELPER, not the game: ULTRAKILL's own process (007c)
         * kept going and reached d3d11.dll + DXGI.DLL afterwards. So gating the helper
         * removes a broken, non-essential process that is protecting nothing, and leaves
         * the game untouched.
         *
         * ⛔ This is containment, NOT the fix for the host-RIP leak. A host address
         * reaching CompileBlock is a real defect (see [iOS-bogusrip] / tasks #42, #69) and
         * "EnterEC wrote it" does NOT name the origin — Core.cpp says so explicitly:
         * EnterEC storing an x64 target in State.rip is its job. The upstream producer
         * still needs finding via x9 at DispatchJump/RetToEntryThunk/ExitToX64. */
        static const char * const blocked_names[] = { "steamerrorreporter", "gldriverquery", "vulkandriverquery",
                                                      "steamsysinfo", "hardwareupdater",
                                                      "unitycrashhandler64" };
        const WCHAR *ip = params->ImagePathName.Buffer;
        int ip_len = params->ImagePathName.Length / sizeof(WCHAR);
        unsigned b;

        for (b = 0; b < sizeof(blocked_names)/sizeof(blocked_names[0]); b++)
        {
            const char *blocked = blocked_names[b];
            int bl = (int)strlen( blocked ), k, j;

            for (k = 0; k + bl <= ip_len; k++)
            {
                for (j = 0; j < bl; j++)
                {
                    WCHAR c = ip[k + j];
                    if (c >= 'A' && c <= 'Z') c += 32;
                    if (c != (WCHAR)blocked[j]) break;
                }
                if (j == bl)
                {
                    dprintf(2, "[proc-gate] REFUSING spawn of %s (%s gate)\n",
                            debugstr_us( &params->ImagePathName ), blocked );
                    return STATUS_ACCESS_DENIED;
                }
            }
        }
    }

    /* ml1520: a program parked while the game runs (ios_park_check,
     * signal_arm64_ios.c) may not start again until the session ends. */
    {
        extern int ios_park_refuse( const WCHAR *path, size_t len );
        if (ios_park_refuse( params->ImagePathName.Buffer, params->ImagePathName.Length / sizeof(WCHAR) ))
            return STATUS_ACCESS_DENIED;
    }

    /* ml526: stamp every accepted spawn on the startup timeline. This is the
     * boundary the coarse phase accounting could not see — steam.exe -> the
     * webhelper spawn was a ~16s block with no internal detail. */
    {
        extern void winios_phase( const char *name );
        char pbuf[160];
        snprintf( pbuf, sizeof(pbuf), "spawn:%s", debugstr_us( &params->ImagePathName ) );
        winios_phase( pbuf );
    }

    /* ml1620: the launcher client started by its own installer or by its
     * self-update restart carries none of the front end's arguments, so it
     * kept its browser-helper hang timeout. On a slower tablet the helper's
     * first page took longer than that and the client killed it ("Assertion
     * Failed: killing unresponsive browser", tablet log 3 (2)); the sign-in
     * window never came. Append -cef-disable-hang-timeouts to any steam.exe
     * spawn that lacks it (the front end already passes it on game launches).
     * MADEIRA_STEAM_NO_HANG_KILL=0 disables it; [proc-gate] logs it. */
    {
        static const char client[] = "\\steam.exe", flag[] = " -cef-disable-hang-timeouts";
        const WCHAR *ip = params->ImagePathName.Buffer, *cl = params->CommandLine.Buffer;
        int ip_len = params->ImagePathName.Length / sizeof(WCHAR), cl_len = params->CommandLine.Length / sizeof(WCHAR);
        int nl = sizeof(client) - 1, fl = sizeof(flag) - 1, k, j, match = 0, has = 0;
        const char *off = getenv( "MADEIRA_STEAM_NO_HANG_KILL" );

        if (!(off && off[0] == '0') && ip && cl && ip_len >= nl)
        {
            for (j = 0; j < nl; j++)
            {
                WCHAR c = ip[ip_len - nl + j];
                if (c >= 'A' && c <= 'Z') c += 32;
                if (c == '/') c = '\\';
                if (c != (WCHAR)client[j]) break;
            }
            match = (j == nl);
            for (k = 0; match && k + fl - 1 <= cl_len && !has; k++)
            {
                for (j = 1; j < fl; j++) if (cl[k + j - 1] != (WCHAR)flag[j]) break;
                if (j == fl) has = 1;
            }
        }
        if (match && !has)
        {
            WCHAR *nbuf = malloc( (cl_len + fl + 1) * sizeof(WCHAR) );
            if (nbuf)
            {
                memcpy( nbuf, cl, cl_len * sizeof(WCHAR) );
                for (j = 0; j < fl; j++) nbuf[cl_len + j] = (WCHAR)flag[j];
                nbuf[cl_len + fl] = 0;
                params->CommandLine.Buffer = nbuf;
                params->CommandLine.Length = (cl_len + fl) * sizeof(WCHAR);
                params->CommandLine.MaximumLength = params->CommandLine.Length + sizeof(WCHAR);
                dprintf( 2, "[proc-gate] ml1620 steam.exe: appended -cef-disable-hang-timeouts\n" );
            }
        }
    }

    /* task #34 single-process CEF: the 64GB VA window above the GPU carveout
     * can hold exactly ONE CEF instance's PartitionAlloc pools + one V8
     * sandbox (see virtual_ios.c slot allocator). Force steamwebhelper into
     * Chromium single-process mode so browser/gpu/renderer/utility all run
     * as threads of one pseudo-process, and refuse any --type= child it
     * still tries to spawn (e.g. crashpad-handler) — a second instance
     * would re-init both static PA copies and exhaust the slots. Chromium
     * tolerates a failed crashpad spawn (continues without crash upload). */
    {
        static const char helper[] = "steamwebhelper.exe";
        static const char typesw[] = "--type=";
        const WCHAR *ip = params->ImagePathName.Buffer;
        int ip_len = params->ImagePathName.Length / sizeof(WCHAR);
        int hl = sizeof(helper) - 1, k, j;
        int is_helper = 0;
        for (k = 0; k + hl <= ip_len && !is_helper; k++)
        {
            for (j = 0; j < hl; j++)
            {
                WCHAR c = ip[k + j];
                if (c >= 'A' && c <= 'Z') c += 32;
                if (c != (WCHAR)helper[j]) break;
            }
            if (j == hl) is_helper = 1;
        }
        if (is_helper)
        {
            const WCHAR *cl = params->CommandLine.Buffer;
            int cl_len = params->CommandLine.Length / sizeof(WCHAR);
            int tl = sizeof(typesw) - 1, has_type = 0;
            for (k = 0; k + tl <= cl_len && !has_type; k++)
            {
                for (j = 0; j < tl; j++)
                    if (cl[k + j] != (WCHAR)typesw[j]) break;
                if (j == tl) has_type = 1;
            }
            if (has_type)
            {
                dprintf(2, "[proc-gate] REFUSING steamwebhelper --type= child (single-process mode; task #34)\n");
                return STATUS_ACCESS_DENIED;
            }
            /* Append --single-process to the browser instance's command line.
             * The new buffer intentionally leaks (once per helper launch);
             * RtlDestroyProcessParameters only frees the params block itself. */
            {
                /* ml1300: Chromium rejects enable-logging=file. Use the
                 * supported empty value so its existing log-file/default file
                 * destination applies. CEF may still set its own severity. */
                /* ml287: steer proxy resolution AWAY from the in-process V8 PAC resolver.
                 *
                 * CEF's own verbose trace dies immediately after
                 *   pref_proxy_config_tracker_impl.cc(191) set chrome proxy config service
                 * and the fault is libcef.dll+0x59ef805 calling a pointer into a private
                 * PAGE_READWRITE PartitionAlloc region -- memory nothing ever requested
                 * execute on ([exec-req]: 5 requests, all succeeded, none in that band).
                 *
                 * On Windows Chromium resolves proxies either through WinHTTP or through a
                 * V8-based PAC resolver, and under --single-process that resolver runs
                 * IN-PROCESS. Starting V8 means JIT, which needs executable memory we cannot
                 * grant on iOS -- so a call into a non-executable region right after proxy
                 * setup is exactly what that would look like.
                 *
                 * --no-proxy-server disables proxy resolution outright (Steam connects
                 * directly here), and --winhttp-proxy-resolver forces the WinHTTP path
                 * instead of the V8 one if anything still resolves. Two flags, no code
                 * change: if the webhelper now survives past proxy setup, the diagnosis is
                 * confirmed and V8 is the wall; if it dies identically, V8/PAC is ruled out
                 * and the bad pointer is unrelated to proxying. */
                /* ml297 CORRECTION to the block above: the "private PAGE_READWRITE
                 * PartitionAlloc region" attribution was WRONG. ml293/294 showed those 512MB
                 * regions are FEX's OWN host reservations (all 23 [bigres] requests carry guest
                 * rsp=0/rip=0, two per thread at FEX thread init), and ml294's [vname] map proves
                 * FEXMem_ThreadState is the only NAMED region in that band. The V8/PAC theory was
                 * also refuted: the fault fired 23 times with --no-proxy-server already active.
                 * The flags stay (harmless, and they do force the WinHTTP path), but they are not
                 * the fix and the comment above should not be read as a live diagnosis.
                 *
                 * ml297 NEW TEST -- PartitionAlloc BackupRefPtr.
                 *
                 * ml296 got the deepest run yet (8,616 lines, 230 modules, ZERO 0xc0000005) and
                 * died instead with 0xc000001d = STATUS_ILLEGAL_INSTRUCTION at chrome_elf.dll
                 * +0xd7d70 -- which offline disassembly had already identified as a bare `ud2`,
                 * i.e. Chromium's IMMEDIATE_CRASH(), reached from a CHECK site that loads 0xAA
                 * poison and the string "refcount". That is PartitionAlloc's BackupRefPtr refcount
                 * integrity check. It never appears in cef_log.txt because IMMEDIATE_CRASH traps
                 * without logging, so Chromium's own log can never explain it.
                 *
                 * BRP is a security hardening feature, not a functional requirement, and it is
                 * runtime-gated by the PartitionAllocBackupRefPtr base::Feature. Disabling it
                 * removes the DETECTOR, not whatever corrupts the refcount -- so this is a
                 * diagnostic, not a fix, and if it works the underlying corruption (most likely a
                 * mis-emulated atomic RMW on PA's pool at 0x78xxxxxxxx -- note our atomic probes
                 * only ever fire on faults, so a silently-wrong-but-successful atomic would be
                 * invisible) still has to be found. Both outcomes are informative: surviving past
                 * the ud2 confirms refcount integrity is the wall, while dying identically means
                 * the ud2 is not BRP and the CHECK must be re-identified.
                 *
                 * HAZARD this must avoid: Steam ALREADY passes --disable-features=...,DcheckIsFatal,
                 * ... and Chromium's CommandLine takes the LAST occurrence of a switch. Appending a
                 * second --disable-features= would silently override Steam's whole list and make
                 * DCHECKs fatal, inventing new crashes and corrupting the experiment. So splice
                 * into the existing value instead of adding a switch. */
                /* ml427 (#70 experiment 2): --js-flags=--jitless. Segmentation-
                 * disable (ml426) took effect (cascade absent from cef_log) and
                 * the overflow recurred byte-identical ⇒ segmentation exonerated.
                 * Remaining prime suspect = in-proc renderer/Shared-JS-Context
                 * bring-up. Jitless V8 interprets without runtime codegen: if the
                 * recursion involves V8's JIT under FEX, this bypasses it; if the
                 * overflow persists, V8 codegen is exonerated too. Steam passes
                 * no --js-flags of its own (webhelper.txt cmdline verified), so
                 * appending the switch is collision-free. */
                /* ml437 (#74): --js-flags=--jitless DROPPED. It was an #70-era
                 * experiment variable (ml427/ml429 exonerated it; "drop
                 * whenever"), and ml436 showed the cost: the steamui shared-JS
                 * -context boot sat pre-GetDesiredSteamUIWindows for 15+ min on
                 * an otherwise healthy run — interpreted V8 under emulation is
                 * the prime suspect. Full V8 JIT emits runtime x86 (heavier FEX
                 * compile + tracker traffic, the normal game path) but runs JS
                 * 5-20x faster. Deploy proof = [proc-gate] cmdline-tail echo no
                 * longer showing the flag. */
                /* ml476: --js-flags=--jitless RESTORED — jitless-off is now
                 * HONESTLY CONVICTED by the criterion ml456 set ("if the JS
                 * boot stalls again on a park-free run").  Both jitless-off
                 * runs parked CrBrowserMain in NtWaitForAlertByThreadId
                 * shortly after BrowserReady and stopped writing cef_log
                 * (ml474b +104s, ml475 +4s), while the process stayed alive.
                 * ml475 was park-free in every sense we can currently
                 * measure — zero [bp-lock] timeouts (#80), zero threads
                 * frozen in the JIT pool, and the #81 SEH storm eliminated
                 * (786k faults -> 0) — so the storm was NOT the freeze cause
                 * and V8 JIT itself is the remaining differentiator: every
                 * jitless-ON run kept CEF logging for many minutes and two of
                 * them dialed.  Restoring it also restores the known-good
                 * pool tail budget (the ml455 exhaustion shape).  The #81 fix
                 * stays regardless — it is a real bug worth ~786k kernel
                 * round-trips per run. */
                /* ml509 EXPERIMENT — --num-raster-threads=1 (DIAGNOSTIC, one
                 * variable, revert after verdict). The login surface shows
                 * per-draw-op destination errors: a panel written at a
                 * constant wrong offset (~-550,-97) with its true location
                 * left black, the QR halo displaced independently of the QR
                 * it surrounds, duplicated tile content. Chromium plainly is
                 * NOT COMPUTING what it computes on real Windows, and the
                 * prime suspect class is x86-TSO memory ordering under FEX:
                 * cc's raster->compositor handoff assumes TSO, this port's
                 * FEX history is a string of atomic/ordering bugs (#37 CASPAL,
                 * #49 RX-alias atomics, #71 misaligned CS), and a stale read
                 * of a layer origin produces exactly a coherent constant
                 * offset. Single-threaded raster removes the cross-thread
                 * handoff: corruption gone => concurrency/ordering class
                 * confirmed, hunt moves to FEX TSO; corruption unchanged =>
                 * deterministic miscomputation, --disable-partial-raster is
                 * the next single-variable test. Steam passes no
                 * --num-raster-threads of its own; append is collision-free.
                 * Deploy proof = the [proc-gate] cmdline-tail echo below. */
                /* ml510 EXPERIMENT — --num-raster-threads=1 REVERTED (ml509
                 * verdict: deploy proven by the cmdline echo, corruption
                 * UNCHANGED — worker-vs-worker raster races exonerated; note
                 * the compositor thread still consumed raster output
                 * cross-thread, so ordering was only narrowed, not cleared).
                 * ml509 also closed the pixel-path question for good:
                 * [put-image] caught 11 full 700x440 paints, every one
                 * SRC{0,0,700,440}->DST{0,0,700,440} — GDI transport is sane
                 * and the corruption is already INSIDE the bitmap Chromium
                 * hands us. --disable-threaded-compositing is the strongest
                 * remaining concurrency discriminator: SingleThreadProxy
                 * collapses cc onto one thread. Corruption gone => TSO
                 * ordering convicted, fix moves into FEX. Corruption stays =>
                 * cross-thread ordering essentially out; deterministic
                 * Skia/cc miscomputation under FEX becomes the hunt. */
                /* ml511: --disable-threaded-compositing VOID and reverted —
                 * it did not test ordering, it broke frame production
                 * outright (ONE 700x440 paint all run vs 11, login window
                 * fully black, 3 presents). SingleThreadProxy's composite
                 * scheduling never fires in this environment; CEF windowed
                 * mode effectively requires threaded compositing. No verdict.
                 * ml511 EXPERIMENT = --disable-partial-raster: tiles are
                 * always fully re-rastered instead of reusing previous
                 * content + rastering the changed part. Targets the
                 * stale/duplicated-tile signature directly. Corruption gone
                 * => tile-reuse readback is where stale data enters (memory
                 * ordering on the reuse path). Unchanged => reuse exonerated,
                 * offline FEX TSO audit carries the hunt. */
                /* ml512: --disable-partial-raster REVERTED (ml511 verdict:
                 * deploy proven, corruption unchanged — tile reuse
                 * exonerated). All cheap Chromium-switch discriminators are
                 * now SPENT, each deploy-proven and inert: raster-threads=1
                 * (ml509), threaded-compositing (ml510 VOID — breaks frame
                 * production), partial-raster (ml511). The hunt moved into
                 * FEX: ml512 flips VectorTSOEnabled + MemcpySetTSOEnabled
                 * defaults in the fork (unordered vector/memcpy accesses are
                 * the audited accuracy gap; x86 orders them, FEX did not). */
                /* ml526 (#82 RETEST): jitless is now A/B-able at runtime.
                 *
                 * ml476 restored --jitless because BOTH jitless-off runs parked
                 * CrBrowserMain in NtWaitForAlertByThreadId shortly after
                 * BrowserReady (ml474b +104s, ml475 +4s) and stopped writing
                 * cef_log. ⚠️ Every one of those runs had StikDebug attached and
                 * spinning, which we now know made each trap a round-trip to a
                 * starved debugger — the same overhead that made webhelper
                 * bring-up 89s instead of 9s (b439be6). V8's JIT emits runtime
                 * x86, i.e. MORE trap/compile traffic than anything else in the
                 * process, so it is exactly the workload that overhead punished
                 * hardest. The #82 verdict may not survive its removal.
                 *
                 * Interpreted V8 costs 5-20x on all of Steam's UI JavaScript, so
                 * this is the largest single startup lever we have.
                 * MADEIRA_JITLESS=0 turns it off; default stays ON (unchanged). */
                const char *jl = getenv( "MADEIRA_JITLESS" );
                const char *lf = getenv( "MADEIRA_CEF_LOGGING_FIX" );
                /* ml1520: VERBOSE browser logging only with diagnostics on.
                 * --v=1 at verbose severity had the helper formatting and
                 * writing every VLOG line for the whole session, game running
                 * or not; the quiet build keeps warnings and errors, which is
                 * all the [guest-log] mirror reads. MADEIRA_CEF_QUIET_LOG=0
                 * restores verbose always. */
                const char *ql = getenv( "MADEIRA_CEF_QUIET_LOG" );
                extern int madeira_diag_on( void );
                int verbose = (ql && ql[0] == '0') || madeira_diag_on();
                int jitless_on = !(jl && jl[0] == '0');
                int logging_fix = !(lf && lf[0] == '0');
                char sp[256];
                snprintf( sp, sizeof(sp), " --single-process --enable-logging%s%s"
                          " --no-proxy-server --winhttp-proxy-resolver%s",
                          logging_fix ? "" : "=file", verbose ? " --v=1 --log-severity=verbose" : " --log-severity=warning",
                          jitless_on ? " --js-flags=--jitless" : "" );
                dprintf(2, "[cef-logging] ml1300 valid-destination=%d jitless=%d verbose=%d (ml1520)\n",
                        logging_fix, jitless_on, verbose);
                static const char dfs[] = "--disable-features=";
                /* ml426 (#70): + segmentation-platform features. Four CreateBrowser
                 * runs died C00000FD in the CreateResponse→BrowserReady gap, and
                 * cef_log ends mid-segmentation-cascade (segment_result_provider
                 * fail-spiral: no ML models/signals in our env) at the fault
                 * instant every time. The bat-level -cef-disable-features attempt
                 * was IGNORED (Steam only translates known -cef- flags; webhelper
                 * cmdline showed no trace) — this splice is the layer that works.
                 * Feature strings verified present in libcef. One variable per
                 * run: --js-flags=--jitless held in reserve if this fails. */
                static const char brp[] = ",PartitionAllocBackupRefPtr,SegmentationPlatform"
                                          ",OptimizationTargetPrediction,OptimizationHints";
                int sl = (int)strlen( sp );
                int dfl = sizeof(dfs) - 1, bl = sizeof(brp) - 1;
                int df_end = -1;
                {
                    int p, k;
                    for (p = 0; p + dfl <= (int)cl_len; p++)
                    {
                        for (k = 0; k < dfl; k++) if (cl[p + k] != (WCHAR)dfs[k]) break;
                        if (k == dfl)
                        {
                            df_end = p + dfl;
                            while (df_end < (int)cl_len && cl[df_end] != ' ' && cl[df_end] != '"') df_end++;
                            break;
                        }
                    }
                }
                if (df_end < 0) bl = 0;   /* no existing list -> splice nothing, report it */
                WCHAR *nbuf = malloc( (cl_len + bl + sl + 1) * sizeof(WCHAR) );
                if (nbuf)
                {
                    int o = 0;
                    if (bl)
                    {
                        memcpy( nbuf, cl, df_end * sizeof(WCHAR) );
                        o = df_end;
                        for (j = 0; j < bl; j++) nbuf[o++] = (WCHAR)brp[j];
                        memcpy( nbuf + o, cl + df_end, (cl_len - df_end) * sizeof(WCHAR) );
                        o += (int)cl_len - df_end;
                    }
                    else
                    {
                        memcpy( nbuf, cl, cl_len * sizeof(WCHAR) );
                        o = (int)cl_len;
                    }
                    for (j = 0; j < sl; j++) nbuf[o++] = (WCHAR)sp[j];
                    nbuf[o] = 0;
                    params->CommandLine.Buffer = nbuf;
                    params->CommandLine.Length = o * sizeof(WCHAR);
                    params->CommandLine.MaximumLength = params->CommandLine.Length + sizeof(WCHAR);
                    dprintf(2, "[proc-gate] steamwebhelper: injected --single-process + CEF verbosity"
                               " + no-proxy + jitless (switch experiments concluded ml509-ml511);"
                               " BRP+segmentation-disable %s (ml426)\n",
                            bl ? "SPLICED into Steam's existing --disable-features list"
                               : "NOT applied (no --disable-features found -- refusing to add a "
                                 "second one, it would override Steam's list)");
                    /* ml428: ECHO the constructed tail. Two verification channels
                     * failed silently: clang compiles sp[]/brp[] into immediate
                     * stores (invisible to any string search of the binary, old
                     * substrings included), and webhelper.txt truncates the
                     * logged command line right where our appends land. The
                     * jitless experiment's first run was VOIDED by that gap —
                     * every injected-arg experiment from now on is proven by
                     * this line, not by binary greps or Valve's log. */
                    {
                        char tail[136];
                        int tstart = o > 128 ? o - 128 : 0, ti;
                        for (ti = 0; ti + tstart < o && ti < 135; ti++)
                            tail[ti] = (char)nbuf[tstart + ti];
                        tail[ti] = 0;
                        dprintf(2, "[proc-gate] cmdline-tail(ml428): ...%s\n", tail);
                    }
                }
            }
        }
    }
#endif

    unixdir = get_unix_curdir( params );

    InitializeObjectAttributes( &attr, &path, OBJ_CASE_INSENSITIVE, 0, 0 );
    if ((status = get_pe_file_info( &attr, &nt_name, &unix_name, &file_handle, &pe_info )))
    {
        if (status == STATUS_INVALID_IMAGE_NOT_MZ && !fork_and_exec( &attr, unix_name, unixdir, params ))
        {
            *process_handle_ptr = *thread_handle_ptr = 0;
            memset( info, 0, sizeof(*info) );
            free( unix_name );
            free( nt_name.Buffer );
            return STATUS_SUCCESS;
        }
        goto done;
    }
    if (!machine)
    {
        /* Owner-aware (X3): the SPAWNER's identity decides hybrid-image
         * machine promotion — an x64 child spawning from an aarch64
         * session must not consult the session's main exe. */
        extern int ios_is_arm64ec_cur(void);
        extern const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void);
        machine = pe_info.machine;
        if (ios_is_arm64ec_cur() && pe_info.is_hybrid && machine == IMAGE_FILE_MACHINE_ARM64)
            machine = ios_cur_image_info()->Machine;
    }
#ifdef WINE_IOS
    /* One line saying which machine the child will be created with and which
     * PE farm its system DLLs will come from.  A 32-bit child routed to the
     * 64-bit farm (or the other way round) is invisible otherwise, and it is
     * the first thing to check when a spawn silently produces no window. */
    {
        extern const char *ios_pe_dir_for_machine( WORD machine );
        ERR( "NtCreateUserProcess: child machine=%04x (image machine=%04x hybrid=%d) pe_dir=%s\n",
             machine, pe_info.machine, (int)pe_info.is_hybrid,
             ios_pe_dir_for_machine( machine ) );
    }
#endif
    if (!(startup_info = create_startup_info( attr.ObjectName, process_flags, params, &pe_info, &startup_info_size )))
        goto done;
    env_size = get_env_size( params, &winedebug );

    if ((status = alloc_object_attributes( process_attr, &objattr, &attr_len ))) goto done;

    if ((status = alloc_handle_list( handles_attr, &handles, &handles_size )))
    {
        free( objattr );
        goto done;
    }

    if ((status = alloc_handle_list( jobs_attr, &jobs, &jobs_size )))
    {
        free( objattr );
        free( handles );
        goto done;
    }

    /* create the socket for the new process */

    if (socketpair( PF_UNIX, SOCK_STREAM, 0, socketfd ) == -1)
    {
        status = STATUS_TOO_MANY_OPENED_FILES;
        free( objattr );
        free( handles );
        free( jobs );
        goto done;
    }
#ifdef SO_PASSCRED
    else
    {
        int enable = 1;
        setsockopt( socketfd[0], SOL_SOCKET, SO_PASSCRED, &enable, sizeof(enable) );
    }
#endif

    wine_server_send_fd( socketfd[1] );

    /* create the process on the server side */

    SERVER_START_REQ( new_process )
    {
        req->token          = wine_server_obj_handle( token );
        req->debug          = wine_server_obj_handle( debug );
        req->parent_process = wine_server_obj_handle( parent );
        req->flags          = process_flags;
        req->socket_fd      = socketfd[1];
        req->access         = process_access;
        req->machine        = machine;
        req->info_size      = startup_info_size;
        req->handles_size   = handles_size;
        req->jobs_size      = jobs_size;
        wine_server_add_data( req, objattr, attr_len );
        wine_server_add_data( req, handles, handles_size );
        wine_server_add_data( req, jobs, jobs_size );
        wine_server_add_data( req, startup_info, startup_info_size );
        wine_server_add_data( req, params->Environment, env_size );
        if (!(status = wine_server_call( req )))
        {
            process_handle = wine_server_ptr_handle( reply->handle );
            id.UniqueProcess = ULongToHandle( reply->pid );
        }
        process_info = wine_server_ptr_handle( reply->info );
    }
    SERVER_END_REQ;
    close( socketfd[1] );
    free( objattr );
    free( handles );
    free( jobs );

    if (status)
    {
        switch (status)
        {
        case STATUS_INVALID_IMAGE_WIN_64:
            ERR( "64-bit application %s not supported in 32-bit prefix\n", debugstr_us(&path) );
            break;
        case STATUS_INVALID_IMAGE_FORMAT:
            ERR( "%s not supported on this installation (machine %04x)\n",
                 debugstr_us(&path), pe_info.machine );
            break;
        }
        goto done;
    }

    if ((status = alloc_object_attributes( thread_attr, &objattr, &attr_len ))) goto done;

    SERVER_START_REQ( new_thread )
    {
        req->process    = wine_server_obj_handle( process_handle );
        req->access     = thread_access;
        req->flags      = thread_flags;
        req->request_fd = -1;
        wine_server_add_data( req, objattr, attr_len );
        if (!(status = wine_server_call( req )))
        {
            thread_handle = wine_server_ptr_handle( reply->handle );
            id.UniqueThread = ULongToHandle( reply->tid );
        }
    }
    SERVER_END_REQ;
    free( objattr );
    if (status) goto done;

    /* create the child process */

    if ((status = spawn_process( params, socketfd[0], unixdir, winedebug, &pe_info ))) goto done;

    close( socketfd[0] );
    socketfd[0] = -1;

    /* wait for the new process info to be ready */

    NtWaitForSingleObject( process_info, FALSE, NULL );
    SERVER_START_REQ( get_new_process_info )
    {
        req->info = wine_server_obj_handle( process_info );
        wine_server_call( req );
        success = reply->success;
        status = reply->exit_code;
    }
    SERVER_END_REQ;

    if (!success)
    {
        if (!status) status = STATUS_INTERNAL_ERROR;
#ifdef WINE_IOS
        /* Name the failure at the boundary the caller sees.  Without this the
         * only evidence a spawn failed was the absence of a window. */
        ERR( "NtCreateUserProcess: %s (machine %04x) did not reach init_process_done; "
             "returning %x — see the [Wine child] boot lines above for the stage\n",
             debugstr_us(&path), machine, (unsigned)status );
#endif
        goto done;
    }

    TRACE( "%s pid %04x tid %04x handles %p/%p\n", debugstr_us(&path),
           HandleToULong(id.UniqueProcess), HandleToULong(id.UniqueThread),
           process_handle, thread_handle );

    /* update output attributes */

    for (i = 0; i < attr_count; i++)
    {
        switch (ps_attr->Attributes[i].Attribute)
        {
        case PS_ATTRIBUTE_CLIENT_ID:
        {
            SIZE_T size = min( ps_attr->Attributes[i].Size, sizeof(id) );
            memcpy( ps_attr->Attributes[i].ValuePtr, &id, size );
            if (ps_attr->Attributes[i].ReturnLength) *ps_attr->Attributes[i].ReturnLength = size;
            break;
        }
        case PS_ATTRIBUTE_IMAGE_INFO:
        {
            SECTION_IMAGE_INFORMATION info;
            SIZE_T size = min( ps_attr->Attributes[i].Size, sizeof(info) );
            virtual_fill_image_information( &pe_info, &info );
            memcpy( ps_attr->Attributes[i].ValuePtr, &info, size );
            if (ps_attr->Attributes[i].ReturnLength) *ps_attr->Attributes[i].ReturnLength = size;
            break;
        }
        case PS_ATTRIBUTE_TEB_ADDRESS:
        default:
            if (!(ps_attr->Attributes[i].Attribute & PS_ATTRIBUTE_INPUT))
                FIXME( "unhandled output attribute %lx\n", ps_attr->Attributes[i].Attribute );
            break;
        }
    }
    *process_handle_ptr = process_handle;
    *thread_handle_ptr = thread_handle;
    process_handle = thread_handle = 0;
    status = STATUS_SUCCESS;

done:
    if (file_handle) NtClose( file_handle );
    if (process_info) NtClose( process_info );
    if (process_handle) NtClose( process_handle );
    if (thread_handle) NtClose( thread_handle );
    if (socketfd[0] != -1) close( socketfd[0] );
    if (unixdir != -1) close( unixdir );
    free( startup_info );
    free( winedebug );
    free( unix_name );
    free( nt_name.Buffer );
    return status;
}


#ifdef WINE_IOS
/******************************************************************************
 * iOS-Madeira ml661: REAL BOUNDED x64 UNWIND (.pdata / UNWIND_INFO)
 *
 * WHY THIS REPLACES THE TWO THINGS WE HAD.
 *
 * 1. ml660's stack scan is a CALL-validated *heuristic*. It walks raw qwords and
 *    keeps the ones with a CALL in front. That turns address soup into something
 *    readable, but it cannot separate a live frame from a dead one, so it can
 *    never name "the caller".
 *
 * 2. FEX's callret buffer is NOT an unwind stack. It is a return-address
 *    PREDICTOR, and its "used=N entries" is occupancy/history, not N live
 *    frames. Proof from the Book of the Dead ml660 run: its top entry was
 *    UnityPlayer+0x1162463 — the return address of the `call
 *    IsProcessorFeaturePresent` that had ALREADY COMPLETED two instructions
 *    before the fatal `int 0x29`. Guest calls and returns are not guaranteed to
 *    balance there. Anything read out of it is a lead, never a frame.
 *
 * So: walk the real x64 unwind metadata instead. Diagnostic only — this never
 * changes control flow, it only prints.
 *
 * BOUNDS (every one of these exists because an unwinder that runs away inside a
 * dying process turns a diagnosable crash into a hang or a second fault):
 *   - at most IOS_UNW_MAX frames
 *   - RSP must strictly INCREASE every frame (x64 stacks grow down)
 *   - RSP must stay inside the window we started in
 *   - every read goes through mach_vm_read_overwrite, so unmapped metadata ends
 *     the walk instead of faulting us
 *   - a repeated PC or a repeated RSP ends the walk
 *
 * ⚠️ The stack window is derived from the entry RSP plus a fixed span, not from
 * the guest TEB — a pseudo-process does not give us a trustworthy stack base
 * here. It bounds the walk; it is not a claim about the real stack extent.
 */
#define IOS_UNW_MAX 32
#define IOS_UNW_STACK_SPAN (8ULL * 1024 * 1024)

static int ios_unw_read( uint64_t addr, void *buf, unsigned int len )
{
    mach_vm_size_t got = 0;
    if (!addr || addr < 0x10000ULL || addr >= 0x800000000000ULL) return 0;
    if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)addr,
                                len, (mach_vm_address_t)buf, &got ) != KERN_SUCCESS)
        return 0;
    return got == len;
}

static int ios_unw_rd32( uint64_t a, unsigned int *v ) { return ios_unw_read( a, v, 4 ); }
static int ios_unw_rd64( uint64_t a, uint64_t *v )     { return ios_unw_read( a, v, 8 ); }

/* Locate the RUNTIME_FUNCTION covering `rva` in module `base`. Returns 1 and
 * fills *rf (3 dwords) on success; 0 means "no entry" == leaf function. */
static int ios_unw_find_rf( uint64_t base, unsigned int rva, unsigned int rf[3] )
{
    unsigned int e_lfanew = 0, pdata_rva = 0, pdata_size = 0;
    unsigned short magic = 0;
    int lo, hi;

    if (!ios_unw_rd32( base + 0x3c, &e_lfanew ) || e_lfanew < 0x40 || e_lfanew > 0x1000) return 0;
    if (!ios_unw_read( base + e_lfanew + 0x18, &magic, 2 ) || magic != 0x20b) return 0; /* PE32+ only */
    /* data directory 3 = IMAGE_DIRECTORY_ENTRY_EXCEPTION; dir[0] sits at +0x88 */
    if (!ios_unw_rd32( base + e_lfanew + 0x88 + 3 * 8,     &pdata_rva  )) return 0;
    if (!ios_unw_rd32( base + e_lfanew + 0x88 + 3 * 8 + 4, &pdata_size )) return 0;
    if (!pdata_rva || pdata_size < 12) return 0;

    lo = 0; hi = (int)(pdata_size / 12) - 1;
    while (lo <= hi)
    {
        int mid = lo + (hi - lo) / 2;
        unsigned int e[3];
        if (!ios_unw_read( base + pdata_rva + (unsigned int)mid * 12, e, 12 )) return 0;
        if (rva < e[0])      hi = mid - 1;
        else if (rva >= e[1]) lo = mid + 1;
        else { rf[0] = e[0]; rf[1] = e[1]; rf[2] = e[2]; return 1; }
    }
    return 0;
}

/* Undo one frame. On entry *rsp/regs describe the frame at `pc`; on success they
 * describe the caller and *ret_pc is its PC. Returns 0 if the frame cannot be
 * decoded (caller should stop). */
static int ios_unw_step( uint64_t base, uint64_t pc, uint64_t *rsp, uint64_t regs[16], uint64_t *ret_pc,
                         uint64_t *fn_start, uint64_t *fn_end )
{
    unsigned int rf[3];
    unsigned int rva = (unsigned int)(pc - base);
    unsigned int off_in_func;
    uint64_t frame_base;
    int chain_guard = 0;

    if (fn_start) *fn_start = 0;
    if (fn_end)   *fn_end   = 0;
    if (!ios_unw_find_rf( base, rva, rf ))
    {
        /* Leaf: nothing pushed, return address sits at [rsp]. */
        if (!ios_unw_rd64( *rsp, ret_pc )) return 0;
        *rsp += 8;
        return 1;
    }

    off_in_func = rva - rf[0];
    if (fn_start) *fn_start = base + rf[0];
    if (fn_end)   *fn_end   = base + rf[1];
again:
    {
        unsigned char ui[4];
        unsigned char codes[2 * 256];
        unsigned short u16 = 0;
        unsigned int u32 = 0;
        int n, i;

        if (!ios_unw_read( base + rf[2], ui, 4 )) return 0;
        if ((ui[0] & 0x7) != 1) return 0;                 /* version must be 1 */
        n = ui[2];                                         /* CountOfCodes */
        if (n > 256) return 0;
        if (n && !ios_unw_read( base + rf[2] + 4, codes, (unsigned int)n * 2 )) return 0;

        /* Frame base: with a frame register the prologue has already established
         * it, so it is authoritative; without one, RSP past the prologue IS it. */
        if (ui[3] & 0xf) frame_base = regs[ui[3] & 0xf] - (uint64_t)((ui[3] >> 4) & 0xf) * 16;
        else             frame_base = *rsp;

        for (i = 0; i < n; )
        {
            unsigned char coff = codes[i * 2];
            unsigned char op   = codes[i * 2 + 1] & 0xf;
            unsigned char info = (codes[i * 2 + 1] >> 4) & 0xf;
            int adv = 1;

            /* Codes are sorted by descending prologue offset. Anything the CPU
             * has not executed yet must not be undone. */
            if (op == 1) adv = (info == 0) ? 2 : 3;
            else if (op == 4 || op == 8) adv = 2;
            else if (op == 5 || op == 9) adv = 3;

            /* An operand slot we never read is a truncated/garbage UNWIND_INFO.
             * Stop rather than read past the codes we actually fetched. */
            if (i + adv > n) return 0;

            /* Codes are sorted by descending prologue offset. Anything the CPU
             * has not executed yet must not be undone. */
            if (coff > off_in_func) { i += adv; continue; }

            memcpy( &u16, &codes[(i + 1) * 2], 2 );
            if (adv >= 3) memcpy( &u32, &codes[(i + 1) * 2], 4 );

            switch (op)
            {
            case 0: /* UWOP_PUSH_NONVOL */
                if (!ios_unw_rd64( *rsp, &regs[info] )) return 0;
                *rsp += 8;
                break;
            case 1: /* UWOP_ALLOC_LARGE */
                if (info == 0) *rsp += (uint64_t)u16 * 8;
                else           *rsp += (uint64_t)u32;
                break;
            case 2: /* UWOP_ALLOC_SMALL */
                *rsp += (uint64_t)info * 8 + 8;
                break;
            case 3: /* UWOP_SET_FPREG */
                *rsp = frame_base;
                break;
            case 4: /* UWOP_SAVE_NONVOL */
                ios_unw_rd64( frame_base + (uint64_t)u16 * 8, &regs[info] );
                break;
            case 5: /* UWOP_SAVE_NONVOL_FAR */
                ios_unw_rd64( frame_base + (uint64_t)u32, &regs[info] );
                break;
            case 8: case 9: break;                         /* XMM saves: no RSP effect */
            case 10:                                       /* UWOP_PUSH_MACHFRAME  */
                if (info) *rsp += 8;
                if (!ios_unw_rd64( *rsp, ret_pc )) return 0;
                if (!ios_unw_rd64( *rsp + 24, rsp )) return 0;
                return 1;
            default: break;                                /* 6/7 carry no RSP effect here */
            }
            i += adv;
        }

        /* UNW_FLAG_CHAININFO: the real unwind data continues in a parent entry. */
        if ((ui[0] >> 3) & 0x4)
        {
            unsigned int pad = (unsigned int)((n + 1) & ~1);
            unsigned int par[3];
            if (++chain_guard > 8) return 0;
            if (!ios_unw_read( base + rf[2] + 4 + pad * 2, par, 12 )) return 0;
            rf[0] = par[0]; rf[1] = par[1]; rf[2] = par[2];
            if (rva < rf[0] || rva >= rf[1]) off_in_func = 0xffffffffu; /* apply all parent codes */
            goto again;
        }
    }

    if (!ios_unw_rd64( *rsp, ret_pc )) return 0;
    *rsp += 8;
    return 1;
}

/* iOS-Madeira ml663: [runtime-info] — the MSVCRT inherited-fd blob.
 *
 * Layout (x64):  DWORD count; BYTE flags[count]; HANDLE handles[count];
 * UCRT's lowio init consumes this BEFORE it consults GetStdHandle. If it finds
 * entries here it stores their handles into __pioinfo[fd].osfhnd, and the
 * std-handle loop then takes its "already inherited" branch, which ORs FTEXT
 * and NEVER sets FOPEN. A stream whose fd lacks FOPEN is invalidated to
 * _file = -1 at stdio init -- which is exactly the state Book of the Dead dies
 * on. So a malformed blob here reproduces the failure precisely.
 *
 * Logged at BOTH ends of the handoff so a good-parent/bad-child result
 * separates "the producer is wrong" from "our serialisation is wrong". */
void ios_dump_runtime_info( const char *when, const void *buf, unsigned int len )
{
    const unsigned char *b = buf;
    unsigned int count = 0, need, hash = 2166136261u, i, n;

    if (!b || !len)
    {
        dprintf( 2, "[runtime-info] ml663 %s EMPTY (len=%u) -> UCRT takes the GetStdHandle path\n",
                 when, len );
        return;
    }
    n = len > 4096 ? 4096 : len;
    for (i = 0; i < n; i++) { hash ^= b[i]; hash *= 16777619u; }
    if (len >= 4) memcpy( &count, b, 4 );
    need = 4 + count + count * 8;
    dprintf( 2, "[runtime-info] ml663 %s len=%u count=%u needs=%u %s hash=0x%08x\n",
             when, len, count, need,
             (need <= len) ? "OK" : "*** TOO SHORT FOR ITS OWN CLAIM ***", hash );
    if (count > 1024 || need > len) return;
    for (i = 0; i < 3 && i < count; i++)
    {
        unsigned char fl = b[4 + i];
        uint64_t h = 0;
        memcpy( &h, b + 4 + count + i * 8, 8 );
        dprintf( 2, "[runtime-info] ml663 %s   fd%u flags=0x%02x FOPEN=%d handle=%llx\n",
                 when, i, fl, !!(fl & 0x01), (unsigned long long)h );
    }
}

/* iOS-Madeira ml662: [std-handles] — the thing we have NEVER logged.
 *
 * Book of the Dead dies inside UCRT `_isatty(fd)` on a descriptor that is
 * neither valid nor -2. `_isatty` TOLERATES -2 (the documented "no handle"
 * sentinel) and returns quietly; it only fast-fails on fd<0 (other than -2) or
 * fd >= _nhandle. So the guest CRT is holding a stream fd we gave it no way to
 * form correctly — and we have no visibility at all into what standard handles
 * a pseudo-process actually receives. Every process gets this line now.
 *
 * Deliberately NOT a fix: converting a bad fd to -2 would satisfy the CRT
 * invariant while leaving initialisation broken and hiding the real defect. */
void ios_dump_std_handles_ex( const char *when, void *peb, HANDLE hin, HANDLE hout,
                              HANDLE herr, HANDLE console )
{
    static const struct { DWORD access; const char *nm; } S[] = {
        { FILE_READ_DATA,  "stdin " }, { FILE_WRITE_DATA, "stdout" },
        { FILE_WRITE_DATA, "stderr" } };
    int i;

    dprintf( 2, "[std-handles] ml662 %s peb=%p console=%p\n", when, peb, (void *)console );
    for (i = 0; i < 3; i++)
    {
        HANDLE h = (i == 0) ? hin : (i == 1) ? hout : herr;
        int fd = -1;
        NTSTATUS st = STATUS_INVALID_HANDLE;

        if (h) st = wine_server_handle_to_fd( h, S[i].access, &fd, NULL );
        dprintf( 2, "[std-handles] ml662 %s   %s handle=%p%s%s -> %s fd=%d\n",
                 when, S[i].nm, (void *)h,
                 h ? "" : " (NULL => CRT should store -2, which _isatty tolerates)",
                 (h && ((UINT_PTR)h & 1)) ? " CONSOLE-marked" : "",
                 st ? "FAILED" : "ok", fd );
        if (!st && fd != -1) close( fd );
    }
}

void ios_dump_std_handles( const char *when )
{
    PEB *peb = NtCurrentTeb() ? NtCurrentTeb()->Peb : NULL;
    RTL_USER_PROCESS_PARAMETERS *pp = peb ? peb->ProcessParameters : NULL;
    if (!pp) { dprintf( 2, "[std-handles] ml662 %s peb=%p NO ProcessParameters\n", when, (void *)peb ); return; }
    ios_dump_std_handles_ex( when, peb, pp->hStdInput, pp->hStdOutput, pp->hStdError, pp->ConsoleHandle );
}

/* ml662: dump a small window at a recovered pointer. Bounded + mach-read, so a
 * garbage register costs a line of output, never a fault. */
static void ios_unw_peek( const char *tag, const char *what, uint64_t addr )
{
    unsigned char b[32];
    if (!ios_unw_read( addr, b, sizeof(b) )) return;
    dprintf( 2, "[unwind] %s ml662   %s=%llx: "
             "%02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x "
             "%02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x\n",
             tag, what, (unsigned long long)addr,
             b[0],b[1],b[2],b[3],    b[4],b[5],b[6],b[7],
             b[8],b[9],b[10],b[11],  b[12],b[13],b[14],b[15],
             b[16],b[17],b[18],b[19],b[20],b[21],b[22],b[23],
             b[24],b[25],b[26],b[27],b[28],b[29],b[30],b[31] );
}

/* ml662: resolve the RIP-relative GLOBALS a small function reads.
 *
 * Why this is general and not a per-app hack: `cmp/mov r32, [rip+disp32]` is a
 * fixed 6-byte encoding (opcode, modrm with mod=00 rm=101, disp32), so the
 * target resolves exactly with no length decoder. Any bounds/limit global a
 * validating CRT routine compares against shows up this way. In the Book of the
 * Dead chain this is what exposes UCRT's `_nhandle` — an ordinary fd=1 still
 * fast-fails inside _isatty if `_nhandle` is wrongly 0, and nothing else we
 * print can tell those two worlds apart. */
static void ios_unw_globals( const char *tag, uint64_t fn_start, uint64_t fn_end, int *budget )
{
    unsigned char code[192];
    unsigned int len = (unsigned int)(fn_end - fn_start);
    unsigned int i;
    int per_frame = 0;

    if (fn_end <= fn_start) return;
    if (len > sizeof(code)) len = sizeof(code);
    if (len < 6 || !ios_unw_read( fn_start, code, len )) return;

    for (i = 0; i + 7 <= len && per_frame < 4 && *budget > 0; i++)
    {
        unsigned char op = code[i], modrm = code[i + 1];
        int disp, ilen;
        uint64_t tgt;
        unsigned int v = 0;
        uint64_t pv = 0;

        if (op == 0x48 && code[i + 1] == 0x8D)          /* ml663: REX.W LEA r64,[rip+d32] */
        {
            modrm = code[i + 2];
            if ((modrm & 0xC7) != 0x05) continue;
            memcpy( &disp, &code[i + 3], 4 );
            ilen = 7;
        }
        else if (op == 0x39 || op == 0x3B || op == 0x8B || op == 0x89)
        {
            if ((modrm & 0xC7) != 0x05) continue;       /* mod=00 rm=101 => RIP-relative */
            memcpy( &disp, &code[i + 2], 4 );
            ilen = 6;
        }
        else continue;

        tgt = fn_start + i + ilen + (int64_t)disp;
        if (!ios_unw_read( tgt, &v, 4 )) continue;
        dprintf( 2, "[unwind] %s ml662   global @+0x%02x -> %llx = 0x%08x (%d)\n",
                 tag, i, (unsigned long long)tgt, v, (int)v );
        per_frame++; (*budget)--;

        /* ml663: follow ONE pointer level. A validating routine's bounds live in
         * a scalar; its TABLE lives behind a pointer. UCRT's __pioinfo is the
         * case that matters here — _isatty indexes it to read the FOPEN bit,
         * and that bit is the difference between a usable stream and the -1 we
         * are dying on. */
        if (ios_unw_rd64( tgt, &pv ) && pv >= 0x10000ULL && pv < 0x800000000000ULL && !(pv & 7))
        {
            int e;
            unsigned char blk[0xC0];
            if (!ios_unw_read( pv, blk, sizeof(blk) )) continue;
            /* ml664: print the RAW bytes too. Last run this block was printed
             * ONLY through the lowio interpretation, so when the followed
             * pointer was __piob[1] (-> the stdout FILE) the real contents were
             * discarded and shown as nonsense lowio fields. Raw first, then the
             * interpretation: 0xC0 bytes covers two 0x58-stride UCRT streams,
             * i.e. _iob[1] AND _iob[2] in one dump. */
            {
                int rw;
                for (rw = 0; rw < 0xC0; rw += 32)
                    dprintf( 2, "[unwind] %s ml664     raw +0x%02x: "
                             "%02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x "
                             "%02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x\n",
                             tag, rw,
                             blk[rw+0],blk[rw+1],blk[rw+2],blk[rw+3],     blk[rw+4],blk[rw+5],blk[rw+6],blk[rw+7],
                             blk[rw+8],blk[rw+9],blk[rw+10],blk[rw+11],   blk[rw+12],blk[rw+13],blk[rw+14],blk[rw+15],
                             blk[rw+16],blk[rw+17],blk[rw+18],blk[rw+19], blk[rw+20],blk[rw+21],blk[rw+22],blk[rw+23],
                             blk[rw+24],blk[rw+25],blk[rw+26],blk[rw+27], blk[rw+28],blk[rw+29],blk[rw+30],blk[rw+31] );
                /* If this pointer is a UCRT __piob entry, these are streams. */
                for (rw = 0; rw + 0x58 <= 0xC0; rw += 0x58)
                {
                    int fl, fi;
                    memcpy( &fl, &blk[rw + 0x14], 4 );
                    memcpy( &fi, &blk[rw + 0x18], 4 );
                    dprintf( 2, "[unwind] %s ml664     if-stream @+0x%02x: _flags=0x%08x _file=%d%s\n",
                             tag, rw, fl, fi,
                             fi == -2 ? "  (-2 = UCRT 'no handle', _isatty TOLERATES)" :
                             fi == -1 ? "  (-1 = CLOSED/invalid, _isatty FAST-FAILS)" : "" );
                }
            }
            /* Interpreted with the UCRT lowio layout: 0x40 stride, osfhnd@+0x28,
             * osfile@+0x38. That layout is an MSVC ABI constant shared by every
             * statically-linked-UCRT binary, not a fact about this game. If the
             * pointer is not __pioinfo the numbers are meaningless -- hence the
             * explicit "if lowio" label. */
            for (e = 0; e < 3; e++)
            {
                uint64_t osfhnd;
                unsigned char osfile;
                memcpy( &osfhnd, &blk[e * 0x40 + 0x28], 8 );
                osfile = blk[e * 0x40 + 0x38];
                dprintf( 2, "[unwind] %s ml663     if-lowio fd%d: osfhnd=%llx osfile=0x%02x "
                         "FOPEN=%d FDEV=%d FPIPE=%d FTEXT=%d\n", tag, e,
                         (unsigned long long)osfhnd, osfile,
                         !!(osfile & 0x01), !!(osfile & 0x40), !!(osfile & 0x08), !!(osfile & 0x80) );
            }
        }
        i += ilen - 1;
    }
}

/* Print the bounded unwind. `regs` is FEX's greg file (RAX,RCX,RDX,RBX,RSP,RBP,RSI,RDI,R8..R15). */
static void ios_unwind_dump( uint64_t rip, const uint64_t *gregs, const char *tag )
{
    extern unsigned long long ios_jit_module_base_for_va( unsigned long long va, unsigned long long *size_out );
    uint64_t regs[16], rsp, pc, lo, hi, prev_pc = 0, prev_rsp = 0;
    int frame, glob_budget = 8, peek_budget = 10;
    static const struct { int idx; const char *nm; } NV[] = {
        { 3, "rbx" }, { 5, "rbp" }, { 6, "rsi" }, { 7, "rdi" },
        { 12, "r12" }, { 13, "r13" }, { 14, "r14" }, { 15, "r15" } };

    for (frame = 0; frame < 16; frame++) regs[frame] = gregs[frame];
    rsp = regs[4];
    pc  = rip;
    lo  = rsp;
    hi  = rsp + IOS_UNW_STACK_SPAN;

    dprintf( 2, "[unwind] %s ml661 begin rip=%llx rsp=%llx window=[%llx..%llx) max=%d\n",
             tag, (unsigned long long)pc, (unsigned long long)rsp,
             (unsigned long long)lo, (unsigned long long)hi, IOS_UNW_MAX );

    for (frame = 0; frame < IOS_UNW_MAX; frame++)
    {
        unsigned long long msz = 0;
        unsigned long long mbase = ios_jit_module_base_for_va( pc, &msz );
        const char *mname = "?";
        uint64_t next_pc = 0, fn_start = 0, fn_end = 0;

        if (mbase)
        {
            unsigned char hdr[2];
            unsigned int e_lf = 0, exp_rva = 0, name_rva = 0;
            static char nb[64];
            if (ios_unw_read( mbase, hdr, 2 ) && hdr[0] == 'M' && hdr[1] == 'Z')
            {
                mname = "(exe)";
                if (ios_unw_rd32( mbase + 0x3c, &e_lf ) && e_lf < 0x1000 &&
                    ios_unw_rd32( mbase + e_lf + 0x88, &exp_rva ) && exp_rva && exp_rva < msz &&
                    ios_unw_rd32( mbase + exp_rva + 0x0c, &name_rva ) && name_rva && name_rva < msz &&
                    ios_unw_read( mbase + name_rva, nb, sizeof(nb) - 1 ))
                { nb[sizeof(nb) - 1] = 0; mname = nb; }
            }
            dprintf( 2, "[unwind] %s ml661 #%02d pc=%llx rsp=%llx  %.40s+0x%llx\n",
                     tag, frame, (unsigned long long)pc, (unsigned long long)rsp,
                     mname, (unsigned long long)(pc - mbase) );
        }
        else
        {
            dprintf( 2, "[unwind] %s ml661 #%02d pc=%llx rsp=%llx  <no module — STOP>\n",
                     tag, frame, (unsigned long long)pc, (unsigned long long)rsp );
            break;
        }

        if (!ios_unw_step( mbase, pc, &rsp, regs, &next_pc, &fn_start, &fn_end ))
        { dprintf( 2, "[unwind] %s ml661 stop: frame not decodable\n", tag ); break; }

        /* ml662: the nonvolatiles the unwind just RECOVERED belong to this
         * frame's caller-visible state — that is where a validating routine's
         * subject object lives (in the Book of the Dead chain, the FILE* is in
         * rbx). Volatile registers are gone by the time we fault, so these are
         * the only object pointers we can ever name. */
        {
            int k, shown = 0;
            dprintf( 2, "[unwind] %s ml662 #%02d nv: rbx=%llx rbp=%llx rsi=%llx rdi=%llx "
                     "r12=%llx r13=%llx r14=%llx r15=%llx\n", tag, frame,
                     regs[3], regs[5], regs[6], regs[7], regs[12], regs[13], regs[14], regs[15] );
            for (k = 0; k < 8 && shown < 2 && peek_budget > 0; k++)
            {
                uint64_t v = regs[NV[k].idx];
                if (v < 0x10000ULL || v >= 0x800000000000ULL || (v & 3)) continue;
                ios_unw_peek( tag, NV[k].nm, v );
                shown++; peek_budget--;
            }
            if (fn_start) ios_unw_globals( tag, fn_start, fn_end, &glob_budget );
        }

        if (rsp <= prev_rsp && frame)
        { dprintf( 2, "[unwind] %s ml661 stop: rsp did not increase (%llx)\n", tag, (unsigned long long)rsp ); break; }
        if (rsp < lo || rsp >= hi)
        { dprintf( 2, "[unwind] %s ml661 stop: rsp %llx left the window\n", tag, (unsigned long long)rsp ); break; }
        if (!next_pc || next_pc == prev_pc)
        { dprintf( 2, "[unwind] %s ml661 stop: ret pc %llx repeats or is null\n", tag, (unsigned long long)next_pc ); break; }

        prev_pc = pc; prev_rsp = rsp;
        pc = next_pc;
        regs[4] = rsp;
    }
    dprintf( 2, "[unwind] %s ml661 end\n", tag );
}
#endif /* WINE_IOS */


/******************************************************************************
 *              NtTerminateProcess  (NTDLL.@)
 */
NTSTATUS WINAPI NtTerminateProcess( HANDLE handle, LONG exit_code )
{
    unsigned int ret;
    BOOL self;

#ifdef WINE_IOS
    {
        static int term_log_count = 0;
        /* iOS-Madeira [term-stack] (task#29): also fire on ANY nonzero exit_code
         * (capped) so Steam's deliberate ExitProcess(-104) bootstrapper bail is
         * captured — the first-3 slots are consumed by early exit-0 procs
         * (cmd/start.exe) before steam.exe ever runs. The dump below (guest RIP +
         * emulator-stack code-address scan) names which steam.exe code path bails. */
        if (term_log_count < 3 || (exit_code != 0 && term_log_count < 24)) {
            term_log_count++;
            extern volatile uint64_t g_wine_dispatcher_count;
            extern volatile uint64_t g_wine_unix_call_count;
            ERR("NtTerminateProcess(handle=%p, exit_code=0x%x) syscalls=%llu unix_calls=%llu\n",
                handle, (unsigned int)exit_code,
                (unsigned long long)g_wine_dispatcher_count,
                (unsigned long long)g_wine_unix_call_count);
            /* task #24: Thumper's settings page deliberately calls
             * ExitProcess(-1) from a fresh thread with no preceding
             * exception — the deciding code is invisible. Dump the calling
             * thread's guest x64 state: RIP, gregs, and return-address-
             * looking qwords on the guest stack (attributed offline via the
             * [jit-pool]/load-order tables). FEX state layout: rip@0x18,
             * gregs@0x20 (CoreState.h); cpuarea+0x30 = FEX state ptr (same
             * offset the [fault_rip] probe uses). dprintf not ERR — this
             * must survive err-channel muting. */
            {
                TEB *cur_teb = NtCurrentTeb();
                CHPE_V2_CPU_AREA_INFO *cpuarea = cur_teb ? cur_teb->ChpeV2CpuAreaInfo : NULL;
                void *fex_state = cpuarea ? *(void **)((char *)cpuarea + 0x30) : NULL;
                if (fex_state)
                {
                    const uint64_t *fx = (const uint64_t *)fex_state;
                    uint64_t rip = fx[0x18 / 8];
                    const uint64_t *gregs = &fx[0x20 / 8];
                    uint64_t sbase = (uint64_t)cpuarea->EmulatorStackBase;
                    uint64_t slimit = (uint64_t)cpuarea->EmulatorStackLimit;
                    uint64_t rsp = 0;
                    int gi, hits = 0;
                    dprintf(2, "[term-stack] rip=%llx stack=[%llx..%llx]\n",
                            (unsigned long long)rip, (unsigned long long)slimit,
                            (unsigned long long)sbase);
                    dprintf(2, "[term-stack] g0-7: %llx %llx %llx %llx %llx %llx %llx %llx\n",
                            gregs[0], gregs[1], gregs[2], gregs[3],
                            gregs[4], gregs[5], gregs[6], gregs[7]);
                    dprintf(2, "[term-stack] g8-15: %llx %llx %llx %llx %llx %llx %llx %llx\n",
                            gregs[8], gregs[9], gregs[10], gregs[11],
                            gregs[12], gregs[13], gregs[14], gregs[15]);

                    /* ml661: the REAL unwind runs first — it is the only thing
                     * here that produces frames rather than candidates. The
                     * ml660 CALL-validated scan below stays as corroboration
                     * (and as the fallback when .pdata is missing or the guest
                     * stack is too damaged to walk). */
                    ios_dump_std_handles( "at-terminate" );
                    ios_unwind_dump( rip, gregs, "term" );
                    /* rsp: prefer a greg inside the cpuarea's recorded range,
                     * but the live FEX stack can differ (seq-3656 run: rsp
                     * pair 0x1613ffxxx vs recorded [0x1514a0000..0x1514e0000])
                     * — fall back to any pointer-looking greg whose memory
                     * reads back. Use mach reads so a bad candidate can't
                     * fault the caller. */
                    for (gi = 0; gi < 16; gi++)
                        if (gregs[gi] >= slimit && gregs[gi] < sbase) { rsp = gregs[gi]; break; }
                    {
                        extern unsigned long long ios_jit_module_base_for_va(unsigned long long va, unsigned long long *size_out);
                        static uint64_t stack_buf[512];
                        int cand;
                        for (cand = -1; cand < 16 && hits == 0; cand++)
                        {
                            uint64_t try_sp = (cand < 0) ? rsp : gregs[cand];
                            mach_vm_size_t got_sb = 0;
                            int wi, nw;
                            if (!try_sp || (try_sp & 7) || try_sp < 0x100000000ULL ||
                                try_sp >= 0x800000000000ULL) continue;
                            if (mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)try_sp,
                                    sizeof(stack_buf), (mach_vm_address_t)stack_buf, &got_sb ) != KERN_SUCCESS ||
                                got_sb < 64) continue;
                            nw = (int)(got_sb / 8);
                            for (wi = 0; wi < nw && hits < 24; wi++)
                            {
                                uint64_t v = stack_buf[wi];
                                unsigned long long msz = 0;
                                unsigned long long mbase = ios_jit_module_base_for_va( v, &msz );
                                if (!mbase) continue;

                                /* ml660: IS THIS A RETURN ADDRESS, OR JUST A CODE-LIKE VALUE?
                                 *
                                 * The old scan printed every stack qword that landed inside a
                                 * module, which mixes live return addresses with dead frames,
                                 * spilled function pointers and vtable entries. Book of the
                                 * Dead's fast-fail produced a dozen such lines and none of them
                                 * could be trusted as the caller.
                                 *
                                 * A REAL return address always has a CALL immediately before it.
                                 * Check the bytes at v-5 and v-2..v-7 for the two x64 forms:
                                 *   E8 rel32                     (5 bytes, direct)
                                 *   FF /2  with modrm.reg == 2   (2-7 bytes, indirect)
                                 * That single test discards most of the noise. It is a VALIDATED
                                 * HEURISTIC, not an unwind — a true .pdata/UNWIND_INFO walk is
                                 * still owed — but it turns address soup into a chain worth
                                 * reading. Unvalidated entries are still shown, marked, so a
                                 * missed CALL form cannot hide the real caller. */
                                const char *kind = "  ?";
                                {
                                    unsigned char cb[8];
                                    mach_vm_size_t cg = 0;
                                    if (v >= 8 &&
                                        mach_vm_read_overwrite( mach_task_self(),
                                            (mach_vm_address_t)(v - 8), sizeof(cb),
                                            (mach_vm_address_t)cb, &cg ) == KERN_SUCCESS && cg == 8)
                                    {
                                        if (cb[3] == 0xE8) kind = "CALL";          /* v-5 */
                                        else {
                                            int k;
                                            for (k = 1; k <= 6; k++) {
                                                unsigned char op = cb[8 - k], modrm = cb[8 - k + 1];
                                                if (op == 0xFF && ((modrm >> 3) & 7) == 2) { kind = "call*"; break; }
                                            }
                                        }
                                    }
                                }
                                if (kind[0] == ' ' && hits >= 8) continue;   /* keep the log honest but bounded */
                                /* name via export directory of the map view */
                                {
                                    const unsigned char *mb = (const unsigned char *)(uintptr_t)mbase;
                                    const char *mname = "?";
                                    unsigned int e_lf, exp_rva, name_rva;
                                    if (mb[0] == 'M' && mb[1] == 'Z' &&
                                        (e_lf = *(const unsigned int *)(mb + 0x3c)) < 0x1000 &&
                                        (exp_rva = *(const unsigned int *)(mb + e_lf + 0x88)) &&
                                        exp_rva < msz &&
                                        (name_rva = *(const unsigned int *)(mb + exp_rva + 0x0c)) &&
                                        name_rva < msz)
                                        mname = (const char *)(mb + name_rva);
                                    else if (mb[0] == 'M' && mb[1] == 'Z')
                                        mname = "(exe)";
                                    dprintf(2, "[term-stack] ml660 sp+%03x: %s %llx  %.32s+0x%llx\n",
                                            wi * 8, kind, (unsigned long long)v, mname,
                                            (unsigned long long)(v - mbase));
                                }
                                hits++;
                            }
                            if (hits)
                                dprintf(2, "[term-stack] used %s=0x%llx, scanned %d qwords, %d code-like\n",
                                        cand < 0 ? "cpuarea-rsp" : "greg", (unsigned long long)try_sp, nw, hits);
                        }
                        if (!hits) dprintf(2, "[term-stack] no readable stack candidate produced hits\n");
                    }
                }
                else dprintf(2, "[term-stack] no FEX state on this thread (cpuarea=%p)\n", (void *)cpuarea);
            }
        }
    }
    /* iOS-Madeira ml659: THE 0xc0000409 -> THREAD-TERMINATE HACK IS GONE.
     *
     * From 2026-05-13 until now this converted a whole-process fast-fail into a
     * single thread death, so "the game continues". Its own comment called it a
     * brutal survival hack to be removed once the underlying FEX issue was fixed.
     * It was never removed, and it silently violates Windows fast-fail semantics
     * for EVERY guest.
     *
     * What it actually costs: Book of the Dead executes a DELIBERATE
     *     mov ecx, 5        ; FAST_FAIL_INVALID_ARG
     *     int 0x29
     * at UnityPlayer.dll+0x116246c. Wine correctly called NtTerminateProcess,
     * this hack killed only tid 007c — Unity's MAIN thread — and left ~60 job
     * workers blocked in ordinary waits forever. The app looked FROZEN while it
     * was really a zombie process. Diagnosing that cost a run, and would have
     * cost more: nothing in the log says "the process should have died here".
     *
     * ⚠️ 0xc0000409 is STATUS_STACK_BUFFER_OVERRUN by NAME ONLY. It is the
     * generic __fastfail status; the real reason is the fast-fail CODE in ecx.
     * Code 5 is FAST_FAIL_INVALID_ARG (an MSVC/CRT invalid-parameter failure),
     * NOT a stack overrun. Reading the name as "stack cookie" is what led to the
     * FEX-miscompiles-cookies theory that justified this hack.
     *
     * ⛔ NOT restricted to one title. A game-specific carve-out would be a
     * per-app hack, which this project does not do — fix the accuracy gap.
     *
     * ⚠️ RISK, STATED PLAINLY: Thumper has depended on this since May. If its
     * fast-fail is genuinely spurious (a real FEX bug with stack cookies) it may
     * now die during init. That regression is INFORMATION — it exposes the bug
     * this hack has been hiding — but it is a regression. The [term-stack] dump
     * above still fires and names the faulting module. */
    /* iOS: if THIS pseudo-process is already exiting and this is the
     * self-terminate call (the -1 pseudo-handle from RtlExitUserProcess),
     * go directly to exit_process. The server may return self=false because
     * it already processed the termination, causing an infinite loop.
     * Per-process flag: a global one poisons every other pseudo-process's
     * exit once the first dies (2026-07-05 3-deep-tree bug) — and worse,
     * would force-exit a process that merely KILLS another (handle != -1),
     * which Steam does to its helpers. */
    extern BOOL *ios_process_exiting_ptr(void);
    BOOL *exiting_flag = ios_process_exiting_ptr();
    if (*exiting_flag && handle == (HANDLE)~(ULONG_PTR)0)
    {
        ERR("NtTerminateProcess: process_exiting=1, forcing exit_process(%d)\n", (int)exit_code);
        exit_process( exit_code );
        /* noreturn */
    }
#endif
    SERVER_START_REQ( terminate_process )
    {
        req->handle    = wine_server_obj_handle( handle );
        req->exit_code = exit_code;
        ret = wine_server_call( req );
        self = reply->self;
    }
    SERVER_END_REQ;
    if (self)
    {
#ifdef WINE_IOS
        /* MADEIRA-TEMP: WOW64_DESIGN.md M1 exit-status observability. This is
         * the one chokepoint every pseudo-process's own termination reaches
         * exactly once (self == TRUE means the calling process is the one
         * being terminated), so one generic line here covers every exe --
         * not just the x86 test path -- with the image name and the decimal
         * status the guest actually asked to exit with. */
        {
            PEB *peb = NtCurrentTeb() ? NtCurrentTeb()->Peb : NULL;
            RTL_USER_PROCESS_PARAMETERS *pp = peb ? peb->ProcessParameters : NULL;
            const WCHAR *path = (pp && pp->ImagePathName.Buffer) ? pp->ImagePathName.Buffer : NULL;
            unsigned int len = path ? pp->ImagePathName.Length / sizeof(WCHAR) : 0;
            unsigned int base = 0, i, n = 0;
            char name[64];

            for (i = 0; i < len; i++) if (path[i] == '\\' || path[i] == '/') base = i + 1;
            for (i = base; i < len && n < sizeof(name) - 1; i++) name[n++] = (char)path[i];
            name[n] = 0;
            ERR( "MADEIRA-EXIT: %s status=%d\n", n ? name : "?", (int)exit_code );
            /* ml962: the [srv-stats] report is piggy-backed on the 10 s
             * deadline being crossed at the end of some server call, so a run
             * that dies before the first window -- which is every crash worth
             * diagnosing -- produced no counters at all.  This is the one
             * chokepoint each pseudo-process's own exit passes exactly once,
             * so dump the window here too: per-kind traffic, the Nt* entry
             * points, the select breakdown and the fastsync hit/miss and
             * cache-learn lines. */
            {
                extern void ios_srv_stats_report_now(void);
                ios_srv_stats_report_now();
            }
            /* Unbuffered duplicate: ERR goes through the debug channel, which a
             * muted err: channel or a dying log pump can swallow.  Everything
             * below is the teardown that used to end the log (and the app), so
             * each step names itself on fd 2 with a plain write(2). */
            extern const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void);
            dprintf( 2, "[Wine child exit] stage=madeira-exit exe=%s status=%d handle=%p "
                        "exiting_flag=%d machine=%04x window=%p teb=%p peb=%p\n",
                     n ? name : "?", (int)exit_code, handle, (int)*exiting_flag,
                     ios_cur_image_info()->Machine, (void *)ios_wow_base(),
                     NtCurrentTeb(), peb );
        }
        if (!handle)
        {
            dprintf( 2, "[Wine child exit] stage=mark-exiting (no teardown yet)\n" );
            *exiting_flag = TRUE;
        }
        else if (*exiting_flag)
        {
            dprintf( 2, "[Wine child exit] stage=exit_process\n" );
            exit_process( exit_code );
            dprintf( 2, "[Wine child exit] stage=returned-from-exit_process (UNEXPECTED)\n" );
        }
        else
        {
            /* The loader_init-failure path: ntdll called
             * NtTerminateProcess( GetCurrentProcess(), status ) with no
             * preceding NtTerminateProcess( 0, ... ), so exiting_flag is still
             * FALSE.  abort_process() used to _exit() here, which on iOS ends
             * the whole Mach task — every other pseudo-process, the UI, the log.
             * It now performs the same per-pseudo-process teardown as
             * exit_process (thread_ios.c). */
            dprintf( 2, "[Wine child exit] stage=abort_process\n" );
            abort_process( exit_code );
            dprintf( 2, "[Wine child exit] stage=returned-from-abort_process (UNEXPECTED)\n" );
        }
#else
        if (!handle) process_exiting = TRUE;
        else if (process_exiting) exit_process( exit_code );
        else abort_process( exit_code );
#endif
    }
    return ret;
}


#if defined(HAVE_MACH_MACH_H)

void fill_vm_counters( VM_COUNTERS_EX *pvmi, int unix_pid )
{
#if defined(MACH_TASK_BASIC_INFO)
    struct mach_task_basic_info info;
    mach_msg_type_number_t infoCount;

    if (unix_pid != -1) return; /* FIXME: Retrieve information for other processes. */

    infoCount = MACH_TASK_BASIC_INFO_COUNT;
    if(task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &infoCount) == KERN_SUCCESS)
    {
        pvmi->VirtualSize = info.resident_size + info.virtual_size;
        pvmi->PagefileUsage = info.virtual_size;
        pvmi->WorkingSetSize = info.resident_size;
        pvmi->PeakWorkingSetSize = info.resident_size_max;
    }
#endif
}

#elif defined(linux)

void fill_vm_counters( VM_COUNTERS_EX *pvmi, int unix_pid )
{
    FILE *f;
    char line[256], path[26];
    unsigned long value;

    if (unix_pid == -1)
        strcpy( path, "/proc/self/status" );
    else
        snprintf( path, sizeof(path), "/proc/%u/status", unix_pid);
    f = fopen( path, "r" );
    if (!f) return;

    while (fgets(line, sizeof(line), f))
    {
        if (sscanf(line, "VmPeak: %lu", &value))
            pvmi->PeakVirtualSize = (ULONG64)value * 1024;
        else if (sscanf(line, "VmSize: %lu", &value))
            pvmi->VirtualSize = (ULONG64)value * 1024;
        else if (sscanf(line, "VmHWM: %lu", &value))
            pvmi->PeakWorkingSetSize = (ULONG64)value * 1024;
        else if (sscanf(line, "VmRSS: %lu", &value))
            pvmi->WorkingSetSize = (ULONG64)value * 1024;
        else if (sscanf(line, "RssAnon: %lu", &value))
            pvmi->PagefileUsage += (ULONG64)value * 1024;
        else if (sscanf(line, "VmSwap: %lu", &value))
            pvmi->PagefileUsage += (ULONG64)value * 1024;
    }
    pvmi->PeakPagefileUsage = pvmi->PagefileUsage;

    fclose(f);
}

#elif defined(HAVE_LIBPROCSTAT)

void fill_vm_counters( VM_COUNTERS_EX *pvmi, int unix_pid )
{
    struct procstat *pstat;
    struct kinfo_proc *kip;
    unsigned int proc_count;

    pstat = procstat_open_sysctl();
    if (pstat)
    {
        kip = procstat_getprocs( pstat, KERN_PROC_PID, unix_pid == -1 ? getpid() : unix_pid, &proc_count );
        if (kip)
        {
            pvmi->VirtualSize = kip->ki_size;
            pvmi->PeakVirtualSize = kip->ki_size;
            pvmi->WorkingSetSize = kip->ki_rssize << PAGE_SHIFT;
            pvmi->PeakWorkingSetSize = kip->ki_rusage.ru_maxrss * 1024;
            procstat_freeprocs( pstat, kip );
        }
        procstat_close( pstat );
    }
}

#else

void fill_vm_counters( VM_COUNTERS_EX *pvmi, int unix_pid )
{
    /* FIXME : real data */
}

#endif

#define UNIMPLEMENTED_INFO_CLASS(c) \
    case c: \
        FIXME( "(process=%p) Unimplemented information class: " #c "\n", handle); \
        ret = STATUS_INVALID_INFO_CLASS; \
        break

/**********************************************************************
 *           NtQueryInformationProcess  (NTDLL.@)
 */
NTSTATUS WINAPI NtQueryInformationProcess( HANDLE handle, PROCESSINFOCLASS class, void *info,
                                           ULONG size, ULONG *ret_len )
{
    unsigned int ret = STATUS_SUCCESS;
    ULONG len = 0;

    TRACE( "(%p,0x%08x,%p,0x%08x,%p)\n", handle, class, info, size, ret_len );

    switch (class)
    {
    UNIMPLEMENTED_INFO_CLASS(ProcessBasePriority);
    UNIMPLEMENTED_INFO_CLASS(ProcessRaisePriority);
    UNIMPLEMENTED_INFO_CLASS(ProcessExceptionPort);
    UNIMPLEMENTED_INFO_CLASS(ProcessAccessToken);
    UNIMPLEMENTED_INFO_CLASS(ProcessLdtInformation);
    UNIMPLEMENTED_INFO_CLASS(ProcessLdtSize);
    UNIMPLEMENTED_INFO_CLASS(ProcessIoPortHandlers);
    UNIMPLEMENTED_INFO_CLASS(ProcessPooledUsageAndLimits);
    UNIMPLEMENTED_INFO_CLASS(ProcessWorkingSetWatch);
    UNIMPLEMENTED_INFO_CLASS(ProcessUserModeIOPL);
    UNIMPLEMENTED_INFO_CLASS(ProcessEnableAlignmentFaultFixup);
    UNIMPLEMENTED_INFO_CLASS(ProcessWx86Information);
    UNIMPLEMENTED_INFO_CLASS(ProcessDeviceMap);
    UNIMPLEMENTED_INFO_CLASS(ProcessForegroundInformation);
    UNIMPLEMENTED_INFO_CLASS(ProcessLUIDDeviceMapsEnabled);
    UNIMPLEMENTED_INFO_CLASS(ProcessBreakOnTermination);
    UNIMPLEMENTED_INFO_CLASS(ProcessHandleTracing);

    case ProcessBasicInformation:
        {
            PROCESS_BASIC_INFORMATION pbi;
            const ULONG_PTR affinity_mask = get_system_affinity_mask();

            if (size >= sizeof(PROCESS_BASIC_INFORMATION))
            {
                if (!info) ret = STATUS_ACCESS_VIOLATION;
                else
                {
                    SERVER_START_REQ(get_process_info)
                    {
                        req->handle = wine_server_obj_handle( handle );
                        if ((ret = wine_server_call( req )) == STATUS_SUCCESS)
                        {
                            pbi.ExitStatus = reply->exit_code;
                            pbi.PebBaseAddress = wine_server_get_ptr( reply->peb );
                            pbi.AffinityMask = reply->affinity & affinity_mask;
                            pbi.BasePriority = reply->base_priority;
                            pbi.UniqueProcessId = reply->pid;
                            pbi.InheritedFromUniqueProcessId = reply->ppid;
                            if (is_old_wow64())
                            {
                                if (!is_machine_64bit( reply->machine ))
                                    pbi.PebBaseAddress = (PEB *)((char *)pbi.PebBaseAddress + 0x1000);
                                else
                                    pbi.PebBaseAddress = NULL;
                            }
                        }
                    }
                    SERVER_END_REQ;

                    memcpy( info, &pbi, sizeof(PROCESS_BASIC_INFORMATION) );
                    len = sizeof(PROCESS_BASIC_INFORMATION);
                }
                if (size > sizeof(PROCESS_BASIC_INFORMATION)) ret = STATUS_INFO_LENGTH_MISMATCH;
            }
            else
            {
                len = sizeof(PROCESS_BASIC_INFORMATION);
                ret = STATUS_INFO_LENGTH_MISMATCH;
            }
        }
        break;

    case ProcessIoCounters:
        {
            IO_COUNTERS pii;

            if (size >= sizeof(IO_COUNTERS))
            {
                if (!info) ret = STATUS_ACCESS_VIOLATION;
                else if (!handle) ret = STATUS_INVALID_HANDLE;
                else
                {
                    /* FIXME : real data */
                    memset(&pii, 0 , sizeof(IO_COUNTERS));
                    memcpy(info, &pii, sizeof(IO_COUNTERS));
                    len = sizeof(IO_COUNTERS);
                }
                if (size > sizeof(IO_COUNTERS)) ret = STATUS_INFO_LENGTH_MISMATCH;
            }
            else
            {
                len = sizeof(IO_COUNTERS);
                ret = STATUS_INFO_LENGTH_MISMATCH;
            }
        }
        break;

    case ProcessVmCounters:
        {
            VM_COUNTERS_EX pvmi;

            /* older Windows versions don't have the PrivateUsage field */
            if (size >= sizeof(VM_COUNTERS))
            {
                if (!info) ret = STATUS_ACCESS_VIOLATION;
                else
                {
                    memset(&pvmi, 0, sizeof(pvmi));
                    if (handle == GetCurrentProcess()) fill_vm_counters( &pvmi, -1 );
                    else
                    {
                        SERVER_START_REQ(get_process_vm_counters)
                        {
                            req->handle = wine_server_obj_handle( handle );
                            if (!(ret = wine_server_call( req )))
                            {
                                pvmi.PeakVirtualSize = reply->peak_virtual_size;
                                pvmi.VirtualSize = reply->virtual_size;
                                pvmi.PeakWorkingSetSize = reply->peak_working_set_size;
                                pvmi.WorkingSetSize = reply->working_set_size;
                                pvmi.PagefileUsage = reply->pagefile_usage;
                                pvmi.PeakPagefileUsage = reply->peak_pagefile_usage;
                            }
                        }
                        SERVER_END_REQ;
                        if (ret) break;
                    }
                    if (size >= sizeof(VM_COUNTERS_EX))
                        pvmi.PrivateUsage = pvmi.PagefileUsage;
                    len = size;
                    if (len != sizeof(VM_COUNTERS)) len = sizeof(VM_COUNTERS_EX);
                    memcpy(info, &pvmi, min(size, sizeof(pvmi)));
                }
                if (size != sizeof(VM_COUNTERS) && size != sizeof(VM_COUNTERS_EX))
                    ret = STATUS_INFO_LENGTH_MISMATCH;
            }
            else
            {
                len = sizeof(pvmi);
                ret = STATUS_INFO_LENGTH_MISMATCH;
            }
        }
        break;

    case ProcessTimes:
        {
            KERNEL_USER_TIMES pti = {{{0}}};

            if (size >= sizeof(KERNEL_USER_TIMES))
            {
                if (!info) ret = STATUS_ACCESS_VIOLATION;
                else if (!handle) ret = STATUS_INVALID_HANDLE;
                else
                {
                    long ticks = sysconf(_SC_CLK_TCK);
                    struct tms tms;

                    /* FIXME: user/kernel times only work for current process */
                    if (ticks && times( &tms ) != -1)
                    {
                        pti.UserTime.QuadPart = (ULONGLONG)tms.tms_utime * 10000000 / ticks;
                        pti.KernelTime.QuadPart = (ULONGLONG)tms.tms_stime * 10000000 / ticks;
                    }

                    SERVER_START_REQ(get_process_info)
                    {
                        req->handle = wine_server_obj_handle( handle );
                        if ((ret = wine_server_call( req )) == STATUS_SUCCESS)
                        {
                            pti.CreateTime.QuadPart = reply->start_time;
                            pti.ExitTime.QuadPart = reply->end_time;
                        }
                    }
                    SERVER_END_REQ;

                    memcpy(info, &pti, sizeof(KERNEL_USER_TIMES));
                    len = sizeof(KERNEL_USER_TIMES);
                }
                if (size > sizeof(KERNEL_USER_TIMES)) ret = STATUS_INFO_LENGTH_MISMATCH;
            }
            else
            {
                len = sizeof(KERNEL_USER_TIMES);
                ret = STATUS_INFO_LENGTH_MISMATCH;
            }
        }
        break;

    case ProcessDebugPort:
        len = sizeof(DWORD_PTR);
        if (size != len) return STATUS_INFO_LENGTH_MISMATCH;
        if (!info) ret = STATUS_ACCESS_VIOLATION;
        else
        {
            HANDLE debug;

            SERVER_START_REQ(get_process_debug_info)
            {
                req->handle = wine_server_obj_handle( handle );
                ret = wine_server_call( req );
                debug = wine_server_ptr_handle( reply->debug );
            }
            SERVER_END_REQ;
            if (ret == STATUS_SUCCESS)
            {
                *(DWORD_PTR *)info = ~0ul;
                NtClose( debug );
            }
            else if (ret == STATUS_PORT_NOT_SET)
            {
                *(DWORD_PTR *)info = 0;
                ret = STATUS_SUCCESS;
            }
            else return ret;
        }
        break;

    case ProcessPriorityBoost:
        len = sizeof(ULONG);
        if (size != len) return STATUS_INFO_LENGTH_MISMATCH;
        if (!info) ret = STATUS_ACCESS_VIOLATION;
        else
        {
            ULONG *disable_boost = info;
            SERVER_START_REQ(get_process_info)
            {
                req->handle = wine_server_obj_handle( handle );
                ret = wine_server_call( req );
                *disable_boost = reply->disable_boost;
            }
            SERVER_END_REQ;
        }
        break;

    case ProcessDebugFlags:
        len = sizeof(DWORD);
        if (size == len)
        {
            if (!info) ret = STATUS_ACCESS_VIOLATION;
            else
            {
                HANDLE debug;

                SERVER_START_REQ(get_process_debug_info)
                {
                    req->handle = wine_server_obj_handle( handle );
                    ret = wine_server_call( req );
                    debug = wine_server_ptr_handle( reply->debug );
                    *(DWORD *)info = reply->debug_children;
                }
                SERVER_END_REQ;
                if (ret == STATUS_SUCCESS) NtClose( debug );
                else if (ret == STATUS_PORT_NOT_SET) ret = STATUS_SUCCESS;
            }
        }
        else ret = STATUS_INFO_LENGTH_MISMATCH;
        break;

    case ProcessDefaultHardErrorMode:
        len = sizeof(process_error_mode);
        if (size == len) memcpy(info, &process_error_mode, len);
        else ret = STATUS_INFO_LENGTH_MISMATCH;
        break;

    case ProcessDebugObjectHandle:
        len = sizeof(HANDLE);
        if (size && ((ULONG_PTR)info & 3)) return STATUS_DATATYPE_MISALIGNMENT;
        /* STATUS_ACCESS_VIOLATION is returned on Windows for unaccessible ret_len even if ret_len is
         * not going to be written. */
        if (ret_len) *(volatile ULONG *)ret_len |= 0;
        if (size != len) return STATUS_INFO_LENGTH_MISMATCH;
        SERVER_START_REQ(get_process_debug_info)
        {
            req->handle = wine_server_obj_handle( handle );
            ret = wine_server_call( req );
            *(HANDLE *)info = wine_server_ptr_handle( reply->debug );
        }
        SERVER_END_REQ;
        break;

    case ProcessHandleCount:
        if (size >= 4)
        {
            if (!info) ret = STATUS_ACCESS_VIOLATION;
            else if (!handle) ret = STATUS_INVALID_HANDLE;
            else
            {
                FIXME( "ProcessHandleCount (%p,%p,0x%08x,%p) stub\n", handle, info, size, ret_len );
                memset(info, 0, 4);
                len = 4;
            }
            if (size > 4) ret = STATUS_INFO_LENGTH_MISMATCH;
        }
        else
        {
            len = 4;
            ret = STATUS_INFO_LENGTH_MISMATCH;
        }
        break;

    case ProcessHandleTable:
        FIXME( "ProcessHandleTable (%p,%p,0x%08x,%p) stub\n", handle, info, size, ret_len );
        len = 0;
        break;

    case ProcessAffinityMask:
        len = sizeof(ULONG_PTR);
        if (size == len)
        {
            const ULONG_PTR system_mask = get_system_affinity_mask();

            SERVER_START_REQ(get_process_info)
            {
                req->handle = wine_server_obj_handle( handle );
                if (!(ret = wine_server_call( req )))
                    *(ULONG_PTR *)info = reply->affinity & system_mask;
            }
            SERVER_END_REQ;
        }
        else return STATUS_INFO_LENGTH_MISMATCH;
        break;

    case ProcessSessionInformation:
        len = sizeof(DWORD);
        if (size == len)
        {
            SERVER_START_REQ(get_process_info)
            {
                req->handle = wine_server_obj_handle( handle );
                if (!(ret = wine_server_call( req )))
                    *(DWORD *)info = reply->session_id;
            }
            SERVER_END_REQ;
        }
        else ret = STATUS_INFO_LENGTH_MISMATCH;
        break;

    case ProcessWow64Information:
        len = sizeof(ULONG_PTR);
        if (size != len) return STATUS_INFO_LENGTH_MISMATCH;
        if (handle == GetCurrentProcess())
            *(ULONG_PTR *)info = is_old_wow64() ? (ULONG_PTR)peb : (ULONG_PTR)wow_peb;
        else
        {
            ULONG_PTR val = 0;

            SERVER_START_REQ( get_process_info )
            {
                req->handle = wine_server_obj_handle( handle );
                ret = wine_server_call( req );
                if (!ret && !is_machine_64bit( reply->machine ) && is_machine_64bit( native_machine ))
                    val = reply->peb + 0x1000;
            }
            SERVER_END_REQ;
            if (!ret) *(ULONG_PTR *)info = val;
        }
        break;

    /* iOS-Madeira (WOW64_DESIGN.md §2): the single source of truth for B, the
     * host address of guest 0 for a 32-bit pseudo-process.  0 when the target
     * has no guest window.  wow64.dll and the FEX WoW64 module each read this
     * once at process init; nothing else may invent a B. */
    case ProcessWineIosWowGuestBase:
        len = sizeof(ULONG_PTR);
        if (size != len) return STATUS_INFO_LENGTH_MISMATCH;
        if (handle == GetCurrentProcess()) *(ULONG_PTR *)info = ios_wow_base();
        else
        {
            ULONG_PTR val = 0;

            /* pseudo-processes share one address space, so the registry is
             * keyed by PEB and a handle resolves through the server. */
            SERVER_START_REQ( get_process_info )
            {
                req->handle = wine_server_obj_handle( handle );
                ret = wine_server_call( req );
                if (!ret) val = ios_wow_base_for_peb( wine_server_get_ptr( reply->peb ) );
            }
            SERVER_END_REQ;
            if (!ret) *(ULONG_PTR *)info = val;
        }
        break;

    case ProcessImageFileName:
        /* FIXME: Should return a device path */
    case ProcessImageFileNameWin32:
        SERVER_START_REQ( get_process_image_name )
        {
            const unsigned int min_size = sizeof(UNICODE_STRING) + sizeof(WCHAR);
            UNICODE_STRING *str = info;

            req->handle = wine_server_obj_handle( handle );
            req->win32  = (class == ProcessImageFileNameWin32);
            wine_server_set_reply( req, str ? str + 1 : NULL,
                                   size > min_size ? size - min_size : 0 );
            ret = wine_server_call( req );
            if (ret == STATUS_BUFFER_TOO_SMALL) ret = STATUS_INFO_LENGTH_MISMATCH;
            len = min_size + reply->len;
            if (ret == STATUS_SUCCESS)
            {
                str->Length = reply->len;
                str->MaximumLength = str->Length + sizeof(WCHAR);
                str->Buffer = (PWSTR)(str + 1);
                str->Buffer[str->Length / sizeof(WCHAR)] = 0;
            }
        }
        SERVER_END_REQ;
        break;

    case ProcessExecuteFlags:
        len = sizeof(ULONG);
        if (size != len)
            ret = STATUS_INFO_LENGTH_MISMATCH;
        else if (is_win64 && !is_wow64())
            *(ULONG *)info = MEM_EXECUTE_OPTION_DISABLE |
                             MEM_EXECUTE_OPTION_DISABLE_THUNK_EMULATION |
                             MEM_EXECUTE_OPTION_PERMANENT;
        else
            *(ULONG *)info = execute_flags;
        break;

    case ProcessPriorityClass:
        len = sizeof(PROCESS_PRIORITY_CLASS);
        if (size == len)
        {
            if (!info) ret = STATUS_ACCESS_VIOLATION;
            else
            {
                PROCESS_PRIORITY_CLASS *priority = info;

                SERVER_START_REQ(get_process_info)
                {
                    req->handle = wine_server_obj_handle( handle );
                    if ((ret = wine_server_call( req )) == STATUS_SUCCESS)
                    {
                        priority->PriorityClass = reply->priority;
                        /* FIXME: Not yet supported by the wineserver */
                        priority->Foreground = FALSE;
                    }
                }
                SERVER_END_REQ;
            }
        }
        else ret = STATUS_INFO_LENGTH_MISMATCH;
        break;

    case ProcessCookie:
        if (handle == NtCurrentProcess())
        {
            len = sizeof(ULONG);
            if (size == len) *(ULONG *)info = process_cookie;
            else ret = STATUS_INFO_LENGTH_MISMATCH;
        }
        else ret = STATUS_INVALID_PARAMETER;
        break;

    case ProcessImageInformation:
        len = sizeof(SECTION_IMAGE_INFORMATION);
        if (size == len)
        {
            if (info)
            {
                struct pe_image_info pe_info;

                SERVER_START_REQ( get_process_info )
                {
                    req->handle = wine_server_obj_handle( handle );
                    wine_server_set_reply( req, &pe_info, sizeof(pe_info) );
                    if ((ret = wine_server_call( req )) == STATUS_SUCCESS)
                        virtual_fill_image_information( &pe_info, info );
                }
                SERVER_END_REQ;
            }
            else ret = STATUS_ACCESS_VIOLATION;
        }
        else ret = STATUS_INFO_LENGTH_MISMATCH;
        break;

    case ProcessCycleTime:
        len = sizeof(PROCESS_CYCLE_TIME_INFORMATION);
        if (size == len)
        {
            if (!info) ret = STATUS_ACCESS_VIOLATION;
            else
            {
                PROCESS_CYCLE_TIME_INFORMATION cycles;

                FIXME( "ProcessCycleTime (%p,%p,0x%08x,%p) stub\n", handle, info, size, ret_len );
                cycles.AccumulatedCycles = 0;
                cycles.CurrentCycleCount = 0;

                memcpy(info, &cycles, sizeof(PROCESS_CYCLE_TIME_INFORMATION));
            }
        }
        else ret = STATUS_INFO_LENGTH_MISMATCH;
        break;

    case ProcessQuotaLimits:
        {
            QUOTA_LIMITS qlimits;

            FIXME( "ProcessQuotaLimits (%p,%p,0x%08x,%p) stub\n", handle, info, size, ret_len );

            len = sizeof(QUOTA_LIMITS);
            if (size == len)
            {
                if (!handle) ret = STATUS_INVALID_HANDLE;
                else
                {
                    /* FIXME: SetProcessWorkingSetSize can also set the quota values.
                                Quota Limits should be stored inside the process. */
                    qlimits.PagedPoolLimit = (SIZE_T)-1;
                    qlimits.NonPagedPoolLimit = (SIZE_T)-1;
                    /* Default minimum working set size is 204800 bytes (50 Pages) */
                    qlimits.MinimumWorkingSetSize = 204800;
                    /* Default maximum working set size is 1413120 bytes (345 Pages) */
                    qlimits.MaximumWorkingSetSize = 1413120;
                    qlimits.PagefileLimit = (SIZE_T)-1;
                    qlimits.TimeLimit.QuadPart = -1;
                    memcpy(info, &qlimits, len);
                }
            }
            else ret = STATUS_INFO_LENGTH_MISMATCH;
            break;
        }

    default:
        FIXME("(%p,info_class=%d,%p,0x%08x,%p) Unknown information class\n",
              handle, class, info, size, ret_len );
        ret = STATUS_INVALID_INFO_CLASS;
        break;
    }

    if (ret_len) *ret_len = len;
    return ret;
}

#ifndef _WIN64

/**********************************************************************
 *           NtWow64QueryInformationProcess64  (NTDLL.@)
 */
NTSTATUS WINAPI NtWow64QueryInformationProcess64( HANDLE handle, PROCESSINFOCLASS class, void *info,
                                                  ULONG size, ULONG *ret_len )
{
    NTSTATUS ret;
    ULONG len = 0;

    TRACE( "(%p,0x%08x,%p,0x%08x,%p)\n", handle, class, info, size, ret_len );

    switch (class)
    {
    case ProcessBasicInformation:
        {
            PROCESS_BASIC_INFORMATION64 pbi;
            const ULONG_PTR affinity_mask = get_system_affinity_mask();

            if (size >= sizeof(PROCESS_BASIC_INFORMATION64))
            {
                if (!info) ret = STATUS_ACCESS_VIOLATION;
                else
                {
                    SERVER_START_REQ(get_process_info)
                    {
                        req->handle = wine_server_obj_handle( handle );
                        if ((ret = wine_server_call( req )) == STATUS_SUCCESS)
                        {
                            pbi.ExitStatus = reply->exit_code;
                            pbi.PebBaseAddress = (ULONG)wine_server_get_ptr( reply->peb );
                            pbi.AffinityMask = reply->affinity & affinity_mask;
                            pbi.BasePriority = reply->base_priority;
                            pbi.UniqueProcessId = reply->pid;
                            pbi.InheritedFromUniqueProcessId = reply->ppid;
                        }
                    }
                    SERVER_END_REQ;

                    memcpy( info, &pbi, sizeof(PROCESS_BASIC_INFORMATION64) );
                    len = sizeof(PROCESS_BASIC_INFORMATION64);
                }
                if (size > sizeof(PROCESS_BASIC_INFORMATION64)) ret = STATUS_INFO_LENGTH_MISMATCH;
            }
            else
            {
                len = sizeof(PROCESS_BASIC_INFORMATION64);
                ret = STATUS_INFO_LENGTH_MISMATCH;
            }
        }
        break;

    default:
        return STATUS_NOT_IMPLEMENTED;
    }

    if (ret_len) *ret_len = len;
    return ret;
}

#endif

/**********************************************************************
 *           NtSetInformationProcess  (NTDLL.@)
 */
NTSTATUS WINAPI NtSetInformationProcess( HANDLE handle, PROCESSINFOCLASS class, void *info, ULONG size )
{
    unsigned int ret = STATUS_SUCCESS;

    switch (class)
    {
    case ProcessAccessToken:
    {
        const PROCESS_ACCESS_TOKEN *token = info;

        if (size != sizeof(PROCESS_ACCESS_TOKEN)) return STATUS_INFO_LENGTH_MISMATCH;

        SERVER_START_REQ( set_process_info )
        {
            req->handle = wine_server_obj_handle( handle );
            req->token = wine_server_obj_handle( token->Token );
            req->mask = SET_PROCESS_INFO_TOKEN;
            ret = wine_server_call( req );
        }
        SERVER_END_REQ;
        break;
    }

    case ProcessDefaultHardErrorMode:
        if (size != sizeof(UINT)) return STATUS_INVALID_PARAMETER;
        process_error_mode = *(UINT *)info;
        break;

    case ProcessAffinityMask:
    {
        const ULONG_PTR system_mask = get_system_affinity_mask();

        if (size != sizeof(DWORD_PTR)) return STATUS_INVALID_PARAMETER;
        if (*(PDWORD_PTR)info & ~system_mask)
            return STATUS_INVALID_PARAMETER;
        if (!*(PDWORD_PTR)info)
            return STATUS_INVALID_PARAMETER;
        SERVER_START_REQ( set_process_info )
        {
            req->handle   = wine_server_obj_handle( handle );
            req->affinity = *(PDWORD_PTR)info;
            req->mask     = SET_PROCESS_INFO_AFFINITY;
            ret = wine_server_call( req );
        }
        SERVER_END_REQ;
        break;
    }
    case ProcessPriorityClass:
        if (size != sizeof(PROCESS_PRIORITY_CLASS)) return STATUS_INVALID_PARAMETER;
        else
        {
            PROCESS_PRIORITY_CLASS* ppc = info;

            SERVER_START_REQ( set_process_info )
            {
                req->handle   = wine_server_obj_handle( handle );
                /* FIXME Foreground isn't used */
                req->priority = ppc->PriorityClass;
                req->mask     = SET_PROCESS_INFO_PRIORITY;
                ret = wine_server_call( req );
            }
            SERVER_END_REQ;
        }
        break;

    case ProcessBasePriority:
        if (size != sizeof(KPRIORITY)) return STATUS_INVALID_PARAMETER;
        else
        {
            KPRIORITY* base_priority = info;

            SERVER_START_REQ( set_process_info )
            {
                req->handle        = wine_server_obj_handle( handle );
                req->base_priority = *base_priority;
                req->mask          = SET_PROCESS_INFO_BASE_PRIORITY;
                ret = wine_server_call( req );
            }
            SERVER_END_REQ;
        }
        break;

    case ProcessPriorityBoost:
        if (size != sizeof(ULONG)) return STATUS_INVALID_PARAMETER;
        else
        {
            ULONG* disable_boost = info;

            SERVER_START_REQ( set_process_info )
            {
                req->handle        = wine_server_obj_handle( handle );
                req->disable_boost = *disable_boost;
                req->mask          = SET_PROCESS_INFO_DISABLE_BOOST;
                ret = wine_server_call( req );
            }
            SERVER_END_REQ;
        }
        break;

    case ProcessExecuteFlags:
        if ((is_win64 && !is_wow64()) || size != sizeof(ULONG)) return STATUS_INVALID_PARAMETER;
        if (execute_flags & MEM_EXECUTE_OPTION_PERMANENT) return STATUS_ACCESS_DENIED;
        else
        {
            BOOL enable;
            switch (*(ULONG *)info & (MEM_EXECUTE_OPTION_ENABLE|MEM_EXECUTE_OPTION_DISABLE))
            {
            case MEM_EXECUTE_OPTION_ENABLE:
                enable = TRUE;
                break;
            case MEM_EXECUTE_OPTION_DISABLE:
                enable = FALSE;
                break;
            default:
                return STATUS_INVALID_PARAMETER;
            }
            execute_flags = *(ULONG *)info;
            virtual_set_force_exec( enable );
        }
        break;

    case ProcessInstrumentationCallback:
    {
        PROCESS_INSTRUMENTATION_CALLBACK_INFORMATION *instr = info;
        void *callback;

        if (size < sizeof(callback)) return STATUS_INFO_LENGTH_MISMATCH;
        if (size >= sizeof(PROCESS_INSTRUMENTATION_CALLBACK_INFORMATION)) callback = instr->Callback;
        else                                                              callback = *(void **)info;
        ret = STATUS_SUCCESS;
        if (handle != GetCurrentProcess())
        {
            FIXME( "Setting ProcessInstrumentationCallback is not yet supported for other process.\n" );
            break;
        }
        set_process_instrumentation_callback( callback );
        break;
    }

    case ProcessThreadStackAllocation:
    {
        void *addr = NULL;
        SIZE_T reserve;
        PROCESS_STACK_ALLOCATION_INFORMATION *stack = info;
        if (size == sizeof(PROCESS_STACK_ALLOCATION_INFORMATION_EX))
            stack = &((PROCESS_STACK_ALLOCATION_INFORMATION_EX *)info)->AllocInfo;
        else if (size != sizeof(*stack)) return STATUS_INFO_LENGTH_MISMATCH;

        reserve = stack->ReserveSize;
        ret = NtAllocateVirtualMemory( GetCurrentProcess(), &addr, stack->ZeroBits, &reserve,
                                       MEM_RESERVE, PAGE_READWRITE );
        if (!ret)
        {
#ifdef VALGRIND_STACK_REGISTER
            VALGRIND_STACK_REGISTER( addr, (char *)addr + reserve );
#endif
            stack->StackBase = addr;
        }
        break;
    }

    case ProcessManageWritesToExecutableMemory:
    {
#ifdef __aarch64__
        const MANAGE_WRITES_TO_EXECUTABLE_MEMORY *mem = info;

        if (size != sizeof(*mem)) return STATUS_INFO_LENGTH_MISMATCH;
        if (handle != GetCurrentProcess()) return STATUS_NOT_SUPPORTED;
        if (mem->Version != 2) return STATUS_REVISION_MISMATCH;
        if (mem->ThreadAllowWrites) return STATUS_INVALID_PARAMETER;
        virtual_enable_write_exceptions( mem->ProcessEnableWriteExceptions );
        break;
#else
        return STATUS_NOT_SUPPORTED;
#endif
    }

    case ProcessWineMakeProcessSystem:
        if (size != sizeof(HANDLE *)) return STATUS_INFO_LENGTH_MISMATCH;
        SERVER_START_REQ( make_process_system )
        {
            req->handle = wine_server_obj_handle( handle );
            if (!(ret = wine_server_call( req )))
                *(HANDLE *)info = wine_server_ptr_handle( reply->event );
        }
        SERVER_END_REQ;
        return ret;

    case ProcessWineGrantAdminToken:
        SERVER_START_REQ( grant_process_admin_token )
        {
            req->handle = wine_server_obj_handle( handle );
            ret = wine_server_call( req );
        }
        SERVER_END_REQ;
        break;

    case ProcessPowerThrottlingState:
        FIXME( "ProcessPowerThrottlingState - stub\n" );
        return STATUS_SUCCESS;

    default:
        FIXME( "(%p,0x%08x,%p,0x%08x) stub\n", handle, class, info, size );
        ret = STATUS_NOT_IMPLEMENTED;
        break;
    }
    return ret;
}


/**********************************************************************
 *           NtOpenProcess  (NTDLL.@)
 */
NTSTATUS WINAPI NtOpenProcess( HANDLE *handle, ACCESS_MASK access,
                               const OBJECT_ATTRIBUTES *attr, const CLIENT_ID *id )
{
    unsigned int status;

    *handle = 0;

    SERVER_START_REQ( open_process )
    {
        req->pid        = HandleToULong( id->UniqueProcess );
        req->access     = access;
        req->attributes = attr ? attr->Attributes : 0;
        status = wine_server_call( req );
        if (!status) *handle = wine_server_ptr_handle( reply->handle );
    }
    SERVER_END_REQ;
    return status;
}


/**********************************************************************
 *           NtSuspendProcess  (NTDLL.@)
 */
NTSTATUS WINAPI NtSuspendProcess( HANDLE handle )
{
    unsigned int ret;

    SERVER_START_REQ( suspend_process )
    {
        req->handle = wine_server_obj_handle( handle );
        ret = wine_server_call( req );
    }
    SERVER_END_REQ;
    return ret;
}


/**********************************************************************
 *           NtResumeProcess  (NTDLL.@)
 */
NTSTATUS WINAPI NtResumeProcess( HANDLE handle )
{
    unsigned int ret;

    SERVER_START_REQ( resume_process )
    {
        req->handle = wine_server_obj_handle( handle );
        ret = wine_server_call( req );
    }
    SERVER_END_REQ;
    return ret;
}


/**********************************************************************
 *           NtGetNextProcess  (NTDLL.@)
 */
NTSTATUS WINAPI NtGetNextProcess( HANDLE process, ACCESS_MASK access, ULONG attributes,
                                  ULONG flags, HANDLE *handle )
{
    HANDLE ret_handle = 0;
    unsigned int ret;

    TRACE( "process %p, access %#x, attributes %#x, flags %#x, handle %p.\n",
           process, access, attributes, flags, handle );

    SERVER_START_REQ( get_next_process )
    {
        req->last = wine_server_obj_handle( process );
        req->access = access;
        req->attributes = attributes;
        req->flags = flags;
        if (!(ret = wine_server_call( req ))) ret_handle = wine_server_ptr_handle( reply->handle );
    }
    SERVER_END_REQ;

    *handle = ret_handle;
    return ret;
}


/**********************************************************************
 *           NtDebugActiveProcess  (NTDLL.@)
 */
NTSTATUS WINAPI NtDebugActiveProcess( HANDLE process, HANDLE debug )
{
    unsigned int ret;

    SERVER_START_REQ( debug_process )
    {
        req->handle = wine_server_obj_handle( process );
        req->debug  = wine_server_obj_handle( debug );
        req->attach = 1;
        ret = wine_server_call( req );
    }
    SERVER_END_REQ;
    return ret;
}


/**********************************************************************
 *           NtRemoveProcessDebug  (NTDLL.@)
 */
NTSTATUS WINAPI NtRemoveProcessDebug( HANDLE process, HANDLE debug )
{
    unsigned int ret;

    SERVER_START_REQ( debug_process )
    {
        req->handle = wine_server_obj_handle( process );
        req->debug  = wine_server_obj_handle( debug );
        req->attach = 0;
        ret = wine_server_call( req );
    }
    SERVER_END_REQ;
    return ret;
}


/**********************************************************************
 *           NtDebugContinue  (NTDLL.@)
 */
NTSTATUS WINAPI NtDebugContinue( HANDLE handle, CLIENT_ID *client, NTSTATUS status )
{
    unsigned int ret;

    SERVER_START_REQ( continue_debug_event )
    {
        req->debug  = wine_server_obj_handle( handle );
        req->pid    = HandleToULong( client->UniqueProcess );
        req->tid    = HandleToULong( client->UniqueThread );
        req->status = status;
        ret = wine_server_call( req );
    }
    SERVER_END_REQ;
    return ret;
}
