#!/usr/bin/env python3
"""A pseudo-process child gets a desktop window like the session; no Wine runs.

Compiles get_desktop_window and its iOS helpers from
build/win32u-unix/winstation_ios.c against a model of the wineserver
(window classes are per process; the desktop window is created by the
process that asks with force=1 and needs the desktop class in THAT process;
a thread without a desktop gets nothing) and checks:
  - the session process (the one that ran init_user) behaves exactly as
    before: one request, no class registration, no winstation_init;
  - a child whose launcher never opened a window (GTA V Enhanced:
    "top_window stays 0" on the game thread) registers the desktop/message
    classes once for its pid+PEB and gets the desktop window on the retry;
  - a child whose thread has no desktop at all is connected with
    winstation_init and asked once more;
  - once a desktop window exists, a child gets it without registering;
  - a child the fixup cannot help gets one attempt, then the old single
    request per call;
  - MADEIRA_CHILD_DESKTOP=0 and a not-yet-initialised session keep the old
    behaviour.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
win = (root / 'build/win32u-unix/winstation_ios.c').read_text()
cls = (root / 'build/win32u-unix/class_ios.c').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


# The session PEB is published at the very end of init_user, after the
# session's own winstation_init and register_desktop_class.
init_user = function(cls, 'static void init_user(void)')
assert init_user.index('winstation_init();') < init_user.index('register_desktop_class();') \
    < init_user.index('ios_win32u_session_peb'), 'the session PEB must be published last'

gdw = function(win, 'HWND get_desktop_window(void)')
# Drop the upstream explorer block (#if 0 ... #endif): it is compiled out anyway.
gdw = re.sub(r'#if 0  /\* upstream explorer.exe launch path.*?#endif  /\* upstream explorer.exe launch path \*/\n',
             '', gdw, flags=re.S)

code = r'''
#include <assert.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define WINE_IOS 1
typedef int BOOL; typedef unsigned int UINT, DWORD; typedef void *HDESK, *HWND;
#define TRUE 1
#define FALSE 0
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define UlongToHandle(x) ((void *)(unsigned long)(x))
#define HandleToULong(h) ((DWORD)(unsigned long)(h))
#define ERR_(ch) err_print
static void err_print( const char *fmt, ... )
{ va_list ap; va_start( ap, fmt ); vfprintf( stderr, fmt, ap ); va_end( ap ); }
struct ntuser_thread_info { UINT top_window, msg_window; };
struct teb { struct { void *UniqueProcess; } ClientId; void *Peb; };

/* ---- the world: two "processes" sharing one desktop object ---- */
static struct teb cur_teb; static DWORD cur_tid;
static struct ntuser_thread_info thread_infos[8]; static int cur_thread;
static int thread_desktop[8];            /* desktop object id of each thread (0 = none) */
static int class_registered[0x100];      /* desktop class per pid */
static int desktop_top[4], desktop_msg[4];
static int requests, registrations, winstation_inits, set_desktop_calls, server_refuses;
static struct teb *NtCurrentTeb(void) { return &cur_teb; }
static struct ntuser_thread_info *NtUserGetThreadInfo(void) { return &thread_infos[cur_thread]; }
static DWORD GetCurrentThreadId(void) { return cur_tid; }
static BOOL is_service_process(void) { return TRUE; }
static HDESK NtUserGetThreadDesktop( DWORD tid ) { (void)tid; return (HDESK)(long)thread_desktop[cur_thread]; }
static void register_desktop_class(void) { registrations++; class_registered[HandleToULong( cur_teb.ClientId.UniqueProcess )] = 1; }
static void winstation_init(void) { winstation_inits++; if (!thread_desktop[cur_thread]) thread_desktop[cur_thread] = 1; }
static void register_builtin_classes(void) { }
static struct { void (*pSetDesktopWindow)(HWND); } driver, *user_driver = &driver;
static void set_desktop( HWND h ) { (void)h; set_desktop_calls++; }

/* server model of DECL_HANDLER(get_desktop_window) */
static struct { int force; } *g_req; static struct { UINT top_window, msg_window; } *g_reply;
#define SERVER_START_REQ(type) do { struct { int force; } req_, *req = &req_; \
    struct { UINT top_window, msg_window; } reply_, *reply = &reply_; g_req = (void *)req; g_reply = (void *)reply; \
    memset( reply, 0, sizeof(*reply) );
#define SERVER_END_REQ } while (0)
static unsigned int wine_server_call( void *req )
{
    int d = thread_desktop[cur_thread];
    (void)req; requests++;
    if (!d || server_refuses) return 0xc0000008;                 /* no desktop: STATUS_INVALID_HANDLE */
    if (!desktop_top[d] && g_req->force)
    {
        if (!class_registered[HandleToULong( cur_teb.ClientId.UniqueProcess )]) return 0xc0000008;
        desktop_top[d] = 0x10020; desktop_msg[d] = 0x10022;     /* created, then detached */
    }
    g_reply->top_window = desktop_top[d]; g_reply->msg_window = desktop_msg[d];
    return 0;
}
void *ios_win32u_session_peb;
'''
start = win.index('#ifdef WINE_IOS\n/* The process whose thread ran init_user')
end = win.index('HWND get_desktop_window(void)')
code += win[start:end].replace('extern void *ios_win32u_session_peb;', '')
code += gdw
code += r'''
static void become( int pid, void *peb, int thread, DWORD tid )
{ cur_teb.ClientId.UniqueProcess = (void *)(long)pid; cur_teb.Peb = peb; cur_thread = thread; cur_tid = tid; }

int main( int argc, char **argv )
{
    const int on = argc > 1 && !strcmp( argv[1], "on" );
    void *session = (void *)0x71ffff0000, *child = (void *)0x10592c000;
    driver.pSetDesktopWindow = set_desktop;
    thread_desktop[0] = thread_desktop[1] = thread_desktop[2] = 1;   /* inherited desktop object 1 */
    class_registered[0x20] = 1;                                      /* the session's init_user */

    /* Before init_user has finished nothing may change, even in a child. */
    become( 0x28, child, 1, 0x34 );
    assert( !get_desktop_window() && requests == 1 && !registrations );

    ios_win32u_session_peb = session;
    /* Session asking first would just work: one request, nothing else. */

    /* GTA: the launcher never opened a window, the game child asks. */
    requests = 0; thread_infos[1].top_window = 0;
    HWND h = get_desktop_window();
    if (!on)
    {
        assert( !h && requests == 1 && !registrations && !winstation_inits );
        puts( "PASS (MADEIRA_CHILD_DESKTOP=0): the child keeps no desktop window, as before" );
        return 0;
    }
    assert( h == (HWND)0x10020 && thread_infos[1].msg_window == 0x10022 );
    assert( requests == 2 && registrations == 1 && !winstation_inits && set_desktop_calls == 1 );

    /* A second thread of the same child: the window exists now, no more work. */
    requests = 0; become( 0x28, child, 2, 0x38 );
    assert( get_desktop_window() == (HWND)0x10020 && requests == 1 && registrations == 1 );

    /* The session asks afterwards: one request, nothing registered. */
    requests = 0; become( 0x20, session, 0, 0x24 );
    assert( get_desktop_window() == (HWND)0x10020 && requests == 1 && registrations == 1 );

    /* A child thread with no desktop at all: connected with winstation_init. */
    desktop_top[1] = desktop_msg[1] = 0;
    requests = 0; become( 0x40, (void *)0x11c59c000, 3, 0x3c ); thread_desktop[3] = 0;
    assert( get_desktop_window() == (HWND)0x10020 && winstation_inits == 1 && registrations == 2 && requests == 3 );

    /* The session's own failures never take the child path. */
    desktop_top[1] = 0; class_registered[0x20] = 0; requests = 0;
    become( 0x20, session, 4, 0x44 ); thread_desktop[4] = 1;
    assert( !get_desktop_window() && requests == 1 && registrations == 2 && winstation_inits == 1 );
    /* A child the fixup cannot help: one attempt, then the old single request. */
    server_refuses = 1; requests = 0;
    become( 0x50, (void *)0x120000000, 5, 0x54 ); thread_desktop[5] = 1;
    assert( !get_desktop_window() && requests == 2 && registrations == 3 );
    requests = 0;
    assert( !get_desktop_window() && requests == 1 && registrations == 3 && winstation_inits == 1 );
    puts( "PASS (default): a child registers the desktop classes once, a desktop-less thread is connected, "
          "the session is untouched" );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-child-desktop-') as directory:
    folder = Path(directory)
    source = folder / 'check.c'
    source.write_text(code)
    executable = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Wno-unused-function', '-Wno-unused-parameter',
             '-Wno-unused-variable', '-Werror', '-g', '-pthread', str(source), '-o', str(executable)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    if subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True).returncode == 0:
        print('built with AddressSanitizer/UBSan')
    else:
        subprocess.run(flags, check=True)
        print('built without sanitizers')
    for value, mode in [(None, 'on'), ('1', 'on'), ('', 'on'), ('0', 'off')]:
        env = dict(os.environ)
        env.pop('MADEIRA_CHILD_DESKTOP', None)
        if value is not None:
            env['MADEIRA_CHILD_DESKTOP'] = value
        result = subprocess.run([str(executable), mode], env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        print(f'MADEIRA_CHILD_DESKTOP={value!r}: {result.stdout.strip()}')
        lines = [l for l in result.stderr.splitlines() if '[child-desktop]' in l]
        if mode == 'on':
            assert len(lines) == 3, result.stderr
            assert 'registered the desktop/message classes' in lines[0] and 'top_window=0x10020' in lines[0], lines[0]
            assert 'winstation_init gave it' in lines[1] and 'top_window=0x10020' in lines[1], lines[1]
        else:
            assert not lines, result.stderr
print('PASS: child pseudo-processes get the desktop window the session gets; the session path is unchanged')
