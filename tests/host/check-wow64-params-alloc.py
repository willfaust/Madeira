#!/usr/bin/env python3
"""build_wow64_parameters() ends only the booting pseudo-process when its block cannot be allocated below 2 GB (#590); no Wine runs.

Pseudo-processes are threads of one app. build_wow64_parameters() in
build/ntdll-unix/env_ios.c asserted that its NtAllocateVirtualMemory() below the
32-bit 2 GB line succeeded: a failure aborted the whole app, and a build without
assertions wrote through a NULL pointer. On iOS it now calls
ios_fatal_startup_error(), which logs the status and ends only the boot thread
with pthread_exit().

Compiles the production build_wow64_parameters(), the _WIN64 dup_unicode_string()
and ios_fatal_startup_error() (WINE_IOS and _WIN64 defined) with stub types and a
stub allocator, and checks in separate processes:
  - a failed allocation ends the boot thread inside the call, logs the FATAL line
    with the size and status, and leaves the app (the joining main thread) running;
  - a successful allocation still fills the block (sizes, fields, strings, environment);
  - and statically, that the fatal function is declared once, before its first use,
    and that the unconditional assert is left only for non-iOS builds.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/env_ios.c').read_text()
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def function(text, signature):
    start = text.index(signature)
    brace = text.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


# ------------------------------------------------------------------ static
proto_re = re.compile(r'^static void ios_fatal_startup_error\( const char \*err, \.\.\. \)[^;{\n]*;$', re.M)
prototypes = list(proto_re.finditer(source))
builder_at = source.index('static void *build_wow64_parameters(')
builder = function(source, 'static void *build_wow64_parameters(')
definitions = re.findall(r'^static void ios_fatal_startup_error\( const char \*err, \.\.\. \)\n\{', source, re.M)
require(len(prototypes) == 1, 'ios_fatal_startup_error has exactly one prototype')
require(len(prototypes) == 1 and prototypes[0].start() < builder_at,
        'the prototype comes before build_wow64_parameters')
require(len(definitions) == 1, 'ios_fatal_startup_error has exactly one definition')
require(builder.count('assert( !status );') == 1 and
        re.search(r'#ifdef WINE_IOS\n.*?\n#else\n\s*assert\( !status \);\n#endif\n', builder, re.S) is not None,
        'the assert is only in the #else of #ifdef WINE_IOS inside build_wow64_parameters')
require(re.search(r'#ifdef WINE_IOS\n(?:.*\n)*?\s*if \(status\)\n\s*ios_fatal_startup_error\(', builder) is not None,
        'on iOS a failed allocation calls ios_fatal_startup_error()')

# ------------------------------------------------------------------ behaviour
prototype = prototypes[0].group(0) if prototypes else ''
dup_start = source.index('#ifdef _WIN64\nstatic inline void dup_unicode_string')
dup = source[dup_start:source.index('\n}\n', dup_start) + 3]
fatal = function(source, 'static void ios_fatal_startup_error( const char *err, ... )\n{')

harness = r'''
#define WINE_IOS 1
#define _WIN64 1
#include <assert.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint16_t WCHAR;
typedef uint16_t USHORT;
typedef uint32_t ULONG;
typedef uint32_t DWORD;
typedef size_t SIZE_T;
typedef int32_t NTSTATUS;
typedef void *HANDLE;
typedef struct { USHORT Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { USHORT Length, MaximumLength; ULONG Buffer; } UNICODE_STRING32;
#define PARAMS_FIELDS(H, STR) \
    ULONG AllocationSize, Size, Flags, DebugFlags; \
    H ConsoleHandle; \
    ULONG ConsoleFlags; \
    H hStdInput, hStdOutput, hStdError; \
    ULONG dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; \
    USHORT wShowWindow; \
    ULONG ProcessGroupId; \
    struct { STR DosPath; } CurrentDirectory; \
    STR DllPath, ImagePathName, CommandLine, WindowTitle, Desktop, ShellInfo, RuntimeInfo;
typedef struct { PARAMS_FIELDS(HANDLE, UNICODE_STRING) void *Environment; ULONG EnvironmentSize; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { PARAMS_FIELDS(ULONG, UNICODE_STRING32) ULONG Environment; ULONG EnvironmentSize; } RTL_USER_PROCESS_PARAMETERS32;

#define HandleToULong(h) ((ULONG)(uintptr_t)(h))
#define NtCurrentProcess() ((HANDLE)(intptr_t)-1)
#define MEM_COMMIT 0x1000
#define PAGE_READWRITE 4
#define STATUS_NO_MEMORY ((NTSTATUS)0xC0000017)
static const uintptr_t limit_2g = 0x80000000u;

static ULONG ios_wow_guest_addr( const void *ptr ) { return (ULONG)(uintptr_t)ptr; }

#define ERR( ... ) do { fprintf( stderr, "err:ntdll: " ); fprintf( stderr, __VA_ARGS__ ); fputc( '\n', stderr ); } while (0)
#define OS_LOG_DEFAULT 0
/* os_log_error( log, "[Wine ntdll] FATAL: %{public}s", buf ) */
static void stub_os_log( const char *fmt, const char *msg )
{
    char copy[128], *at;
    strncpy( copy, fmt, sizeof(copy) - 1 );
    copy[sizeof(copy) - 1] = 0;
    if ((at = strstr( copy, "%{public}s" ))) memmove( at + 2, at + 10, strlen( at + 10 ) + 1 );
    fprintf( stderr, copy, msg );
    fputc( '\n', stderr );
}
#define os_log_error( log, fmt, msg ) ( (void)(log), stub_os_log( fmt, msg ) )

static int alloc_fail;
static SIZE_T requested;
static NTSTATUS NtAllocateVirtualMemory( HANDLE process, void **addr, uintptr_t zero_bits, SIZE_T *size,
                                         ULONG type, ULONG protect )
{
    (void)process; (void)zero_bits; (void)type; (void)protect;
    requested = *size;
    if (alloc_fail) return STATUS_NO_MEMORY;   /* *addr stays NULL */
    *addr = calloc( 1, *size );                /* exact size: ASan sees any overrun */
    return 0;
}

''' + prototype + '\n' + fatal + '\n\n' + dup + '\n\n' + builder + r'''

static int bad;
static void check( int ok, const char *label ) { printf( "%s: %s\n", ok ? "PASS" : "FAIL", label ); bad |= !ok; }

static const WCHAR image[] = { 'C', ':', '\\', 'g', '.', 'e', 'x', 'e', 0 };
static const WCHAR command[] = { 'g', '.', 'e', 'x', 'e', ' ', '-', 'x', 0, 0 };
static const char env_data[] = "A=1\0B=22\0";

static RTL_USER_PROCESS_PARAMETERS make_params( void )
{
    RTL_USER_PROCESS_PARAMETERS p;
    memset( &p, 0, sizeof(p) );
    p.Flags = 0x4001;
    p.dwFlags = 0x101;
    p.wShowWindow = 5;
    p.ProcessGroupId = 7;
    p.ImagePathName.Buffer = (WCHAR *)image;
    p.ImagePathName.Length = sizeof(image) - sizeof(WCHAR);
    p.ImagePathName.MaximumLength = sizeof(image);
    p.CommandLine.Buffer = (WCHAR *)command;
    p.CommandLine.Length = 8 * sizeof(WCHAR);
    p.CommandLine.MaximumLength = sizeof(command);
    p.Environment = (void *)env_data;
    p.EnvironmentSize = sizeof(env_data);
    return p;
}

static int boot_returned;
static void *boot_thread( void *arg )
{
    RTL_USER_PROCESS_PARAMETERS p = make_params();
    (void)arg;
    build_wow64_parameters( &p );
    boot_returned = 1;   /* not reached when the allocation fails */
    return (void *)1;
}

static const void *guest( const RTL_USER_PROCESS_PARAMETERS32 *block, ULONG addr )
{
    return (const char *)block + (addr - ios_wow_guest_addr( block ));
}

int main( int argc, char **argv )
{
    if (argc != 2) return 2;
    if (!strcmp( argv[1], "fail" ))
    {
        pthread_t thread;
        void *result = (void *)2;
        alloc_fail = 1;
        pthread_create( &thread, NULL, boot_thread, NULL );
        pthread_join( thread, &result );
        printf( "main: thread joined, result-null=%d returned=%d\n", result == NULL, boot_returned );
        printf( "main: app still running\n" );
        fflush( stdout );
        return 0;
    }
    else
    {
        RTL_USER_PROCESS_PARAMETERS p = make_params();
        RTL_USER_PROCESS_PARAMETERS32 *block;
        SIZE_T expected = sizeof(*block) + sizeof(image) + sizeof(command) + sizeof(env_data);
        block = build_wow64_parameters( &p );
        check( block != NULL, "a block is returned" );
        check( requested == expected, "the block is requested with the summed size" );
        check( block->Size == requested && block->AllocationSize == requested, "Size == AllocationSize == the requested size" );
        check( block->Flags == 0x4001 && block->dwFlags == 0x101 && block->wShowWindow == 5 && block->ProcessGroupId == 7,
               "Flags, dwFlags, wShowWindow and ProcessGroupId are copied" );
        check( block->ImagePathName.Length == p.ImagePathName.Length &&
               block->ImagePathName.MaximumLength == sizeof(image) &&
               !memcmp( guest( block, block->ImagePathName.Buffer ), image, sizeof(image) ),
               "ImagePathName is copied byte-exact into the block" );
        check( block->CommandLine.Length == p.CommandLine.Length &&
               !memcmp( guest( block, block->CommandLine.Buffer ), command, sizeof(command) ),
               "CommandLine is copied byte-exact into the block" );
        check( block->CurrentDirectory.DosPath.Buffer == 0 && block->DllPath.Buffer == 0,
               "empty strings stay unset" );
        check( block->EnvironmentSize == sizeof(env_data) &&
               !memcmp( guest( block, block->Environment ), env_data, sizeof(env_data) ) &&
               (const char *)guest( block, block->Environment ) + block->EnvironmentSize == (const char *)block + requested,
               "Environment bytes are copied and end at the end of the block" );
        free( block );
        return bad;
    }
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-wow64-params-') as directory:
    folder = Path(directory)
    src = folder / 'check.c'
    src.write_text(harness)
    exe = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-g', '-pthread',
             str(src), '-o', str(exe)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-fno-omit-frame-pointer']
    build = subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True, text=True)
    if build.returncode == 0:
        print('built with AddressSanitizer/UBSan')
    else:
        build = subprocess.run(flags, capture_output=True, text=True)
        print('built without sanitizers' if build.returncode == 0 else build.stderr[-4000:])
    require(build.returncode == 0, 'harness compiles')
    if build.returncode == 0:
        fail = subprocess.run([str(exe), 'fail'], capture_output=True, text=True, timeout=60)
        require(fail.returncode == 0, 'failed allocation: the process exits 0 (no abort, no crash)')
        require('returned=0' in fail.stdout and 'result-null=1' in fail.stdout,
                'failed allocation: the boot thread ends inside the call (pthread_exit)')
        require('FATAL: ' in fail.stderr and 'could not be allocated below 2 GB' in fail.stderr and
                'status c0000017' in fail.stderr,
                'failed allocation: the FATAL line names the cause and the status')
        require('main: app still running' in fail.stdout, 'failed allocation: the app keeps running after the join')
        if failures:
            print(fail.stdout[-2000:] + fail.stderr[-2000:])
        ok = subprocess.run([str(exe), 'ok'], capture_output=True, text=True, timeout=60)
        print(ok.stdout, end='')
        require(ok.returncode == 0, 'successful allocation: the block is filled, no sanitizer report')
        if ok.returncode:
            print(ok.stderr[-3000:])

print('PASS' if not failures else f'FAILED ({failures})')
sys.exit(1 if failures else 0)
