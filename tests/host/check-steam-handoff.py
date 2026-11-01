#!/usr/bin/env python3
"""Execute the real Steam registry, server death hook, bridge wait and focus policy."""
from pathlib import Path
import importlib.util
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]


def function(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


bridge = (root / 'app/Madeira/WineProcessBridge.m').read_text()
driver = (root / 'build/win32u-unix/driver_ios.c').read_text()
spec = importlib.util.spec_from_file_location('steam_lifecycle', root / 'build/wineserver/stage-steam-lifecycle.py')
stager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stager)
original = (root / 'wine/server/process.c').read_text()
staged = stager.stage(original)
assert original != staged
assert staged.count('madeira_child_server_exited(process->id, process->exit_code)') == 1
try:
    stager.stage('/* wrong Wine version */')
except AssertionError:
    pass
else:
    raise AssertionError('changed process death entry must fail staging')

code = r'''
#define _DEFAULT_SOURCE
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
typedef uint16_t WCHAR;
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))

/* Actual staged Wine process_killed/remove_process_thread, with object cleanup
 * stubbed. In particular the boot pthread does not need to return for this. */
#define WINE_IOS 1
#define STARTUP_ABORTED 1
#define DbgExitProcessStateChange 1
#define DbgExitThreadStateChange 2
struct list { int count; struct list *head; };
struct process {
    unsigned id; int exit_code,running_threads,winstation,desktop,console;
    struct list thread_list,entry; long end_time; void *idle_event,*sync;
};
struct thread { struct list proc_entry; int exit_code; };
static const long current_time=123;
static int list_empty(struct list *list) { return !list->count; }
static void list_remove(struct list *list) { if(list->head) --list->head->count; }
static void release_object(void *p) { (void)p; }
static void signal_sync(void *p) { (void)p; }
static void generate_debug_event(struct thread *t,int type,void *p) { (void)t;(void)type;(void)p; }
#define CLEANUP(name) static void name(struct process *p) { (void)p; }
CLEANUP(close_process_desktop) CLEANUP(cancel_terminating_process_asyncs)
CLEANUP(close_process_handles) CLEANUP(destroy_process_classes) CLEANUP(free_mapped_views)
CLEANUP(free_process_user_handles) CLEANUP(remove_process_locks) CLEANUP(finish_process_tracing)
CLEANUP(release_job_process) CLEANUP(start_sigkill_timer)
static void set_process_startup_state(struct process *p,int state) { (void)p;(void)state; }
PROCESS_KILLED
REMOVE_PROCESS_THREAD

/* Define the native registry after the actual weak server import, as the
 * production linker does across translation units. */
#include "steam_handoff.h"
static void *const root_owner = (void *)(uintptr_t)0x100000;
static void *const owner_a = (void *)(uintptr_t)0x200000;
static void *const owner_b = (void *)(uintptr_t)0x300000;
static const char client[] = "C:\\Program Files (x86)\\Steam\\steam.exe";
static UNICODE_STRING wide(const char *name, WCHAR *buf) {
    size_t n = strlen(name); assert(n < 1024);
    for (size_t i=0; i<=n; ++i) buf[i]=(unsigned char)name[i];
    return (UNICODE_STRING){ (unsigned short)(n*2), (unsigned short)(n*2+2), buf };
}
static struct ios_child_token spawn(const char *name, unsigned pid, unsigned ppid, void *parent, void *owner) {
    WCHAR buf[1024], parent_buf[1024];
    const char *root_image=ios_steam_session.root_steam ? client : "C:\\windows\\system32\\explorer.exe";
    UNICODE_STRING image=wide(name,buf), parent_image=wide(root_image,parent_buf);
    struct ios_child_token token=ios_child_slot_take(&image,pid,ppid,parent,root_owner,&parent_image);
    ios_current_child=token; madeira_child_process_started(owner,pid); return token;
}
static unsigned leader(void) { unsigned pid=0; madeira_live_steam_successors(&pid); return pid; }
static void root_exit(int status) { madeira_child_process_exited(root_owner,0x20,status); }
static void begin(int enabled,int direct) { madeira_child_session_begin(enabled,direct); }
static void last_thread_exit(unsigned pid,int status) {
    struct process p={.id=pid,.exit_code=259,.running_threads=2,.thread_list={.count=2}};
    struct thread t={.proc_entry={.head=&p.thread_list},.exit_code=status};
    remove_process_thread(&p,&t); assert(p.running_threads==1);
    assert(madeira_live_steam_successors(NULL)>0); /* first thread isn't process death */
    remove_process_thread(&p,&t); assert(!p.running_threads && p.end_time==current_time);
}

static int server_running=1, wait_ticks, wait_mode;
static int wineserver_is_running(void) { return server_running; }
static int fake_usleep(unsigned usec) {
    assert(usec==200000); ++wait_ticks;
    if(wait_mode==1) {
        if(wait_ticks==1) spawn(client,0x304,0x2b4,owner_a,owner_b);
        if(wait_ticks==2) last_thread_exit(0x2b4,42);
        if(wait_ticks==3) last_thread_exit(0x304,0);
    } else if(wait_mode==2) server_running=0; /* explicit session exit */
    assert(wait_ticks<10); return 0;
}
#define usleep fake_usleep
BRIDGE_WAIT
#undef usleep

/* Actual driver handoff: Win32 window eligibility + process lineage. */
typedef unsigned DWORD,UINT;
typedef long long LONGLONG;
typedef int BOOL;
typedef void *HWND;
typedef struct { int left,top,right,bottom; } RECT;
#define FALSE 0
#define TRUE 1
#define WS_VISIBLE 1
#define WS_CHILD 2
#define WS_MINIMIZE 4
#define WS_DISABLED 8
#define WS_EX_NOACTIVATE 16
#define WS_EX_TOOLWINDOW 32
#define GWL_STYLE 0
#define GWL_EXSTYLE 1
#define GA_PARENT 1
struct window { unsigned pid,tid,style,exstyle; int visible,width,height,child; };
static struct window windows[8];
static unsigned window_count, current_pid, current_tid;
static HWND foreground;
static int activations,clicks,allow_activation=1;
static DWORD GetCurrentProcessId(void) { return current_pid; }
static DWORD GetCurrentThreadId(void) { return current_tid; }
static HWND NtUserGetForegroundWindow(void) { return foreground; }
static HWND get_desktop_window(void) { return (void *)(uintptr_t)1; }
static HWND NtUserGetAncestor(HWND h,int type) { (void)type; return ((struct window *)h)->child ? 0 : get_desktop_window(); }
static DWORD get_window_thread(HWND h,DWORD *pid) { struct window *w=h; if(!w->tid)return 0; if(pid)*pid=w->pid;return w->tid; }
static DWORD get_window_long(HWND h,int which) { struct window *w=h; return which==GWL_STYLE?w->style:w->exstyle; }
static int is_window_visible(HWND h) { return ((struct window *)h)->visible; }
static UINT get_thread_dpi(void) { return 96; }
static int get_window_rect(HWND h,RECT *r,UINT dpi) { struct window *w=h;(void)dpi;*r=(RECT){0,0,w->width,w->height};return 1; }
static HWND *list_window_children(HWND parent) {
    (void)parent; HWND *list=calloc(window_count+1,sizeof(HWND)); assert(list);
    for(unsigned i=0;i<window_count;++i) list[i]=&windows[i];
    return list;
}
static BOOL set_foreground_window(HWND h,BOOL mouse,BOOL force) {
    assert(!mouse && force); ++activations;if(allow_activation)foreground=h;return allow_activation;
}
static void winios_click_focus(HWND h,const char *why) { assert(h && !strcmp(why,"Steam restart"));++clicks; }
DRIVER_FOCUS
static struct ios_child_token setup_restart(void) {
    begin(1,1); struct ios_child_token token=spawn(client,0x2b4,0x20,root_owner,owner_a);
    spawn("C:\\Steam\\steamwebhelper.exe",0x2b8,0x2b4,owner_a,owner_b); root_exit(42);
    assert(leader()==0x2b4); assert(madeira_steam_focus_epoch(0x2b8));
    memset(windows,0,sizeof(windows)); window_count=1; current_pid=0x2b8; current_tid=7;
    windows[0]=(struct window){0x2b8,7,WS_VISIBLE,0,1,1056,486,0};
    foreground=NULL; activations=clicks=0; allow_activation=1;
    return token;
}

int main(void) {
    /* Real exit-42 handoff: helpers don't own the session; successor final
     * status replaces 42; no root TEB APIs run while the bridge waits. */
    begin(1,1);
    spawn("C:\\Steam\\steamwebhelper.exe",0x80,0x20,root_owner,owner_b);
    struct ios_child_token first=spawn(client,0x2b4,0x20,root_owner,owner_a);
    assert(madeira_live_steam_successors(NULL)==1 && leader()==0x20);
    root_exit(42); assert(leader()==0x2b4 && madeira_steam_final_status(1)==42);
    assert(madeira_steam_focus_epoch(0x2b4) && !madeira_steam_focus_epoch(0x80));
    assert(madeira_steam_focus_can_replace(0x80)); /* old client's visible browser */
    wait_mode=1;wait_ticks=0;server_running=1;
    assert(madeira_wait_steam_handoff(42)==0 && wait_ticks==3);
    assert(!madeira_live_steam_successors(NULL));
    assert(madeira_live_game_children(NULL,0,-1)==0); /* surviving webhelper excluded */
    ios_child_slot_release(first); /* old boot-thread return must be harmless */

    /* Exact same installed path is architecture independent (32 -> 64),
     * slash/case/NT prefix normalized; another steam.exe is not a successor. */
    begin(1,1); first=spawn("\\??\\c:/PROGRAM FILES (X86)/STEAM/STEAM.EXE",0x90,0x20,root_owner,owner_a);
    assert(madeira_live_steam_successors(NULL)==1);
    spawn("C:\\Other\\steam.exe",0x94,0x90,owner_a,owner_b);
    spawn(client,0x98,0x99,owner_b,owner_b); assert(madeira_live_steam_successors(NULL)==1);
    root_exit(42); last_thread_exit(0x90,7);assert(madeira_steam_final_status(0)==7);
    begin(1,1);spawn("C:\\Other\\steam.exe",0x94,0x20,root_owner,owner_b);
    assert(!madeira_live_steam_successors(NULL)); /* root's own image pins path */
    spawn(client,0x90,0x20,owner_b,owner_a);assert(!madeira_live_steam_successors(NULL)); /* wrong creator owner */
    spawn(client,0x98,0x20,root_owner,owner_a);assert(madeira_live_steam_successors(NULL)==1);

    /* No successor, startup failure, helpers only, and generic applications. */
    begin(1,1); spawn("C:\\Steam\\steamwebhelper.exe",0x80,0x20,root_owner,owner_b);
    root_exit(42);assert(!madeira_live_steam_successors(NULL));
    assert(madeira_wait_steam_handoff(42)==42);
    begin(1,1);first=spawn(client,0x90,0x20,root_owner,owner_a);ios_child_slot_release(first);
    root_exit(42);assert(!madeira_live_steam_successors(NULL));
    begin(0,0);spawn(client,0x90,0x20,root_owner,owner_a);
    assert(!madeira_live_steam_successors(NULL));assert(madeira_live_game_children(NULL,0,60)==1);

    /* Native Steam cmd/explorer wrapper exits; descendant client owns the
     * session. Its unrelated sibling service cannot grant that ownership. */
    begin(1,0);spawn("C:\\windows\\system32\\services.exe",0x40,0x20,root_owner,owner_a);
    spawn(client,0x44,0x40,owner_a,owner_b);assert(!madeira_live_steam_successors(NULL));
    first=spawn(client,0x90,0x20,root_owner,owner_a);root_exit(0);
    assert(madeira_live_steam_successors(NULL)==1 && leader()==0x90 && madeira_steam_focus_epoch(0x90));
    for(unsigned i=0;i<IOS_CHILD_SLOTS;++i) ios_child_slots[i].started-=3600;
    assert(madeira_live_steam_successors(NULL)==1 && !madeira_live_game_children(NULL,0,60));
    last_thread_exit(0x90,0);assert(!madeira_live_steam_successors(NULL));
    begin(1,0);spawn("C:\\windows\\system32\\cmd.exe",0x40,0x20,root_owner,owner_a);
    spawn(client,0x90,0x40,owner_a,owner_b);root_exit(0);
    assert(madeira_live_steam_successors(NULL)==1 && leader()==0x90);
    last_thread_exit(0x90,0);assert(!madeira_live_steam_successors(NULL));

    /* Server last-Windows-thread death retires exactly the active record,
     * including a worker exit with a still-blocked native boot pthread. */
    first=setup_restart();
    struct ios_child_token old=spawn(client,0x304,0x2b4,owner_a,owner_b);
    last_thread_exit(0x2b4,42); assert(leader()==0x304);
    struct ios_child_token reused=spawn("C:\\Steam\\steamwebhelper.exe",0x400,0x304,owner_b,owner_a);
    ios_child_slot_release(first); assert(ios_child_slots[reused.slot].used);
    madeira_child_process_exited(owner_a,0x304,99);assert(leader()==0x304); /* wrong owner */
    madeira_child_process_exited(owner_b,0x304,0);assert(!madeira_live_steam_successors(NULL));
    ios_child_slot_release(old);assert(madeira_steam_final_status(42)==0);
    /* A reused slot with the SAME PID but a new owner/generation survives a
     * late boot return or stale native exit from the previous generation. */
    begin(1,1);old=spawn(client,0x90,0x20,root_owner,owner_a);root_exit(42);
    madeira_child_server_exited(0x90,0);
    reused=spawn(client,0x90,0x20,root_owner,owner_b); /* dead root isn't trusted */
    assert(reused.slot==old.slot && reused.generation!=old.generation);
    ios_child_slot_release(old);madeira_child_process_exited(owner_a,0x90,99);
    assert(ios_child_slots[reused.slot].used);
    /* Session reset retains monotonic generations, so delayed old cleanup
     * cannot retire a new session's identically indexed and named client. */
    begin(1,1);reused=spawn(client,0x90,0x20,root_owner,owner_a);
    ios_child_slot_release(old);assert(ios_child_slots[reused.slot].used);

    /* Explicit user session/server stop breaks wait even if native threads
     * have not unwound; normal Steam Exit retires the final client above. */
    setup_restart();wait_mode=2;wait_ticks=0;server_running=1;
    assert(madeira_wait_steam_handoff(42)==42 && wait_ticks==1 && !server_running);

    /* Focus only a visible activation-eligible UI window on its own thread,
     * never fabricate ShowWindow or give a hidden helper focus. */
    setup_restart();windows[0].style=0;ios_steam_handoff_foreground();assert(!activations);
    windows[0].style=WS_VISIBLE;windows[0].visible=0;ios_steam_handoff_foreground();assert(!activations);
    windows[0].visible=1;
    const unsigned styles[]={WS_CHILD,WS_DISABLED,WS_MINIMIZE};
    for(unsigned i=0;i<ARRAY_SIZE(styles);++i) { windows[0].style=WS_VISIBLE|styles[i];ios_steam_handoff_foreground();assert(!activations); }
    windows[0].style=WS_VISIBLE;
    const unsigned extended[]={WS_EX_TOOLWINDOW,WS_EX_NOACTIVATE};
    for(unsigned i=0;i<ARRAY_SIZE(extended);++i) { windows[0].exstyle=extended[i];ios_steam_handoff_foreground();assert(!activations); }
    windows[0].exstyle=0;windows[0].child=1;ios_steam_handoff_foreground();assert(!activations);
    windows[0].child=0;windows[0].tid=8;ios_steam_handoff_foreground();assert(!activations);
    windows[0].tid=0;ios_steam_handoff_foreground();assert(!activations); /* destroyed handle: owner output unwritten */
    windows[0].tid=7;windows[0].width=319;ios_steam_handoff_foreground();assert(!activations);
    windows[0].width=1056;
    struct window unrelated={.pid=0x777,.tid=99,.style=WS_VISIBLE,.visible=1};
    foreground=&unrelated;ios_steam_handoff_foreground();assert(!activations);
    spawn("C:\\Steam\\steamapps\\common\\Counter-Strike Global Offensive\\game\\bin\\win64\\cs2.exe",0x730,0x2b4,owner_a,(void *)(uintptr_t)0x400000);
    unrelated.pid=0x730;ios_steam_handoff_foreground();assert(!activations && !madeira_steam_focus_epoch(0x730));
    foreground=NULL;windows[1]=windows[0];windows[1].exstyle=WS_EX_NOACTIVATE;windows[1].width=3000;window_count=2;
    allow_activation=0;ios_steam_handoff_foreground();assert(activations==1 && madeira_steam_focus_epoch(0x2b8));
    allow_activation=1;ios_steam_handoff_foreground();assert(activations==2 && foreground==&windows[0] && clicks==1);
    assert(!madeira_steam_focus_epoch(0x2b8));ios_steam_handoff_foreground();assert(activations==2);
    setup_restart();foreground=&windows[0];current_pid=0x2b4;
    ios_steam_handoff_foreground();assert(!activations && !madeira_steam_focus_epoch(0x2b4));

    puts("PASS native Steam exit-42/repeated restart, server worker death, ownership/generation reuse, wrappers, helper exclusion, explicit stop, final status and eligible visible-window focus");
}
'''
code = code.replace('PROCESS_KILLED', function(staged, 'static void process_killed( struct process *process )'))
code = code.replace('REMOVE_PROCESS_THREAD', function(original, 'void remove_process_thread( struct process *process, struct thread *thread )'))
code = code.replace('BRIDGE_WAIT', function(bridge, 'static int madeira_wait_steam_handoff(int initial_status)'))
code = code.replace('DRIVER_FOCUS', function(driver, 'static void ios_steam_handoff_foreground(void)\n{'))
with tempfile.TemporaryDirectory() as d:
    source, binary = Path(d) / 'handoff.c', Path(d) / 'handoff'
    source.write_text(code)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                    '-pthread', '-I'+str(root / 'build/ntdll-unix'), str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

