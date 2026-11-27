#!/usr/bin/env python3
"""Background processes leave the performance cores while the game presents
(build/ntdll-unix/server_ios.c [bg-qos]); no Wine runs.

Compiles the production ios_bg_game_note, ios_bg_qos_init, ios_bg_qos_listed_self
and ios_bg_qos_check against a fake TEB/PEB (ClientId, ImagePathName), a fake
clock and a recording pthread_set_qos_class_self_np, and checks per thread:
  - before any game presents nothing is touched;
  - while the game presents, threads of the listed processes (default:
    SocialClubHelper.exe, Launcher.exe, RockstarService.exe, dockhost.exe; any
    case, any directory) go to utility once, other processes and the game's own
    threads never do, even if the game is on the list;
  - not before the game has presented for MADEIRA_BG_QOS_DELAY_S (default 60 s,
    its sign-in minute), counted again after a pause;
  - 2 s after the last present they return to user-interactive, once;
  - a refused QoS change leaves the thread alone for good;
  - MADEIRA_BG_QOS_PROCS picks the list and an empty value turns it off;
and textually that every server call checks, the [xp] sampler notes the game
only from a presenting (role P) thread that ran, reading ClientId.UniqueProcess.
Needs python3 and a C compiler with pthreads (CC, default cc).
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/server_ios.c').read_text()

start = src.index('#define IOS_BG_QOS_HOLD_NS')
end = src.index('/* madeira-bcd: [xp-t] shows a native thread (no TEB) as m<thread id> only,')
code = src[start:end]

harness = r'''
#define _GNU_SOURCE
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
typedef uint16_t WCHAR;
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { UNICODE_STRING ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { RTL_USER_PROCESS_PARAMETERS *ProcessParameters; } PEB;
typedef struct { void *UniqueProcess, *UniqueThread; } CLIENT_ID;
typedef struct { PEB *Peb; CLIENT_ID ClientId; } TEB;
#define HandleToULong(h) ((unsigned long)(uintptr_t)(h))
#ifdef __APPLE__
/* Darwin declares the real hook and QoS classes: rename what the code calls
   and use the system's class values (the same 0x21 / 0x11) */
#define pthread_set_qos_class_self_np model_set_qos_class_self
#else
enum { QOS_CLASS_USER_INTERACTIVE = 0x21, QOS_CLASS_UTILITY = 0x11 };
#endif
static __thread TEB *cur_teb;
static TEB *NtCurrentTeb( void ) { return cur_teb; }
static uint64_t fake_ns = 5000000000ull;
static int fake_clock_gettime( int c, struct timespec *ts ) { (void)c; ts->tv_sec = fake_ns / 1000000000ull; ts->tv_nsec = fake_ns % 1000000000ull; return 0; }
#define clock_gettime fake_clock_gettime
static __thread int qos_now = QOS_CLASS_USER_INTERACTIVE, qos_calls, refuse;
static int pthread_set_qos_class_self_np( int q, int rel ) { (void)rel; if (refuse) return 1; qos_calls++; qos_now = q; return 0; }
static int lines;
static void wine_log_write( const char *fmt, ... ) { va_list ap; va_start( ap, fmt ); vfprintf( stderr, fmt, ap ); va_end( ap ); fputc( '\n', stderr ); lines++; }
''' + code + r'''
static int fails;
#define CHECK(c) do { if (!(c)) { fprintf( stderr, "FAIL line %d: %s\n", __LINE__, #c ); fails++; } } while (0)
struct job { const char *exe; unsigned pid; int refuse; int expect_listed; int game; int result; };
static void make_teb( TEB *teb, PEB *peb, RTL_USER_PROCESS_PARAMETERS *pp, WCHAR *buf, const char *exe, unsigned pid )
{
    size_t i, n = strlen( exe );
    for (i = 0; i < n; i++) buf[i] = (unsigned char)exe[i];
    pp->ImagePathName.Buffer = buf; pp->ImagePathName.Length = pp->ImagePathName.MaximumLength = n * 2;
    peb->ProcessParameters = pp; teb->Peb = peb;
    teb->ClientId.UniqueProcess = (void *)(uintptr_t)pid; teb->ClientId.UniqueThread = (void *)(uintptr_t)(pid + 4);
}
static void *worker( void *arg )
{
    struct job *j = arg;
    TEB teb; PEB peb; RTL_USER_PROCESS_PARAMETERS pp; WCHAR buf[256];
    make_teb( &teb, &peb, &pp, buf, j->exe, j->pid );
    cur_teb = &teb; refuse = j->refuse;
    /* a phase per step, driven by the main thread through fake_ns / the note */
    ios_bg_qos_check();                                   /* the game presents (main noted it) */
    j->result = qos_now * 1000 + qos_calls;
    ios_bg_qos_check();                                   /* again: no second change */
    if (qos_calls > 1) j->result = -1;
    return NULL;
}
static int run( struct job *j )
{
    pthread_t t; pthread_create( &t, NULL, worker, j ); pthread_join( t, NULL ); return j->result;
}
static void *later( void *arg )   /* a demoted thread after the game stopped */
{
    struct job *j = arg;
    TEB teb; PEB peb; RTL_USER_PROCESS_PARAMETERS pp; WCHAR buf[256];
    make_teb( &teb, &peb, &pp, buf, j->exe, j->pid );
    cur_teb = &teb;
    ios_bg_qos_check();
    CHECK( qos_now == QOS_CLASS_UTILITY && qos_calls == 1 );
    fake_ns += 1000000000ull;                             /* 1 s after the last present: still utility */
    ios_bg_qos_check();
    CHECK( qos_now == QOS_CLASS_UTILITY && qos_calls == 1 );
    fake_ns += 1500000000ull;                             /* 2.5 s: back */
    ios_bg_qos_check();
    CHECK( qos_now == QOS_CLASS_USER_INTERACTIVE && qos_calls == 2 );
    ios_bg_qos_check();
    CHECK( qos_calls == 2 );
    ios_bg_game_note( 0x3f4, 0x470 );                     /* the game presents again */
    ios_bg_qos_check();
    CHECK( qos_now == QOS_CLASS_UTILITY && qos_calls == 3 );
    return NULL;
}
static void present_for( uint64_t seconds )   /* the sampler notes the game every 250 ms */
{
    uint64_t i;
    for (i = 0; i < seconds * 4; i++) { fake_ns += 250000000ull; ios_bg_game_note( 0x3f4, 0x470 ); }
}
static void *delay_thread( void *arg )   /* default MADEIRA_BG_QOS_DELAY_S: 60 s of presents first */
{
    TEB teb; PEB peb; RTL_USER_PROCESS_PARAMETERS pp; WCHAR buf[256];
    (void)arg;
    make_teb( &teb, &peb, &pp, buf, "C:\\x\\SocialClubHelper.exe", 0x1ec );
    cur_teb = &teb;
    ios_bg_game_note( 0x3f4, 0x470 );                     /* the game's first present */
    ios_bg_qos_check();
    CHECK( qos_calls == 0 );
    present_for( 59 );
    ios_bg_qos_check();
    CHECK( qos_calls == 0 );                              /* 59 s: still the start-up minute */
    present_for( 1 );
    ios_bg_qos_check();
    CHECK( qos_now == QOS_CLASS_UTILITY && qos_calls == 1 );   /* 60 s */
    fake_ns += 3000000000ull;                             /* the game stops presenting */
    ios_bg_qos_check();
    CHECK( qos_now == QOS_CLASS_USER_INTERACTIVE && qos_calls == 2 );
    present_for( 30 );                                    /* presents again: a new minute */
    ios_bg_qos_check();
    CHECK( qos_calls == 2 );
    present_for( 31 );
    ios_bg_qos_check();
    CHECK( qos_now == QOS_CLASS_UTILITY && qos_calls == 3 );
    return NULL;
}
int main( int argc, char **argv )
{
    struct job before = { "C:\\Program Files\\Rockstar Games\\Social Club\\SocialClubHelper.exe", 0x1ec, 0, 1, 0, 0 };
    /* nothing presents yet */
    CHECK( run( &before ) == QOS_CLASS_USER_INTERACTIVE * 1000 );
    if (argc > 1 && !strcmp( argv[1], "delay" ))
    {
        pthread_t t;
        pthread_create( &t, NULL, delay_thread, NULL ); pthread_join( t, NULL );
        if (!fails) puts( "PASS: default delay: demoted only after 60 s of presents, again after a pause" );
        return fails != 0;
    }
    ios_bg_game_note( 0x3f4, 0x470 );
    if (argc > 1)   /* MADEIRA_BG_QOS_PROCS set by the caller */
    {
        struct job sch = { "C:\\x\\SocialClubHelper.exe", 0x1ec, 0, 0, 0, 0 };
        struct job other = { "C:\\x\\Other.exe", 0x50, 0, 0, 0, 0 };
        int r1 = run( &sch ), r2 = run( &other );
        printf( "%d %d\n", r1, r2 );
        return fails != 0;
    }
    {
        struct job sch = { "C:\\Program Files\\Rockstar Games\\Social Club\\SocialClubHelper.exe", 0x1ec, 0, 1, 0, 0 };
        struct job launcher = { "c:\\program files\\rockstar games\\launcher\\LAUNCHER.EXE", 0x34, 0, 1, 0, 0 };
        struct job service = { "C:/Program Files/Rockstar Games/Launcher/RockstarService.exe", 0xc8, 0, 1, 0, 0 };
        struct job dock = { "C:\\madeira\\dockhost.exe", 0x34 + 0x100, 0, 1, 0, 0 };
        struct job game = { "C:\\steam\\GTA5_Enhanced.exe", 0x3f4, 0, 0, 1, 0 };
        struct job prefix = { "C:\\x\\MyLauncher.exe", 0x60, 0, 0, 0, 0 };
        struct job refused = { "C:\\x\\Launcher.exe", 0x64, 1, 1, 0, 0 };
        CHECK( run( &sch ) == QOS_CLASS_UTILITY * 1000 + 1 );
        CHECK( run( &launcher ) == QOS_CLASS_UTILITY * 1000 + 1 );
        CHECK( run( &service ) == QOS_CLASS_UTILITY * 1000 + 1 );
        CHECK( run( &dock ) == QOS_CLASS_UTILITY * 1000 + 1 );
        CHECK( run( &game ) == QOS_CLASS_USER_INTERACTIVE * 1000 );
        CHECK( run( &prefix ) == QOS_CLASS_USER_INTERACTIVE * 1000 );
        CHECK( run( &refused ) == QOS_CLASS_USER_INTERACTIVE * 1000 );
        {
            pthread_t t; struct job j = { "C:\\x\\SocialClubHelper.exe", 0x1ec, 0, 1, 0, 0 };
            pthread_create( &t, NULL, later, &j ); pthread_join( t, NULL );
        }
        /* the game itself on the list: its own threads stay */
        {
            struct job self = { "C:\\x\\Launcher.exe", 0x3f4, 0, 1, 1, 0 };
            CHECK( run( &self ) == QOS_CLASS_USER_INTERACTIVE * 1000 );
        }
    }
    if (!fails) puts( "PASS: listed processes go to utility while the game presents and come back 2 s after it stops; "
                      "the game, other processes, refusals and threads before any present are untouched" );
    return fails != 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'bgqos.c'
    c.write_text(harness)
    exe = Path(tmp) / 'bgqos'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function', '-pthread',
                    str(c), '-o', str(exe)], check=True)
    base = dict(os.environ)
    base.pop('MADEIRA_BG_QOS_PROCS', None)
    base.pop('MADEIRA_BG_QOS_DELAY_S', None)
    out = subprocess.run([str(exe), 'delay'], capture_output=True, text=True, env=base)
    print(out.stdout.strip() or out.stderr.strip())
    assert out.returncode == 0, out.stderr
    assert 'once it has presented for 60 s' in out.stderr
    base['MADEIRA_BG_QOS_DELAY_S'] = '0'
    out = subprocess.run([str(exe)], capture_output=True, text=True, env=base)
    print(out.stdout.strip() or out.stderr.strip())
    assert out.returncode == 0, out.stderr
    assert '[bg-qos] the game is process 03f4 (presenting thread 0470)' in out.stderr
    for value, want in (('', '33000 33000'), ('Other.exe', '33000 17001'), ('socialclubhelper.exe;other.exe', '17001 17001')):
        out = subprocess.run([str(exe), 'env'], capture_output=True, text=True, env=dict(base, MADEIRA_BG_QOS_PROCS=value))
        assert out.returncode == 0, out.stderr
        assert out.stdout.split() == want.split(), (value, out.stdout)
        print(f'PASS: MADEIRA_BG_QOS_PROCS={value!r}: SocialClubHelper.exe / Other.exe -> {want}')

# --- textual wiring -----------------------------------------------------------
call = src[src.index('unsigned int server_call_unlocked( void *req_ptr )'):]
call = call[:call.index('\n}\n')]
assert call.index('ios_bg_qos_check();') < call.index('send_request( req )'), 'every server call checks first'
sampler = src[src.index("if (r->role && strchr( r->role, 'P' ) && teb && pt + et >= 1.0)"):][:400]
assert 'ios_ts_read( teb + 0x40, &gp, 4 );' in sampler and 'ios_bg_game_note( gp, w );' in sampler
print('PASS: every server call checks; the game is noted only from its presenting thread, by ClientId.UniqueProcess')
