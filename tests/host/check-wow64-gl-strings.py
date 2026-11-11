#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""patches/wine-opengl-winios.patch: a 32-bit program's GL strings stay in its own process.

Wine's opengl32 unix side caches the 32-bit copy of each GL string it hands to a WoW64 program
(return_wow64_string), keyed by the host string. On Linux that cache is per process; in Madeira every
pseudo-process shares the unix side, so the cached pointer belongs to the process that asked first and
is an address in that process's window (Far Cry 3's hardware detection was handed its exited updater's
copy of GL_EXTENSIONS). On iOS the patch copies into the caller's buffer every time, and opengl32.dll
keeps one copy per distinct string (intern_wow64_string).

Checks, with the patch applied to the wine checkout's dlls/opengl32/wgl.c and unix_wgl.c in a scratch
directory, and the real return_wow64_string, intern_wow64_string, glGetString and glGetStringi built
on the host (ASan/UBSan) against a model of two 32-bit processes with their own windows and heaps and
one shared unix side:
  - process A asks for GL_EXTENSIONS and GL_RENDERER and exits without opengl32's cleanup, as a
    process exit does;
  - process B, whose heap holds its own data at A's addresses, gets its own copies with the right
    text, and the same pointer when it asks again;
  - glGetStringi's strings are kept once each, so asking again does not grow the list;
  - without WINE_IOS (one process per unix side, as on Linux) the same model shows process B handed
    process A's address, so the model catches the old behaviour.
Needs python3, git and a host C compiler (cc).
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def function(source, signature):
    """The definition that starts with `signature`, up to its closing brace in column 0."""
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


PRELUDE = r'''
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef long NTSTATUS;
typedef unsigned int PTR32, GLenum, GLuint;
typedef unsigned char GLubyte;
typedef size_t SIZE_T;
typedef void TEB;
#define STATUS_SUCCESS          ((NTSTATUS)0)
#define STATUS_BUFFER_TOO_SMALL ((NTSTATUS)0xc0000023)
#define WINAPI
#define TRACE(...) do {} while (0)
#define WARN(...)  do {} while (0)
#define ERR(...)   fprintf( stderr, __VA_ARGS__ )

/* Two 32-bit processes, each with its own window (a guest address is an offset into it) and a heap there. */
#define WINDOW (1 << 20)
static unsigned char *window[2];
static size_t heap_top[2];
static int current;
static void *ios_wow_host_ptr( PTR32 p ) { return window[current] + p; }
#define UlongToPtr(u) ios_wow_host_ptr(u)
static PTR32 guest( const void *p ) { return p ? (PTR32)((const unsigned char *)p - window[current]) : 0; }
static void *guest_malloc( size_t n )
{
    void *p = window[current] + heap_top[current];
    heap_top[current] += (n + 15) & ~(size_t)15;
    return p;
}
static void guest_free( void *p ) { (void)p; }

/* The unix side: one copy for both processes, as in Madeira. */
static pthread_mutex_t wgl_lock = PTHREAD_MUTEX_INITIALIZER;
static const char *host_extensions = "GL_ARB_multitexture GL_EXT_texture_compression_s3tc GL_ARB_vertex_buffer_object";
static const char *host_renderer = "Apple GPU (Zink)";
static const char *host_indexed[3] = { "GL_ARB_multitexture", "GL_EXT_texture_compression_s3tc", "GL_ARB_vertex_buffer_object" };
'''

PE_PRELUDE = r'''
/* opengl32.dll, with its statics per process; its strings come from that process's heap. */
#define malloc guest_malloc
#define free guest_free
typedef struct { int unused; } CRITICAL_SECTION;
static void EnterCriticalSection( CRITICAL_SECTION *cs ) { (void)cs; }
static void LeaveCriticalSection( CRITICAL_SECTION *cs ) { (void)cs; }
static TEB *NtCurrentTeb( void ) { return NULL; }
static char **strings_of[2];
static SIZE_T strings_count_of[2];
#define wow64_strings strings_of[current]
#define wow64_strings_count strings_count_of[current]
static CRITICAL_SECTION wow64_cs;
struct glGetString_params { TEB *teb; GLenum name; const GLubyte *ret; };
struct glGetStringi_params { TEB *teb; GLenum name; GLuint index; const GLubyte *ret; };
static NTSTATUS to_unix( const char *host, const GLubyte **ret )
{
    PTR32 p = guest( *ret );
    NTSTATUS status = return_wow64_string( host, &p );
    *ret = status == STATUS_BUFFER_TOO_SMALL ? (const GLubyte *)(uintptr_t)p : p ? ios_wow_host_ptr( p ) : NULL;
    return status;
}
#define UNIX_CALL(func, args) unix_##func( args )
#define unix_glGetString(a) to_unix( (a)->name == 0x1f03 ? host_extensions : host_renderer, &(a)->ret )
#define unix_glGetStringi(a) to_unix( host_indexed[(a)->index], &(a)->ret )
'''