# The bridge root remains the same native thread and session epoch: no root
# TEB/API use in the wait and no teardown until successor ownership finishes.
wait = function(bridge, 'static int madeira_wait_steam_handoff(int initial_status)')
assert 'NtCurrentTeb' not in wait and 'NtQuery' not in wait and 'setenv' not in wait
launch = bridge[bridge.index('const int steam_session = native_steam || steam_client;'):]
assert launch.index('madeira_child_session_begin(steam_session, steam_client)') < launch.index('__wine_main(argc, argv)')
assert launch.index('madeira_wait_steam_handoff') < launch.index('wine_launched_process_did_exit(session_status)')
assert launch.index('madeira_wait_steam_handoff') < launch.index('__atomic_store_n(&g_wine_exit_code, session_status')
assert launch.index('madeira_wait_steam_handoff') < launch.index('g_wine_running = 0') < launch.index('wineserver_stop()')
assert 'MADEIRA_WAIT_CHILDREN' not in wait
assert 'while (wineserver_is_running() && (n = madeira_live_game_children' in launch
assert 'ShowWindow' not in function(driver, 'static void ios_steam_handoff_foreground(void)\n{')
server = (root / 'build/ntdll-unix/server_ios.c').read_text()
death = function(server, 'void process_exit_wrapper( int status )')
assert death.index('madeira_child_process_exited(caller_peb') < death.index('ios_thread_process_exit_ready(caller_peb)')
loader = (root / 'build/ntdll-unix/loader_ios.c').read_text()
assert loader.index('server_init_process_child( child_fd_socket )') < loader.index('madeira_child_process_started(child_peb')
print('PASS bridge preserves UI/input/JIT/observer session through handoff; native/server hooks precede resource retirement; no forced visibility')

