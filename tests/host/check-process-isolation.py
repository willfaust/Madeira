#!/usr/bin/env python3
"""Execute the production bootstrap/window, startup-block and thread-lifetime
helpers with synthetic processes. No iPhone, Wine prefix or Valve files used.
The native harnesses run under ASan/UBSan and include a protected stale TEB.
"""
import os
import re
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
v = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
l = (root / 'build/ntdll-unix/loader_ios.c').read_text()
t = (root / 'build/ntdll-unix/thread_ios.c').read_text()
s = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()


def body(src, marker):
    start = src.index(marker)
    brace = src.index('{', start)
    depth = 0
    for token in re.finditer(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]', src[brace:], re.S):
        ch = token.group()
        if ch == '{': depth += 1
        elif ch == '}':
            depth -= 1
            if not depth: return src[start:brace + token.end()]
    raise AssertionError(marker)


def run(label, code):
    with tempfile.TemporaryDirectory() as temp:
        c = Path(temp) / 'check.c'
        exe = Path(temp) / 'check'
        c.write_text(code)
        subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-g', '-O1', '-Wall',
                        '-Werror=implicit-function-declaration', '-Wno-unused-function',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined',
                        '-pthread', str(c), '-o', str(exe)], check=True)
        result = subprocess.run([str(exe)], text=True, capture_output=True, timeout=30,
                                env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))
        if result.returncode:
            print(result.stdout + result.stderr)
            raise AssertionError(f'{label}: exit {result.returncode}')
    print('PASS: ' + label)


common = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <setjmp.h>
#include <errno.h>
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define ERR(...) ((void)0)
typedef uintptr_t ULONG_PTR;
typedef uint32_t ULONG;
typedef uint32_t NTSTATUS;
#define STATUS_SUCCESS 0
#define STATUS_NO_MEMORY 0xc0000017
#define IOS_WOW_MAX_WINDOWS 8
#define IOS_WOW_WINDOW_SIZE 0x100000000ull
'''

window = common + body(v, 'struct ios_wow_window\n{') + ';\n' + r'''
static struct ios_wow_window ios_wow_windows[IOS_WOW_MAX_WINDOWS];
static unsigned ios_wow_window_count, ios_wow_next_generation;
static pthread_mutex_t ios_wow_mutex = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local struct ios_wow_window *ios_wow_boot_slot;
static _Thread_local unsigned ios_wow_boot_generation;
static unsigned ios_wow_small_va_slots, ios_wow_placeholder_count;
static struct { int adopted; ULONG_PTR base; } ios_wow_placeholders[1];
static int ios_wow_elastic(void) { return 0; }
static int ios_wow_window_try(ULONG_PTR b, unsigned *g) { (void)b; (void)g; return 0; }
static void *current_peb;
static int allocation_allowed = 1;
static ULONG_PTR next_base = 0x400000000;
static void *ios_jit_current_peb(void) { return current_peb; }
static void ios_wow_session_arm(void) {}
static void ios_wow_reclaim_dead_windows(void) {}
static void ios_wow_band(ULONG_PTR *floor, ULONG_PTR *ceil) { *floor=0; *ceil=0; }
static int ios_wow_map_allows_window(void) { return allocation_allowed; }
static ULONG_PTR ios_wow_window_pick(unsigned *guard) {
    ULONG_PTR b = next_base; next_base += 0x200000000; *guard=1; return b;
}
'''
for f in ('static struct ios_wow_window *ios_wow_slot_for_peb(',
          'static struct ios_wow_window *ios_wow_slot_boot(',
          'static struct ios_wow_window *ios_wow_slot_current(',
          'NTSTATUS ios_wow_window_reserve(', 'void ios_wow_window_bind('):
    window += body(v, f) + '\n'
window += r'''
int main(void) {
    void *parent=(void*)0x47ffd0000, *child=(void*)0x600310000;
    assert(!ios_wow_window_reserve()); ios_wow_window_bind(parent);
    assert(ios_wow_slot_current()->peb==parent);
    /* New boot thread, SAME pthread_t as the live parent's old boot thread.
       No inherited TLS reservation; even a stale creator PEB cannot be used. */
    ios_wow_boot_slot=NULL; ios_wow_boot_generation=0; current_peb=parent;
    assert(!ios_wow_window_reserve());
    assert(ios_wow_slot_current()->base==0x600000000);
    assert(ios_wow_slot_current()!=ios_wow_slot_for_peb(parent));
    assert(!ios_wow_window_reserve() && ios_wow_window_count==2);
    ios_wow_window_bind(child);
    assert(ios_wow_slot_for_peb(parent)->base==0x400000000);
    assert(ios_wow_slot_for_peb(child)->base==0x600000000);
    ios_wow_boot_slot=NULL; current_peb=parent;
    assert(ios_wow_slot_current()->peb==parent);
    current_peb=child; assert(ios_wow_slot_current()->peb==child);
    current_peb=NULL; assert(!ios_wow_slot_current());
    /* Stale TLS token must not adopt a recycled registry slot. */
    ios_wow_boot_slot=&ios_wow_windows[1];
    ios_wow_boot_generation=ios_wow_windows[1].generation;
    ++ios_wow_windows[1].generation;
    assert(!ios_wow_slot_current());
    allocation_allowed=0;
    assert(ios_wow_window_reserve()==STATUS_NO_MEMORY);
    assert(ios_wow_windows[0].peb==parent && ios_wow_windows[1].peb==child);
    return 0;
}
'''
run('fresh/reused thread cannot steal a live process window; own reservation, generations and failure', window)

# Exercise the real export producer with independent ntdll images and the real
# identity lookup/release. Stubs provide exports, not alternate startup logic.
startup = common + r'''
typedef void *HMODULE;
typedef uintptr_t UINT_PTR;
typedef uintptr_t unixlib_handle_t;
typedef struct { int Machine; } SECTION_IMAGE_INFORMATION;
typedef struct { int unused; } IMAGE_EXPORT_DIRECTORY;
typedef struct {
    uint64_t ntdll_handle, pKiUserApcDispatcher, pKiUserCallbackDispatcher,
    pKiUserExceptionDispatcher, pLdrInitializeThunk, pLdrSystemDllInitBlock,
    pRtlUserThreadStart, pRtlpFreezeTimeBias, pRtlpQueryProcessDebugInformationRemote;
} SYSTEM_DLL_INIT_BLOCK;
#include "build/ntdll-unix/ios_mixed.h"
#define IOS_MAX_PROC_IDENTS 64
#define IMAGE_FILE_EXPORT_DIRECTORY 0
#define _WIN64 1
static SYSTEM_DLL_INIT_BLOCK root_block, *pLdrSystemDllInitBlock=&root_block;
static void *p__wine_ctrl_routine, *current_peb, *session_peb=(void*)0x100;
static int ios_proc_ident_count;
static __attribute__((noreturn)) void ios_unix_fatal_exit(int s,const char*w) { assert(0); __builtin_trap(); }
static uintptr_t current_base;
static void *unix_call_wow64_funcs;
static IMAGE_EXPORT_DIRECTORY exports;
static SECTION_IMAGE_INFORMATION main_image_info={0x14c};
static void *ios_jit_current_peb(void) { return current_peb; }
static void *ios_session_peb_get(void) { return session_peb; }
static uintptr_t ios_wow_base(void) { return current_base; }
static const IMAGE_EXPORT_DIRECTORY *get_module_data_dir(void*m,int a,void*b) { return &exports; }
static uintptr_t find_named_export(void *m,const IMAGE_EXPORT_DIRECTORY *e,const char *name) {
    if (!strcmp(name,"LdrSystemDllInitBlock")) return (uintptr_t)m+1024;
    if (!strcmp(name,"__wine_unixlib_handle")) return (uintptr_t)m+512;
    if (!strcmp(name,"RtlpFreezeTimeBias")) return 0;
    if (!strcmp(name,"RtlpQueryProcessDebugInformationRemote")) return 0;
    return (uintptr_t)m+128;
}
'''
startup += body(l, 'struct ios_proc_ident\n{') + ';\n'
startup += 'static struct ios_proc_ident ios_proc_idents[IOS_MAX_PROC_IDENTS];\n'
for f in ('const SECTION_IMAGE_INFORMATION *ios_image_info_for_peb(',
          'void ios_register_proc_ident(', 'void ios_proc_ident_release(',
          'const SYSTEM_DLL_INIT_BLOCK *ios_wow64_init_block_for_peb(',
          'static void load_ntdll_wow64_functions('):
    startup += body(l, f) + '\n'
startup += r'''
int main(void) {
    unsigned char images[3][2048] = {{0}};
    SYSTEM_DLL_INIT_BLOCK saved_root, saved_child;
    SECTION_IMAGE_INFORMATION info={0x14c};
    current_peb=session_peb; current_base=(uintptr_t)images[0]-0xfff40000ull;
    ios_register_proc_ident(current_peb,&info);
    load_ntdll_wow64_functions(images[0]); saved_root=root_block;
    main_image_info.Machine=0x8664; /* mutable child bootstrap global */
    assert(ios_image_info_for_peb(session_peb)->Machine==0x14c);
    current_peb=(void*)0x200; current_base=(uintptr_t)images[1]-0xffe30000ull;
    ios_register_proc_ident(current_peb,&info);
    assert(!ios_wow64_init_block_for_peb(current_peb));
    load_ntdll_wow64_functions(images[1]);
    saved_child=*ios_wow64_init_block_for_peb(current_peb);
    assert(saved_child.pRtlUserThreadStart==0xffe30080);
    assert(!memcmp(&saved_child,images[1]+1024,sizeof(saved_child)));
    current_peb=(void*)0x300; current_base=(uintptr_t)images[2]-0xffd20000ull;
    ios_register_proc_ident(current_peb,&info); load_ntdll_wow64_functions(images[2]);
    assert(ios_wow64_init_block_for_peb(current_peb)->pRtlUserThreadStart==0xffd20080);
    assert(!memcmp(&root_block,&saved_root,sizeof(root_block)));
    assert(!memcmp(ios_wow64_init_block_for_peb((void*)0x200),&saved_child,sizeof(saved_child)));
    assert(!saved_child.pRtlpFreezeTimeBias);
    assert(!memcmp(ios_wow64_init_block_for_peb(session_peb),pLdrSystemDllInitBlock,sizeof(saved_root)));
    ios_proc_ident_release((void*)0x200);
    assert(!ios_wow64_init_block_for_peb((void*)0x200));
    assert(!ios_wow64_init_block_for_peb(NULL));
    assert(ios_wow64_init_block_for_peb((void*)0x300)->pRtlUserThreadStart==0xffd20080);
    return 0;
}
'''
# Include paths stay explicit; generated harness resides outside the repository.
startup = startup.replace('"build/ntdll-unix/ios_mixed.h"', '"'+str(root/'build/ntdll-unix/ios_mixed.h')+'"')
run('interleaved 32-bit ntdll exports and exception/thread startup remain with their process', startup)

# The production private-data writer must fail closed for a foreign owner.
writer = common + r'''
struct ios_jit_mapping { void *pe_base, *jit_base, *owner_peb; size_t size; };
static struct ios_jit_mapping ios_jit_mappings[3];
static int ios_jit_mapping_count=3;
static void *ios_jit_rw_base_global, *ios_jit_rx_base_global;
static size_t ios_jit_pool_size_global=1024;
'''+body(v,'int ios_jit_write_process_data(')+r'''
int main(void) {
    unsigned char pe[64]={0}, rw[1024]={0}, rx[1024]={0};
    uint64_t value=0xffe30080;
    ios_jit_rw_base_global=rw; ios_jit_rx_base_global=rx;
    for(int i=0;i<3;i++) ios_jit_mappings[i]=(struct ios_jit_mapping){pe,rx+i*256,(void*)(uintptr_t)(i+1),64};
    assert(ios_jit_write_process_data((void*)2,pe+16,&value,8));
    assert(!memcmp(rw+256+16,&value,8));
    assert(!memcmp(rw,pe,64) && !memcmp(rw+512,pe,64));
    assert(!ios_jit_write_process_data((void*)4,pe+16,&value,8));
    assert(!ios_jit_write_process_data((void*)2,pe+60,&value,8));
    assert(!ios_jit_write_process_data((void*)2,(void*)((uintptr_t)pe-1),&value,8));
    assert(!ios_jit_write_process_data(NULL,pe,&value,8));
    return 0;
}
'''
run('private native ntdll startup data never writes another owner or the source image', writer)

threads = common + r'''
#define DECLSPEC_NORETURN __attribute__((noreturn))
typedef struct { void *Peb; } TEB;
static _Thread_local TEB *test_teb;
static TEB *NtCurrentTeb(void) { return test_teb; }
static void ios_trace_steam_helper_exit(const char *event, int status) { (void)event; (void)status; assert(test_teb && test_teb->Peb); }
static int free_calls, exit_calls;
static jmp_buf escape;
static void virtual_free_teb(void *teb) { assert(((TEB*)teb)->Peb==test_teb->Peb); ++free_calls; }
static DECLSPEC_NORETURN void pthread_exit_wrapper(int status) { longjmp(escape,1); }
static DECLSPEC_NORETURN void exit_process(int status) { ++exit_calls; longjmp(escape,1); }
static sigset_t server_block_set;
#include <signal.h>
'''
# Native declarations and bookkeeping are compiled verbatim.
a=t.index('struct ios_thread_group\n{')
b=t.index('\nstatic inline int get_unix_exit_code(',a)
threads += t[a:b] + '\n' + body(t,'static DECLSPEC_NORETURN void exit_thread(')
threads += r'''
static void *finished(void *a) { return NULL; }
static void retire(TEB *teb) {
    test_teb=teb; ios_retired_thread_owner=NULL;
    if (!setjmp(escape)) exit_thread(0);
}
int main(void) {
    TEB a={(void*)0x100}, b={(void*)0x200};
    pthread_t old_thread;
    size_t page=sysconf(_SC_PAGESIZE);
    void *dead=mmap(NULL,page,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    assert(dead!=MAP_FAILED);
    pthread_create(&old_thread,NULL,finished,NULL);
    assert(ios_thread_count_add(a.Peb,1)==2);
    ios_thread_groups[0].prev_teb=dead;
    ios_thread_groups[0].prev_pthread=old_thread;
    assert(ios_thread_count_add(b.Peb,1)==2);
    retire(&b);
    assert(!free_calls && !exit_calls); /* old global prev_teb dereferenced dead here */
    assert(ios_thread_groups[0].count==2 && ios_thread_groups[1].count==1);
    errno=EINTR;
    assert(!ios_thread_process_exit_ready(b.Peb)); /* other logical thread is still live */
    assert(errno==EINTR); /* observation cannot alter the caller's error state */
    assert(ios_thread_count_add(b.Peb,1)<0);
    ios_retired_thread_owner=NULL; /* the remaining B thread */
    assert(ios_thread_process_exit_ready(b.Peb));
    assert(!ios_thread_process_exit_ready(b.Peb)); /* reclamation happens once */
    assert(ios_thread_groups[0].count==2); /* A remains completely independent */
    pthread_mutex_lock(&ios_thread_reapers[0]);
    assert(!ios_thread_process_forget(a.Peb)); /* busy reaper never stalls another process */
    assert(ios_thread_groups[0].owner==a.Peb && ios_thread_groups[1].owner==b.Peb);
    pthread_mutex_unlock(&ios_thread_reapers[0]);
    assert(ios_thread_process_forget(a.Peb)); /* detach snapshot without a TEB read */
    munmap(dead,page);
    assert(!ios_thread_groups[0].owner);
    return 0;
}
'''
threads = threads.replace('static sigset_t server_block_set;\n#include <signal.h>', '#include <signal.h>\nstatic sigset_t server_block_set;')
run('deferred TEB handoff/counts are per process; protected stale TEB never read; live threads quarantine memory', threads)

# The final retiring thread no longer has a live master socket. Exercise the
# real fixed-image state machine, including refusal to touch a foreign image.
fixed = common + r"""
#include <stdlib.h>
#include <signal.h>
#include <errno.h>
#define STATUS_NOT_MAPPED_VIEW 0xc0000019u
#define VPROT_SYSTEM 0x100
#define IOS_EXEWIN_OWNED 1
#define IOS_EXEWIN_RETIRING 2
#define IOS_EXEWIN_FREE 3
#define IOS_EXEWIN_HELD_NOT_READY 4
static pthread_mutex_t ios_exewin_lock=PTHREAD_MUTEX_INITIALIZER, virtual_mutex=PTHREAD_MUTEX_INITIALIZER;
static int ios_exewin_st, ios_exe_win_img_dead, ios_retire_trace_armed, ios_retire_trace_fd, ios_retire_trace_lastwr;
static unsigned ios_exe_win_generation=7;
static void *ios_exe_win_img_base, *ios_exe_win_img_peb, *ios_exe_win_held_base;
static size_t ios_exe_win_img_size, ios_exe_win_held_size;
struct file_view { void *base; size_t size; unsigned protect; };
static struct file_view test_view;
static int deleted, rpc_calls, view_present=1;
static void ios_retire_mark(const char *s) {}
static void *NtCurrentProcess(void) { return (void*)-1; }
static unsigned NtUnmapViewOfSection(void*p,void*b) { ++rpc_calls; return 0; }
static void server_enter_uninterrupted_section(pthread_mutex_t*m,sigset_t*s) { pthread_mutex_lock(m); }
static void server_leave_uninterrupted_section(pthread_mutex_t*m,sigset_t*s) { pthread_mutex_unlock(m); }
static struct file_view *find_view(void*b,size_t n) { return view_present ? &test_view : NULL; }
static int is_view_valloc(struct file_view *v) { return !!(v->protect&0x200); }
static void delete_view(struct file_view *v) { ++deleted; view_present=0; }
static void *anon_mmap_tryfixed(void*b,size_t n,int prot,int flags) { return b; }
""" + body(v,'static void ios_retire_fixed_base_image(') + r"""
static void setup(void) {
    ios_exewin_st=IOS_EXEWIN_OWNED;
    ios_exe_win_img_base=(void*)0x140000000; ios_exe_win_img_size=0x20000;
    ios_exe_win_img_peb=(void*)0x100; ios_exe_win_img_dead=1;
    test_view=(struct file_view){ios_exe_win_img_base,ios_exe_win_img_size,0};
    view_present=1; deleted=rpc_calls=0;
}
int main(void) {
    setup(); ios_retire_fixed_base_image((void*)0x200,1);
    assert(!deleted && !rpc_calls && ios_exewin_st==IOS_EXEWIN_OWNED);
    ios_retire_fixed_base_image((void*)0x100,1);
    assert(deleted==1 && !rpc_calls && ios_exewin_st==IOS_EXEWIN_HELD_NOT_READY);
    assert(ios_exe_win_held_base==(void*)0x140000000 && ios_exe_win_held_size==0x20000);
    setup(); test_view.size+=0x1000; ios_retire_fixed_base_image((void*)0x100,1);
    assert(!deleted && !rpc_calls && ios_exewin_st==IOS_EXEWIN_OWNED);
    setup(); test_view.protect=VPROT_SYSTEM; ios_retire_fixed_base_image((void*)0x100,1);
    assert(!deleted && !rpc_calls && ios_exewin_st==IOS_EXEWIN_OWNED);
    setup(); test_view.protect=0x200; ios_retire_fixed_base_image((void*)0x100,1);
    assert(!deleted && !rpc_calls && ios_exewin_st==IOS_EXEWIN_OWNED);
    setup(); ios_retire_fixed_base_image((void*)0x100,0);
    assert(!deleted && rpc_calls==1 && ios_exewin_st==IOS_EXEWIN_HELD_NOT_READY);
    return 0;
}
"""
run('last-thread fixed-image cleanup uses no dead-server RPC; foreign/system/changed views are retained', fixed)

frame = body(s,'void init_syscall_frame(')
assert 'i386_context->Eip = wow_init->pRtlUserThreadStart;' in frame
assert 'arg == teb->Peb ? (char *)teb->Peb + page_size : arg' in frame
assert 'i386_context->Eip = pLdrSystemDllInitBlock' not in frame
assert 'ios_jit_write_process_data(child_peb, pLdrSystemDllInitBlock,' in l
assert 'private guest-window ownership not established' in l
assert 'if (slot && slot->peb) slot = NULL;' in body(v,'void ios_wow_window_release_current(')
print('PASS: actual i386 context consumes its owner snapshot; bootstrap and release fail closed')