TAIL = r'''
static int run( int ios )
{
    const GLubyte *b_ext, *b_ext2, *b_ren, *b_idx[3], *b_idx2[3];
    PTR32 a_ext;
    int bad = 0, ok, i;

    for (i = 0; i < 2; i++) heap_top[i] = 0x10000;
    current = 0;   /* process A asks, then exits: DLL_PROCESS_DETACH with reserved != NULL frees nothing */
    a_ext = guest( glGetString( 0x1f03 ) );
    glGetString( 0x1f01 );
    current = 1;   /* process B: its own data where A's copies are */
    memset( window[1] + 0x10000, 'Z', 0x1000 );
    heap_top[1] = 0x11000;
    b_ext = glGetString( 0x1f03 );
    b_ext2 = glGetString( 0x1f03 );
    b_ren = glGetString( 0x1f01 );
    for (i = 0; i < 3; i++) b_idx[i] = glGetStringi( 0x1f03, i );
    for (i = 0; i < 3; i++) b_idx2[i] = glGetStringi( 0x1f03, i );

    if (!ios)
    {
        ok = guest( b_ext ) == a_ext && strcmp( (const char *)b_ext, host_extensions );
        printf( "%s: without WINE_IOS process B is handed process A's address 0x%x, which holds B's own data there "
                "(the old behaviour)\n", ok ? "PASS" : "FAIL", guest( b_ext ) );
        return !ok;
    }
    ok = b_ext && !strcmp( (const char *)b_ext, host_extensions ) && guest( b_ext ) >= 0x11000;
    printf( "%s: process B gets its own GL_EXTENSIONS copy (0x%x), with the right text\n", ok ? "PASS" : "FAIL", guest( b_ext ) );
    bad += !ok;
    ok = b_ren && !strcmp( (const char *)b_ren, host_renderer );
    printf( "%s: and its own GL_RENDERER\n", ok ? "PASS" : "FAIL" );
    bad += !ok;
    printf( "%s: asking again gives the same pointer\n", b_ext == b_ext2 ? "PASS" : "FAIL" );
    bad += b_ext != b_ext2;
    ok = 1;
    for (i = 0; i < 3; i++) ok &= b_idx[i] == b_idx2[i] && !strcmp( (const char *)b_idx[i], host_indexed[i] );
    printf( "%s: glGetStringi's strings are kept once each, with the right text\n", ok ? "PASS" : "FAIL" );
    bad += !ok;
    ok = strings_count_of[1] == 5;
    printf( "%s: process B keeps %d strings for 10 calls (2 + 3 distinct)\n", ok ? "PASS" : "FAIL", (int)strings_count_of[1] );
    bad += !ok;
    return bad;
}

int main( void )
{
    window[0] = calloc( 1, WINDOW );
    window[1] = calloc( 1, WINDOW );
    return run( IOS ) ? 1 : 0;
}
'''

wine = root / 'wine'
patch = root / 'patches/wine-opengl-winios.patch'
files = ['dlls/opengl32/wgl.c', 'dlls/opengl32/unix_wgl.c']
if not all((wine / f).is_file() for f in files):
    print('SKIP: wine not checked out; the model needs its opengl32 sources')
    sys.exit(0)
if not shutil.which('cc'):
    print('SKIP: no host C compiler (cc)')
    sys.exit(0)

work = Path(tempfile.mkdtemp(prefix='check-wow64-gl-strings-'))
try:
    for f in files:
        (work / f).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(wine / f, work / f)
    subprocess.run(['git', 'init', '-q'], cwd=work, check=True)
    applied = subprocess.run(['git', 'apply'] + [f'--include={f}' for f in files] + [str(patch)],
                             cwd=work, capture_output=True, text=True)
    require(applied.returncode == 0, 'the patch applies to wgl.c and unix_wgl.c of the checked-out wine')
    if applied.returncode:
        print(applied.stderr)
        sys.exit(1)
    wgl = (work / files[0]).read_text(encoding='utf-8')
    unix = (work / files[1]).read_text(encoding='utf-8')
    require('append_wow64_string' not in wgl and wgl.count('args.ret = intern_wow64_string(') == 6,
            "opengl32.dll's six string wrappers keep their copies through intern_wow64_string")
    pe = '\n'.join(function(wgl, s) for s in ('static void *intern_wow64_string( char *str )',
                                               'const GLubyte * WINAPI glGetStringi( GLenum name, GLuint index )',
                                               'const GLubyte * WINAPI glGetString( GLenum name )'))
    cache = unix[unix.index('struct wow64_string_entry\n'):unix.index('static SIZE_T wow64_strings_count;\n')]
    unix_part = cache + 'static SIZE_T wow64_strings_count;\n\n' + \
        function(unix, 'NTSTATUS return_wow64_string( const void *str, PTR32 *wow64_str )')

    for ios in (1, 0):
        name = 'WINE_IOS' if ios else 'without WINE_IOS'
        src = PRELUDE + ('#define WINE_IOS 1\n' if ios else '') + unix_part + PE_PRELUDE + pe + \
            TAIL.replace('run( IOS )', f'run( {ios} )')
        c, exe = work / f'model-{ios}.c', work / f'model-{ios}'
        c.write_text(src, encoding='utf-8')
        cc = subprocess.run(['cc', '-std=gnu11', '-g', '-O1', '-Wall', '-Wno-unused-function',
                             '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined',
                             str(c), '-o', str(exe), '-lpthread'], capture_output=True, text=True)
        require(cc.returncode == 0, f'the model builds ({name})')
        if cc.returncode:
            print(cc.stderr[-3000:])
            continue
        result = subprocess.run([str(exe)], capture_output=True, text=True)
        print(result.stdout, end='')
        if result.stderr.strip():
            print(result.stderr[-2000:])
        require(result.returncode == 0, f'the model passes ({name})')
finally:
    shutil.rmtree(work, ignore_errors=True)

print('PASS: all wow64 GL string checks' if not failures else f'FAILED: {failures} check(s)')
sys.exit(1 if failures else 0)