# Run the actual producer's nm check with Darwin-format positive/negative
# fixtures, so a cached process.o cannot silently ship without the callback.
build = (root / 'build/wineserver/build.sh').read_text()
gate = build[build.index('if ! xcrun nm -m "$OBJ_DIR/process_ios.o"'):]
gate = gate[:gate.index('\nfi') + len('\nfi')]
for symbols, expected in [
    ('                 (undefined) weak external _madeira_child_server_exited\n', 0),
    ('                 (undefined) external _madeira_child_server_exited\n', 1),
    ('0000000000000000 (__TEXT,__text) external _madeira_child_server_exited\n', 1),
    ('                 (undefined) weak external _old_callback\n', 1),
]:
    script = "xcrun() { printf '%s' \"$NM_FIXTURE\"; }\n" + gate
    result = subprocess.run(['bash', '-c', script], env={'PATH': '/usr/bin:/bin', 'NM_FIXTURE': symbols},
                            capture_output=True, text=True)
    assert result.returncode == expected, (symbols, result.stdout, result.stderr)
assert '"process_ios:$OBJ_DIR/process_lifecycle.c:process.o"' in build
assert '"process_ios.o:process.o"' in build
assert not re.search(r'(write_text|open)\([^\n]*wine/server', (root / 'build/wineserver/stage-steam-lifecycle.py').read_text())
print('PASS producer requires actual weak native lifecycle import before archive replacement; rejects stale/strong/wrong symbol fixtures')
