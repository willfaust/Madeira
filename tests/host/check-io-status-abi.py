#!/usr/bin/env python3
"""Regression for native I/O in a WoW64 process and delayed 32-bit completions.

Compile actual staged Wine publishers/PE helpers and the native ABI controller;
use real memory/threads/isolated faults. No Steam or service replies are mocked.
"""
from pathlib import Path
import importlib.util
import os
import re
import subprocess
import tempfile
import shutil

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('io_stage', root / 'tools/build/stage-io-status-abi.py')
stager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stager)


def function(source, signature):
    start = source.index(signature)
    begin = source.index('{', start)
    end, depth = begin + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


with tempfile.TemporaryDirectory(prefix='madeira-io-abi-') as temp:
    folder = Path(temp)
    stager.stage(folder, root / 'wine')
    unix = (folder / 'dlls/ntdll/unix/unix_private.h').read_text()
    pe = (folder / 'dlls/wow64/wow64_private.h').read_text()
    native = (root / 'build/ntdll-unix/io_status_abi.c').read_text()
    server = (root / 'build/ntdll-unix/server_ios.c').read_text()
    producer = function(unix, 'static inline client_ptr_t iosb_client_ptr(')
    submit = function(unix, 'static inline struct async_data server_async(')
    io_struct = function(unix, 'struct async_fileio\n') + ';'
    complete = server[server.index('    case APC_ASYNC_IO:'):server.index('    /* in every APC below,')]
    scope = (folder / 'dlls/wow64/syscall.c').read_text()
    assert '__FINALLY_CTX( io_scope_leave, &scope )' in scope
    assert 'wow_guest_base && io_scope_required(table->ServiceTable[id])' in scope
    header = (root / 'build/ntdll-unix/io_status_abi.h').read_text()
    declared = dict((name, int(num, 16)) for num, name in re.findall(r'X\(\s*(0x[0-9a-f]+),\s*(Nt\w+)\s*\)', header))
    callers = set()
    for path in (root / 'wine/dlls/wow64').glob('*.c'):
        staged_path = folder / 'dlls/wow64' / path.name
        text = (staged_path if staged_path.exists() else path).read_text()
        for match in re.finditer(r'NTSTATUS WINAPI wow64_(\w+)\( UINT \*args \)', text):
            body = function(text, match.group(0))
            if 'iosb_32to64(' in body or 'put_iosb(' in body: callers.add(match.group(1))
    assert callers == declared.keys(), ('IOSB thunk coverage', callers ^ declared.keys())
    syscalls = dict((name, int(num, 16)) for num, name in re.findall(r'SYSCALL_ENTRY\(\s*(0x[0-9a-f]+),\s*(Nt\w+),', (root / 'wine/dlls/ntdll/ntsyscalls.h').read_text()))
    assert all(syscalls[name] == value for name, value in declared.items())
    assert not {'NtOpenSection', 'NtContinueEx', 'NtCallbackReturn'} & callers
    predicate = function(scope, 'static BOOL io_scope_required(')
    leave = function(scope, 'static void io_scope_leave(')
    dispatcher = function(scope, 'NTSTATUS WINAPI Wow64SystemServiceEx(')

    assert 'if (status && normal) RtlRaiseStatus( status );' in scope
    assert 'io->iosb32   = FALSE;' in (folder / 'dlls/ntdll/unix/file.c').read_text()
    code = r'''
#define _GNU_SOURCE
#define WINE_IOS 1
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include <setjmp.h>
#include <sys/mman.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_vm.h>
#endif
#include "io_status_abi.h"
typedef int BOOL, THREADINFOCLASS; typedef int32_t NTSTATUS;
typedef unsigned int ULONG, DWORD, UINT; typedef int32_t LONG; typedef size_t SIZE_T; typedef uintptr_t ULONG_PTR, client_ptr_t;
typedef void *HANDLE; typedef void *PIO_APC_ROUTINE;
#define TRUE 1
#define FALSE 0
#define STATUS_SUCCESS 0
#define STATUS_INVALID_HANDLE ((NTSTATUS)0xc0000008)
#define STATUS_INFO_LENGTH_MISMATCH ((NTSTATUS)0xc0000004)
#define STATUS_ACCESS_VIOLATION ((NTSTATUS)0xc0000005)
#define STATUS_REVISION_MISMATCH ((NTSTATUS)0xc0000059)
#define STATUS_INVALID_PARAMETER ((NTSTATUS)0xc000000d)
#define STATUS_PENDING 0x103
#define STATUS_INVALID_SYSTEM_SERVICE ((NTSTATUS)0xc000001c)
#define C_ASSERT(x) _Static_assert((x),#x)
#define NtCurrentThread() ((HANDLE)(intptr_t)-2)
#define GetCurrentThread() NtCurrentThread()
typedef struct { union { NTSTATUS Status; void *Pointer; }; uintptr_t Information; } IO_STATUS_BLOCK;
typedef struct { union { NTSTATUS Status; uint32_t Pointer; }; uint32_t Information; } IO_STATUS_BLOCK32;
_Static_assert(offsetof(IO_STATUS_BLOCK,Information)==8, "native IOSB layout");
_Static_assert(sizeof(struct madeira_io_scope)==24 && sizeof(struct madeira_io_control)==32, "private ABI sizes");
_Static_assert(offsetof(struct madeira_io_control,scope)==8 && offsetof(struct madeira_io_control,native_iosb)==16 && offsetof(struct madeira_io_control,guest_iosb)==24,"private ABI pointer offsets");
_Static_assert(offsetof(IO_STATUS_BLOCK32,Information)==4, "guest IOSB layout");
typedef struct { struct { void *StackLimit,*StackBase; } Tib; void *Peb; } TEB;
static _Thread_local TEB fixture_teb;
static TEB *NtCurrentTeb(void) { return &fixture_teb; }
static void prepare_teb(void) {
#if defined(__APPLE__)
    fixture_teb.Tib.StackBase=pthread_get_stackaddr_np(pthread_self());
    fixture_teb.Tib.StackLimit=(char *)fixture_teb.Tib.StackBase-pthread_get_stacksize_np(pthread_self());
#else
    pthread_attr_t attr;void *stack;size_t size;
    assert(!pthread_getattr_np(pthread_self(),&attr));assert(!pthread_attr_getstack(&attr,&stack,&size));
    fixture_teb.Tib.StackLimit=stack;fixture_teb.Tib.StackBase=(char *)stack+size;pthread_attr_destroy(&attr);
#endif
    fixture_teb.Peb=(void *)0xfeed0000;
}
static BOOL accessible(const void *p,size_t n,BOOL write) {
    uintptr_t address=(uintptr_t)p;if(!p||!n||address>UINTPTR_MAX-n)return FALSE;
#if defined(__APPLE__)
    mach_vm_address_t region=address;mach_vm_size_t length=0;natural_t depth=0;
    vm_region_submap_short_info_data_64_t info={0};mach_msg_type_number_t count=VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
    return mach_vm_region_recurse(mach_task_self(),&region,&length,&depth,(vm_region_recurse_info_t)&info,&count)==KERN_SUCCESS &&
           region<=address && length>=address-region && length-(address-region)>=n && (info.protection&(write?VM_PROT_WRITE:VM_PROT_READ));
#else
    FILE *maps=fopen("/proc/self/maps","r");assert(maps);char line[512],perms[5];unsigned long long low,high;BOOL found=FALSE;
    while(fgets(line,sizeof(line),maps))if(sscanf(line,"%llx-%llx %4s",&low,&high,perms)==3 &&
        low<=address && address<high && high-address>=n && perms[write?1:0]==(write?'w':'r')){found=TRUE;break;}
    fclose(maps);return found;
#endif
}
static _Thread_local ULONG_PTR current_window;
ULONG_PTR ios_wow_base(void) { return current_window; }
BOOL ios_io_buffer_writable(const void *p,SIZE_T n) { return accessible(p,n,TRUE); }
BOOL ios_io_read_control(const void *p,struct madeira_io_control *out) {
    if(!accessible(p,sizeof(*out),FALSE))return FALSE;
    memcpy(out,p,sizeof(*out));return TRUE;
}
void ios_trace_io_scope(const struct madeira_io_control *c,const char *a,const void *r,
                        unsigned long long g,unsigned d,NTSTATUS s) {(void)c;(void)a;(void)r;(void)g;(void)d;(void)s;}

static void *wine_server_get_ptr(client_ptr_t p) { return (void *)p; }
static client_ptr_t wine_server_client_ptr(const void *p) { return (uintptr_t)p; }
static unsigned wine_server_obj_handle(HANDLE h) { return (uintptr_t)h; }
#define WriteRelease(p,v) __atomic_store_n((p),(v),__ATOMIC_RELEASE)
typedef BOOL async_callback_t(void *,ULONG_PTR *,unsigned int *);
''' + native[native.index('struct ios_io_record'):]+ r'''
static uintptr_t wow_guest_base = 0x600000000ull;
static NTSTATUS NtSetInformationThread(HANDLE h,THREADINFOCLASS c,const void *p,ULONG n) {
    assert(c==MADEIRA_THREAD_IO_ABI); return ios_io_status_control(h,p,n);
}
static void RtlRaiseStatus(NTSTATUS s) { fprintf(stderr,"unexpected private ABI failure %x\n",(unsigned)s); abort(); }
''' + function(pe, 'static inline void *guest_ptr32(') + '\n' + function(pe, 'static inline void *get_ptr(') + '\n' + function(pe, 'static inline void iosb_control(') + '\n' + function(pe, 'static inline IO_STATUS_BLOCK *iosb_32to64(') + '\n' + function(pe, 'static inline void put_iosb(') + '\n' + producer + '\n' + io_struct + r'''
struct async_data { unsigned handle; client_ptr_t user,iosb; unsigned event; client_ptr_t apc,apc_context; };
''' + submit + r'''
enum { APC_ASYNC_IO=1 };
union apc_call { unsigned type; struct { unsigned type,status; client_ptr_t user,sb; unsigned result; } async_io; };
union apc_result { unsigned type; struct { unsigned type,status,total; } async_io; };
static BOOL ios_trace_async_apc(const union apc_call *c,const char *p) { (void)c;(void)p; return FALSE; }
static void actual_complete(const union apc_call *call,union apc_result *result) { switch(call->type) {
''' + complete + r'''
} }
static BOOL finish_and_free(void *user,ULONG_PTR *info,unsigned int *status) {
    assert(*info==54); *status=0x80000005; free(user); return TRUE;
}
static struct async_data queued(IO_STATUS_BLOCK *io) {
    struct async_fileio *user=malloc(sizeof(*user)); assert(user);
    user->callback=finish_and_free; user->iosb32=FALSE;
    return server_async(NULL,user,NULL,NULL,NULL,iosb_client_ptr(io));
}
static void dispatch(struct async_data data) {
    union apc_call call={.async_io={.type=APC_ASYNC_IO,.user=data.user,.sb=data.iosb,.result=54}};
    union apc_result result={0}; actual_complete(&call,&result);
    assert(result.async_io.status==0x80000005u && result.async_io.total==54);
}
static NTSTATUS control(unsigned op,struct madeira_io_scope *s) {
    struct madeira_io_control c={MADEIRA_IO_ABI_VERSION,op,s,NULL,NULL};
    return ios_io_status_control(NtCurrentThread(),&c,sizeof(c));
}
static jmp_buf nonlocal;
static unsigned syscall_count;
#define IO_TEST_THUNK(id,name) static NTSTATUS wow64_ ## name(UINT *args) {(void)args;syscall_count++;return STATUS_SUCCESS;}
MADEIRA_IO_THUNKS(IO_TEST_THUNK)
#undef IO_TEST_THUNK
static NTSTATUS wow64_NtOpenSection(UINT *args){(void)args;syscall_count++;return STATUS_SUCCESS;}
static NTSTATUS wow64_NtContinueEx(UINT *args){(void)args;longjmp(nonlocal,1);}
static NTSTATUS wow64_NtCallbackReturn(UINT *args){(void)args;longjmp(nonlocal,2);}
typedef struct {ULONG_PTR *ServiceTable;void *CounterTable;UINT ServiceLimit;void *ArgumentTable;} SYSTEM_SERVICE_TABLE;
static SYSTEM_SERVICE_TABLE syscall_tables[4];
static NTSTATUS wow64_syscall(UINT *args,ULONG_PTR thunk){return ((NTSTATUS (*)(UINT *))thunk)(args);}
static void free_temp_data(void){}
#define WINAPI
#define ERR(...) ((void)0)
static LONG InterlockedCompareExchange(LONG *p,LONG value,LONG expected){return __sync_val_compare_and_swap(p,expected,value);}
#define __TRY do
#define __FINALLY_CTX(fn,ctx) while(0);fn(TRUE,ctx);
''' + predicate + '\n' + leave + '\n' + dispatcher + r'''
static void extended_tests(void) {
    struct madeira_io_scope poisoned={.previous=(void *)0x19efef30,.native_iosb=(void *)0x19efe928,.guest_iosb=(void *)0x419efef30ull};
    assert(!control(MADEIRA_IO_ENTER_OPERATION(8),&poisoned));
    assert(poisoned.previous==(void *)0x19efef30); // caller memory never supplies links
    unsigned long long generation=io_scopes.records[0].generation;
    IO_STATUS_BLOCK native={0};IO_STATUS_BLOCK32 target={0};
    iosb_32to64(&native,&target);
    poisoned.previous=(void *)0x19efef30; // abandoned frame contents cannot redirect traversal
    assert(ios_io_status_proxy(&native)==&target);
    assert(!control(MADEIRA_IO_LEAVE,&poisoned));
    assert(!control(MADEIRA_IO_ENTER_OPERATION(8),&poisoned));
    assert(io_scopes.records[0].generation>generation);
    fixture_teb.Peb=(void *)0xdead0000;
    assert(control(MADEIRA_IO_LEAVE,&poisoned)==STATUS_INVALID_PARAMETER);
    fixture_teb.Peb=(void *)0xfeed0000;assert(!control(MADEIRA_IO_LEAVE,&poisoned));
    // The actual non-I/O producer path may longjmp; it creates no scope to abandon.
    ULONG_PTR table[0x1000]={0};syscall_tables[0].ServiceTable=table;syscall_tables[0].ServiceLimit=0x1000;
#define IO_TEST_ENTRY(id,name) table[id]=(ULONG_PTR)wow64_ ## name;
    MADEIRA_IO_THUNKS(IO_TEST_ENTRY)
#undef IO_TEST_ENTRY
    table[0x37]=(ULONG_PTR)wow64_NtOpenSection;table[0x75]=(ULONG_PTR)wow64_NtContinueEx;table[5]=(ULONG_PTR)wow64_NtCallbackReturn;
    assert(!io_scope_required(table[0x37]) && !io_scope_required(table[0x75]) && !io_scope_required(table[5]));
    if(!setjmp(nonlocal))Wow64SystemServiceEx(0x75,NULL);
    assert(!io_scopes.depth);assert(!Wow64SystemServiceEx(0x37,NULL));assert(!io_scopes.depth);
    if(!setjmp(nonlocal))Wow64SystemServiceEx(5,NULL);
    assert(!io_scopes.depth);assert(!Wow64SystemServiceEx(0x37,NULL));assert(!io_scopes.depth);
#define IO_TEST_CALL(id,name) assert(io_scope_required(table[id]));assert(!Wow64SystemServiceEx(id,NULL));assert(!io_scopes.depth);
    MADEIRA_IO_THUNKS(IO_TEST_CALL)
#undef IO_TEST_CALL
    // Invalid control/stack cookies are probed without dereferencing hostile addresses.
    assert(ios_io_status_control(NtCurrentThread(),NULL,sizeof(struct madeira_io_control))==STATUS_ACCESS_VIOLATION);
    assert(ios_io_status_control(NtCurrentThread(),&poisoned,sizeof(struct madeira_io_control)-1)==STATUS_INFO_LENGTH_MISMATCH);
    assert(ios_io_status_control(NtCurrentThread(),(void *)0x19efef30,sizeof(struct madeira_io_control))==STATUS_ACCESS_VIOLATION);
    assert(control(MADEIRA_IO_ENTER,(void *)0x19efef30)==STATUS_ACCESS_VIOLATION);
    struct madeira_io_control old={1,MADEIRA_IO_ENTER,&poisoned,NULL,NULL};
    assert(ios_io_status_control(NtCurrentThread(),&old,sizeof(old))==STATUS_REVISION_MISMATCH);
    struct madeira_io_scope depth[MADEIRA_IO_SCOPE_LIMIT+1];
    for(unsigned i=0;i<MADEIRA_IO_SCOPE_LIMIT;i++)assert(!control(MADEIRA_IO_ENTER,&depth[i]));
    assert(control(MADEIRA_IO_ENTER,&depth[MADEIRA_IO_SCOPE_LIMIT])==STATUS_INVALID_PARAMETER);
    for(unsigned i=MADEIRA_IO_SCOPE_LIMIT;i;i--)assert(!control(MADEIRA_IO_LEAVE,&depth[i-1]));
    size_t page=sysconf(_SC_PAGESIZE);
    struct madeira_io_scope *cookie=mmap(NULL,page,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);assert(cookie!=MAP_FAILED);
    IO_STATUS_BLOCK32 *guest=mmap(NULL,page,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);assert(guest!=MAP_FAILED);
    void *old_low=fixture_teb.Tib.StackLimit,*old_high=fixture_teb.Tib.StackBase;
    fixture_teb.Tib.StackLimit=cookie;fixture_teb.Tib.StackBase=(char *)cookie+page;
    assert(!control(MADEIRA_IO_ENTER_OPERATION(8),cookie));
    current_window=(uintptr_t)guest & ~0xffffffffull;
    ULONG_PTR old_wow_base=wow_guest_base;wow_guest_base=current_window;
    UINT guest_args[1]={(UINT)((uintptr_t)guest-current_window)},*guest_cursor=guest_args;
    assert(guest_args[0] && guest_ptr32(0)==NULL);
    assert(get_ptr(&guest_cursor)==guest); // actual pinned-Wine guest32-to-host conversion
    struct madeira_io_control bind={MADEIRA_IO_ABI_VERSION,MADEIRA_IO_BIND,NULL,&native,(void *)(uintptr_t)(uint32_t)(uintptr_t)guest};
    assert(ios_io_status_control(NtCurrentThread(),&bind,sizeof(bind))==STATUS_ACCESS_VIOLATION); // raw guest remains invalid
    bind.guest_iosb=guest;assert(!mprotect(guest,page,PROT_READ));
    assert(ios_io_status_control(NtCurrentThread(),&bind,sizeof(bind))==STATUS_ACCESS_VIOLATION);
    assert(!mprotect(guest,page,PROT_READ|PROT_WRITE));
    assert(!ios_io_status_control(NtCurrentThread(),&bind,sizeof(bind)));
    guest_cursor=guest_args;assert(iosb_32to64(&native,get_ptr(&guest_cursor))==&native);
    assert(ios_io_status_proxy(&native)==guest);
    struct async_data delayed=queued(&native);
    assert(!mprotect(cookie,page,PROT_NONE)); // producer frame storage becomes inaccessible
    assert(!control(MADEIRA_IO_LEAVE,cookie)); // identity-only pop never dereferences cookie
    assert(!munmap(cookie,page));fixture_teb.Tib.StackLimit=old_low;fixture_teb.Tib.StackBase=old_high;
    dispatch(delayed);assert(guest->Information==54); // async keeps target/layout, not dead scope
    assert(!munmap(guest,page));current_window=0;wow_guest_base=old_wow_base;
    puts("PASS actual I/O thunk coverage, nonlocal continuation/callback then NtOpenSection, native-owned links, owner/generation/depth, hostile raw pointers, translated/readonly IOSB and unmapped producer-stack lifetime");
}
static void *thread_test(void *unused) {
    (void)unused; prepare_teb(); struct madeira_io_scope s; IO_STATUS_BLOCK native={.Pointer=(void *)0x10000};
    IO_STATUS_BLOCK32 guest={0}; IO_STATUS_BLOCK wrapper;
    assert(!control(MADEIRA_IO_ENTER,&s)); iosb_32to64(&wrapper,&guest);
    assert(iosb_client_ptr(&wrapper)==(uintptr_t)&guest);
    assert(iosb_client_ptr(&native)==(uintptr_t)&native);
    put_iosb(&guest,&wrapper); assert(!control(MADEIRA_IO_LEAVE,&s)); return NULL;
}
int main(void) {
    prepare_teb();struct rlimit core={0,0}; assert(!setrlimit(RLIMIT_CORE,&core));
    // Exact logged failure: native stack IOSB contains 0x10000 in a WoW64 process.
    IO_STATUS_BLOCK native={.Pointer=(void *)0x10000,.Information=0};
    assert(iosb_client_ptr(&native)==(uintptr_t)&native);
    dispatch(queued(&native));
    assert((unsigned)native.Status==0x80000005u && native.Information==54);
    // A return/code pointer in that union must never become a completion destination.
    uint32_t code_words[4]={0xd503201f,0xd503201f,0xd503201f,0xd503201f};
    native.Pointer=code_words; dispatch(queued(&native)); assert(code_words[1]==0xd503201f);
    // The former process-wide rule corrupts the next instruction with byte count 54.
    IO_STATUS_BLOCK32 *old_target=(IO_STATUS_BLOCK32 *)code_words;
    old_target->Information=54; assert(code_words[1]==0x36);
    struct madeira_io_scope outer,inner;
    assert(!control(MADEIRA_IO_ENTER,&outer));
    struct { IO_STATUS_BLOCK32 io; uint64_t canary; } guest={{.Status=STATUS_PENDING},0xfeedface87654321ull};
    IO_STATUS_BLOCK wrapper; iosb_32to64(&wrapper,&guest.io);
    struct async_data delayed=queued(&wrapper);
    assert(((struct async_fileio *)(uintptr_t)delayed.user)->iosb32);
    assert(delayed.iosb==(uintptr_t)&guest.io);
    assert(!control(MADEIRA_IO_ENTER,&inner));
    IO_STATUS_BLOCK failed={.Status=(NTSTATUS)0xc0000003,.Information=0};
    IO_STATUS_BLOCK32 error_out={.Status=STATUS_PENDING,.Information=99};
    put_iosb(&error_out,&failed); // real PE validation can fail before iosb_32to64
    assert((unsigned)error_out.Status==0xc0000003u && error_out.Information==0);
    assert(iosb_client_ptr(&wrapper)==(uintptr_t)&guest.io); // nested native callback keeps outer provenance
    native.Pointer=(void *)0x10000; dispatch(queued(&native));
    assert(native.Information==54);
    assert(control(MADEIRA_IO_ENTER,&outer)==STATUS_INVALID_PARAMETER); // no scope cycles
    assert(control(MADEIRA_IO_LEAVE,&outer)==STATUS_INVALID_PARAMETER); // LIFO
    assert(!control(MADEIRA_IO_LEAVE,&inner));
    put_iosb(&guest.io,&wrapper); assert(!control(MADEIRA_IO_LEAVE,&outer));
    dispatch(delayed); // scope gone, callback frees metadata: layout still 32-bit
    assert((unsigned)guest.io.Status==0x80000005u && guest.io.Information==54);
    assert(guest.canary==0xfeedface87654321ull);
    pthread_t threads[4];
    for(int i=0;i<4;i++) assert(!pthread_create(&threads[i],NULL,thread_test,NULL));
    for(int i=0;i<4;i++) assert(!pthread_join(threads[i],NULL));
    pid_t child=fork(); assert(child>=0);
    if(!child) { signal(SIGSEGV,SIG_DFL); signal(SIGBUS,SIG_DFL); ios_complete_io_status(0x10000,0,54,FALSE); _exit(0); }
    int status; assert(waitpid(child,&status,0)==child);
    assert(WIFSIGNALED(status) && (WTERMSIG(status)==SIGSEGV || WTERMSIG(status)==SIGBUS));
    puts("PASS native 0x10000/code-pointer IOSBs, explicit guest proxies, nested/thread scopes, delayed completion/canary, original status and genuine fault");
    extended_tests();
}
'''
    path, binary = folder / 'test.c', folder / 'test'
    path.write_text(code)
    subprocess.run([os.environ.get('CC','cc'), '-std=gnu11','-Wall','-Wextra','-Werror',
                    '-fsanitize=address,undefined','-pthread','-I',str(root/'build/ntdll-unix'),
                    str(path),'-o',str(binary)],check=True)
    # Cookie bounds model the real Windows native stack. ASan's optional fake
    # stack moves local objects off-stack; actual lifetime is exercised with
    # PROT_NONE/munmap instead, while all address/undefined checks remain on.
    subprocess.run([str(binary)],check=True,env=dict(os.environ,ASAN_OPTIONS='handle_segv=0:handle_sigbus=0:detect_stack_use_after_return=0'))
    # Exercise restoration on an isolated source checkout, including refusal
    # to overwrite an edit made while a build was running.
    source = folder / 'source'
    for name in stager.FILES:
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / 'wine' / name, target)
    subprocess.run(['git','init','-q',str(source)],check=True)
    subprocess.run(['git','-C',str(source),'add','.'],check=True)
    subprocess.run(['git','-C',str(source),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                    'commit','-qm','source fixture'],check=True)
    originals = {n:(source/n).read_bytes() for n in stager.FILES}
    state = folder / 'state'; state.mkdir()
    stager.apply(state,source)
    changed = source / stager.FILES[0]; staged_bytes = changed.read_bytes()
    changed.write_bytes(staged_bytes + b'/* concurrent edit */\n')
    try:
        stager.restore(state)
    except SystemExit as error:
        assert 'Refusing to overwrite changes' in str(error)
    else:
        raise AssertionError('concurrent source edit was overwritten')
    assert changed.read_bytes().endswith(b'/* concurrent edit */\n')
    changed.write_bytes(staged_bytes)
    stager.restore(state)
    assert all((source/n).read_bytes()==data for n,data in originals.items())
    assert not (source/stager.HEADER).exists()
    print('PASS Wine overlay restores exact original files and refuses concurrent edits')
