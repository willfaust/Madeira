#!/usr/bin/env python3
"""ml1500 per-program thread scheduling class (ntdll signal_arm64_ios.c); no Wine runs.

Compiles the production ios_qos_listed / ios_apply_program_qos against minimal TEB/PEB stubs and
a recording pthread_set_qos_class_self_np, then checks the classes chosen for listed and unlisted
programs, the rollback, and that the hook sits before PE entry.
"""
from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/signal_arm64_ios.c").read_text()
a = src.index("static int ios_qos_listed( const char *list, const WCHAR *name, size_t len )")
b = src.index("void init_syscall_frame( LPTHREAD_START_ROUTINE entry")
helpers = src[a:b]
harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
typedef unsigned short WCHAR;
typedef enum { QOS_CLASS_USER_INTERACTIVE = 0x21, QOS_CLASS_DEFAULT = 0x15, QOS_CLASS_UTILITY = 0x11, QOS_CLASS_BACKGROUND = 0x09 } qos_class_t;
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { UNICODE_STRING ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { RTL_USER_PROCESS_PARAMETERS *ProcessParameters; } PEB;
typedef struct { void *UniqueProcess, *UniqueThread; } CLIENT_ID;
typedef struct { CLIENT_ID ClientId; PEB *Peb; } TEB;
#define HandleToULong(h) ((unsigned long)(uintptr_t)(h))
static qos_class_t last = 0; static int calls = 0;
static int pthread_set_qos_class_self_np( qos_class_t c, int p ) { (void)p; last = c; calls++; return 0; }
static TEB *current_teb; static TEB *NtCurrentTeb( void ) { return current_teb; }
static const char *debugstr_wn( const WCHAR *s, size_t n ) { static char b[64]; size_t i; for (i = 0; i < n && i < 63; i++) b[i] = (char)s[i]; b[i] = 0; return b; }
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
typedef void *HANDLE; typedef long NTSTATUS;
#define NtCurrentProcess() ((HANDLE)~(uintptr_t)0)
static int term_calls; static HANDLE term_handles[4];
static NTSTATUS NtTerminateProcess( HANDLE h, long code ) { (void)code; term_handles[term_calls++ & 3] = h; return 0; }
static int reclaim_calls, reclaim_left = 2;
int ios_wow_reclaim_settled( void ) { reclaim_calls++; return reclaim_left > 0 ? --reclaim_left : 0; }
""" + helpers + r"""
static WCHAR buf[128];
static TEB make( const char *path ) {
    static RTL_USER_PROCESS_PARAMETERS pp; static PEB peb; TEB t;
    size_t n = strlen( path ), i; for (i = 0; i < n; i++) buf[i] = (WCHAR)path[i];
    pp.ImagePathName.Buffer = buf; pp.ImagePathName.Length = (unsigned short)(n * 2);
    peb.ProcessParameters = &pp; t.Peb = &peb; t.ClientId.UniqueThread = (void *)0x94; return t;
}
#define CHECK(c, m) do { if (!(c)) { printf( "FAIL: %s\n", m ); return 1; } } while (0)
static void as( TEB *t ) { current_teb = t; pthread_setspecific( ios_park_key, NULL ); }  /* a different guest thread */
static TEB freeze_teb; static volatile int freeze_released;
static void *freeze_run( void *arg ) {   /* a listed thread of its own (pthread keys are per thread) */
    (void)arg; current_teb = &freeze_teb; ios_park_check(); freeze_released = 1; return NULL;
}
static int park_tests( const char *mode ) {
    static WCHAR hp[] = { 'C',':','/','x','/','H','e','l','p','e','r','.','e','x','e' };
    static WCHAR gp[] = { 'C',':','/','x','/','g','a','m','e','.','e','x','e' };
    TEB h1 = make( "C:/Launcher/helper.exe" ), h2, g, o;
    h1.ClientId.UniqueProcess = (void *)0x50; h2 = h1; h2.ClientId.UniqueThread = (void *)0x98;
    if (!strcmp( mode, "parkoff" )) {
        madeira_set_background_qos( 1 ); as( &h1 ); ios_park_check();
        CHECK( term_calls == 0 && !ios_park_refuse( hp, 15 ), "MADEIRA_PARK=0: nothing ends, nothing refused" );
        printf( "PASS: MADEIRA_PARK=0 keeps the helper\n" ); return 0;
    }
    CHECK( !ios_park_refuse( hp, 15 ), "not armed: a listed program may start" );
    as( &h1 ); ios_park_check(); CHECK( term_calls == 0, "not armed: nothing ends" );
    madeira_set_background_qos( 1 );
    CHECK( ios_park_refuse( hp, 15 ) && !ios_park_refuse( gp, 13 ), "armed: only the listed program is refused (case-insensitive)" );
    if (!strcmp( mode, "freeze" )) {   /* ml1790: held at the wait until the session ends */
        pthread_t th;
        freeze_teb = h1; pthread_create( &th, NULL, freeze_run, NULL );
        usleep( 600000 ); CHECK( !freeze_released && term_calls == 0, "freeze: the listed thread is held, nothing ends" );
        as( &h2 ); { TEB gg = make( "C:/x/game.exe" ); gg.ClientId.UniqueProcess = (void *)0x60; as( &gg ); ios_park_check(); }
        CHECK( term_calls == 0, "freeze: the game passes its wait" );
        CHECK( madeira_park_frozen() == 1, "freeze: the front end sees one held thread" );
        if (!strcmp( getenv( "THAW" ) ? getenv( "THAW" ) : "", "1" )) {   /* ml1800: the watchdog */
            madeira_park_thaw(); pthread_join( th, NULL );
            CHECK( freeze_released && madeira_park_frozen() == 0, "thaw: the held thread goes on" );
            freeze_released = 0; pthread_create( &th, NULL, freeze_run, NULL ); pthread_join( th, NULL );
            CHECK( freeze_released && term_calls == 0, "thaw: no more freezing this session" );
            madeira_set_background_qos( 0 );
            printf( "PASS: the watchdog's thaw releases a frozen helper and stops further freezing\n" ); return 0;
        }
        madeira_set_background_qos( 0 ); pthread_join( th, NULL );
        CHECK( freeze_released && term_calls == 0, "freeze: released when the session ends, never ended" );
        printf( "PASS: a frozen helper is held at its wait, never ended, and released when the session ends\n" ); return 0;
    }
    if (!strcmp( mode, "delay" )) {
        as( &h1 ); ios_park_check(); CHECK( term_calls == 0, "inside the delay: nothing ends" );
        printf( "PASS: the delay holds the helper\n" ); return 0;
    }
    as( &h1 ); ios_park_check();
    CHECK( term_calls == 2 && term_handles[0] == 0 && term_handles[1] == NtCurrentProcess(), "listed thread ends its process like ExitProcess" );
    as( &h2 ); ios_park_check(); CHECK( term_calls == 2, "the process's other threads do not end it again" );
    g = make( "C:/x/game.exe" ); g.ClientId.UniqueProcess = (void *)0x60; as( &g ); ios_park_check();
    CHECK( term_calls == 2 && reclaim_calls == 0, "the game is untouched" );
    o = make( "C:/Launcher/client.exe" ); o.ClientId.UniqueProcess = (void *)0x40; as( &o ); ios_park_check();
    CHECK( reclaim_calls == 0, "owner: reclaim waits 2 s after the end" );
    sleep( 3 ); ios_park_check(); CHECK( reclaim_calls == 1, "owner: window still waiting after the first try" );
    ios_park_check(); CHECK( reclaim_calls == 1, "owner: at most every 2 s" );
    sleep( 3 ); ios_park_check(); CHECK( reclaim_calls == 2, "owner: second try gives it back" );
    sleep( 3 ); ios_park_check(); CHECK( reclaim_calls == 2, "owner: nothing left, no more tries" );
    madeira_set_background_qos( 0 ); CHECK( !ios_park_refuse( hp, 15 ), "session over: may start again" );
    printf( "PASS: a parked helper ends once after the delay, is refused while the game runs, and its window is given back\n" );
    return 0;
}
int main( int argc, char **argv ) {
    TEB t;
    if (argc > 2) return park_tests( argv[2] );
    if (argc > 1 && !strcmp( argv[1], "bg" )) {   /* ml1530: background class */
        t = make( "C:/x/Web.EXE" ); ios_apply_program_qos( &t, 1 );
        CHECK( calls == 1 && last == QOS_CLASS_BACKGROUND, "background list -> background (before utility)" );
        t = make( "C:/x/other.exe" ); ios_apply_program_qos( &t, 1 );
        CHECK( calls == 2 && last == QOS_CLASS_UTILITY, "utility list still applies" );
        printf( "PASS: a background-listed helper gets the lowest class\n" ); return 0;
    }
    if (argc > 1) {   /* rollback run */
        t = make( "C:\\Program Files (x86)\\Launcher\\bin\\helper.exe" ); ios_apply_program_qos( &t, 1 );
        CHECK( calls == 0, "switch off: no class change" );
        printf( "PASS: rollback leaves every thread interactive\n" ); return 0;
    }
    t = make( "C:\\Program Files (x86)\\Launcher\\bin\\Helper.EXE" ); ios_apply_program_qos( &t, 1 );
    CHECK( calls == 1 && last == QOS_CLASS_UTILITY, "listed helper -> utility (case-insensitive)" );
    t = make( "C:\\Program Files (x86)\\Launcher\\client.exe" ); ios_apply_program_qos( &t, 1 );
    CHECK( calls == 2 && last == QOS_CLASS_DEFAULT, "client -> default" );
    t = make( "C:\\Games\\Title\\game.exe" ); ios_apply_program_qos( &t, 1 );
    CHECK( calls == 2, "unlisted game keeps interactive (no call)" );
    t = make( "C:\\Games\\Title\\helper.exe.bak" ); ios_apply_program_qos( &t, 1 );
    CHECK( calls == 2, "no prefix or substring matches" );
    t = make( "helper.exe" ); ios_apply_program_qos( &t, 1 );
    CHECK( calls == 3 && last == QOS_CLASS_UTILITY, "bare name" );
    TEB none = { { 0, 0 }, 0 }; ios_apply_program_qos( &none, 1 );
    CHECK( calls == 3, "no PEB: untouched" );
    t = make( "C:\\Launcher\\helper.exe" ); ios_apply_program_qos( &t, 0 );
    CHECK( calls == 4 && last == QOS_CLASS_USER_INTERACTIVE, "classes off: a listed thread returns to interactive" );
    /* ml1510: dynamic. Off at start, so a listed thread stays interactive until the switch. */
    calls = 0; t = make( "C:\\Launcher\\helper.exe" ); current_teb = &t;
    ios_qos_refresh_teb( &t ); CHECK( calls == 0, "classes off: nothing at thread start" );
    madeira_set_background_qos( 1 ); ios_qos_refresh(); CHECK( calls == 1 && last == QOS_CLASS_UTILITY, "switch on: moves at its next wait" );
    ios_qos_refresh(); CHECK( calls == 1, "no change: no call on later waits" );
    madeira_set_background_qos( 0 ); ios_qos_refresh(); CHECK( calls == 2 && last == QOS_CLASS_USER_INTERACTIVE, "switch off: back to interactive" );
    madeira_set_background_qos( 1 );
    TEB g = make( "C:\\Games\\game.exe" ); current_teb = &g; ios_qos_refresh();
    CHECK( calls == 2, "the game never changes class" );
    printf( "PASS: listed programs drop to utility/default, unlisted keep interactive, exact names only\n" );
    return 0;
}
"""
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "qos.c"; c.write_text(harness)
    exe = Path(t) / "qos"
    subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wno-unused-function", "-fsanitize=address,undefined", str(c), "-o", str(exe)], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
    env["MADEIRA_QOS_UTILITY_EXES"] = "other.exe;helper.exe"
    env["MADEIRA_QOS_DEFAULT_EXES"] = "client.exe"
    out = subprocess.run([str(exe)], env=env, capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    assert "[thread-qos] ml1500 tid=0094 image=Helper.EXE class=utility" in out.stderr, out.stderr
    out = subprocess.run([str(exe), "bg"], env=dict(env, MADEIRA_QOS_BACKGROUND_EXES="web.exe", MADEIRA_QOS_UTILITY_EXES="web.exe;other.exe"), capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    env["MADEIRA_THREAD_QOS"] = "0"
    out = subprocess.run([str(exe), "rollback"], env=env, capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    # ml1520: the park (helper ends while the game runs), its delay and its switch
    park = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
    park.update(MADEIRA_PARK_EXES="other.exe;helper.exe", MADEIRA_PARK_OWNER_EXES="client.exe", MADEIRA_PARK_DELAY_S="0")
    out = subprocess.run([str(exe), "x", "park"], env=park, capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    assert "[park] ml1520 ending helper.exe pid=0050" in out.stderr and "window returned" in out.stderr, out.stderr
    assert "[park] ml1520 refused restart #1 of Helper.exe" in out.stderr, out.stderr
    out = subprocess.run([str(exe), "x", "freeze"], env=dict(park, MADEIRA_PARK_MODE="freeze"), capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    assert "[park] ml1790 freezing thread #1" in out.stderr and "[park] ml1790 frozen threads released" in out.stderr, out.stderr
    out = subprocess.run([str(exe), "x", "freeze"], env=dict(park, MADEIRA_PARK_MODE="freeze", THAW="1"), capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    assert "[park] ml1800 thaw: 1 held thread(s) released" in out.stderr, out.stderr
    out = subprocess.run([str(exe), "x", "delay"], env=dict(park, MADEIRA_PARK_DELAY_S="30"), capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    out = subprocess.run([str(exe), "x", "parkoff"], env=dict(park, MADEIRA_PARK="0"), capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr

frame = src[src.index("void init_syscall_frame( LPTHREAD_START_ROUTINE entry"):]
assert frame.index("ios_qos_refresh_teb( teb );") < frame.index("before PE entry"), "applied before PE entry"
print("PASS: the class is applied on the thread itself, before it first enters PE code")
