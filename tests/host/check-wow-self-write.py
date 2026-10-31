#!/usr/bin/env python3
"""Execute the real native self-write route with RO/RW aliases and logical 4 KB permissions."""
from pathlib import Path
import os,re,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'build/ntdll-unix/virtual_ios.c').read_text()
def fn(marker):
 a=s.index(marker);return s[a:s.index('\n}',a)+2]
code=r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>
#include <pthread.h>
typedef void* HANDLE;typedef uintptr_t ULONG_PTR;typedef size_t SIZE_T;typedef uint32_t NTSTATUS;typedef unsigned char BYTE;typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define WINAPI
#define WINE_IOS 1
#define STATUS_SUCCESS 0
#define STATUS_NO_MEMORY 0xc0000017u
#define STATUS_ACCESS_DENIED 0xc0000022u
#define STATUS_ACCESS_VIOLATION 0xc0000005u
#define STATUS_PARTIAL_COPY 0x8000000du
#define PROCESS_VM_WRITE 0x20
#define VPROT_WRITE 2
#define VPROT_WRITECOPY 8
#define VPROT_COMMITTED 0x20
#define VPROT_GUARD 0x10
#define IOS_WOW_WINDOW_SIZE 0x100000000ULL
#define IOS_KW_PAGE 4096
#define ObjectBasicInformation 0
#define ProcessBasicInformation 0
#define NtCurrentProcess() ((void*)(intptr_t)-1)
struct {struct {void* UniqueProcess;} ClientId;} teb;
#define NtCurrentTeb() (&teb)
typedef struct {unsigned GrantedAccess;} OBJECT_BASIC_INFORMATION;
typedef struct {uintptr_t UniqueProcessId;} PROCESS_BASIC_INFORMATION;
static uintptr_t wow;static unsigned rights=PROCESS_VM_WRITE;static uintptr_t pid=100;static int queryfail,server_calls,notes;
static unsigned char *ro,*rw;static int alias_on=1;static BYTE prot[4];static const size_t page_size=4096,page_mask=4095;
static pthread_mutex_t virtual_mutex=PTHREAD_MUTEX_INITIALIZER;
static uintptr_t ios_wow_base(void){return wow;}
static NTSTATUS NtQueryObject(HANDLE h,int c,OBJECT_BASIC_INFORMATION* o,size_t n,void* r){(void)h;(void)c;(void)n;(void)r;o->GrantedAccess=rights;return queryfail?STATUS_ACCESS_DENIED:0;}
static NTSTATUS NtQueryInformationProcess(HANDLE h,int c,PROCESS_BASIC_INFORMATION* o,size_t n,void* r){(void)h;(void)c;(void)n;(void)r;o->UniqueProcessId=pid;return queryfail?STATUS_ACCESS_DENIED:0;}
static BOOL virtual_check_buffer_for_read(const void* b,size_t n){return (!n || (uintptr_t)b>=0x10000);}
static void server_enter_uninterrupted_section(pthread_mutex_t* m,sigset_t* set){(void)set;assert(!pthread_mutex_lock(m));}
static void server_leave_uninterrupted_section(pthread_mutex_t* m,sigset_t* set){(void)set;assert(!pthread_mutex_unlock(m));}
static BYTE get_page_vprot(const void* a){uintptr_t p=(uintptr_t)a;return alias_on&&p>=(uintptr_t)ro&&p-(uintptr_t)ro<16384?prot[(p-(uintptr_t)ro)/4096]:0;}
static NTSTATUS check_write_access(void* a,size_t n,BOOL* w){(void)a;(void)n;*w=1;return 0;}
static void update_write_watches(void* a,size_t n,size_t done){(void)a;assert(n==done||done==0);notes++;}
static uintptr_t ios_kw_rw_alias(uintptr_t p){return p>=(uintptr_t)ro&&p-(uintptr_t)ro<16384?(uintptr_t)rw+p-(uintptr_t)ro:0;}
static int ios_range_writable(const void* a,size_t n){(void)a;(void)n;return 0;}
static void ios_jit_anon_alias_note_write(uintptr_t p){assert(p>=(uintptr_t)ro&&p-(uintptr_t)ro<16384);}
static void ios_trace_wow_write_begin(HANDLE p,void* a,const void* b,size_t n){(void)p;(void)a;(void)b;(void)n;}
static void ios_trace_wow_write(NTSTATUS s,size_t n,const char* route){(void)n;assert(!strcmp(route,s==STATUS_ACCESS_DENIED?"server":"self"));}
struct request {HANDLE handle;uintptr_t addr;} request;
struct reply {size_t written;} response;
#define SERVER_START_REQ(x) do { struct request* req=&request;struct reply* reply=&response;
#define SERVER_END_REQ } while(0)
static HANDLE wine_server_obj_handle(HANDLE h){return h;}
static uintptr_t wine_server_client_ptr(void* p){return (uintptr_t)p;}
static void wine_server_add_data(struct request* r,const void* b,size_t n){(void)r;(void)b;(void)n;}
static NTSTATUS wine_server_call(struct request* r){(void)r;server_calls++;response.written=0;return STATUS_ACCESS_DENIED;}
''' + fn('static BOOL ios_kw_dest_ok(')+fn('static BOOL ios_kw_store(')+fn('static int ios_wow_self_write_target(')+fn('static NTSTATUS ios_wow_write_self(')+fn('NTSTATUS WINAPI NtWriteVirtualMemory(')+r'''
int main(void){
 char name[]="/tmp/madeira-write-XXXXXX";int fd=mkstemp(name);assert(fd>=0);unlink(name);assert(!ftruncate(fd,16384));
 rw=mmap(NULL,16384,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);ro=mmap(NULL,16384,PROT_READ,MAP_SHARED,fd,0);assert(ro!=MAP_FAILED&&rw!=MAP_FAILED);close(fd);
 wow=(uintptr_t)ro-0x10000;teb.ClientId.UniqueProcess=(void*)100;memset(prot,VPROT_COMMITTED|VPROT_WRITE,sizeof(prot));
 const char patch[5]={0xe9,1,2,3,4};size_t written=99;
 assert(!NtWriteVirtualMemory(NtCurrentProcess(),ro+4094,patch,5,&written)&&written==5&&!memcmp(ro+4094,patch,5));
 assert(!server_calls && notes==1);assert(!NtWriteVirtualMemory((void*)8,ro+200,patch,5,NULL));
 alias_on=0;assert(NtWriteVirtualMemory(NtCurrentProcess(),ro+200,patch,5,&written)==STATUS_ACCESS_VIOLATION&&written==0);alias_on=1;
 memcpy(rw+100,"123456789",9);assert(!NtWriteVirtualMemory(NtCurrentProcess(),ro+102,ro+100,5,&written));assert(!memcmp(ro+100,"121234589",9));
 // A real handle must authorize VM_WRITE and refer to this logical Wine PID.
 rights=0;assert(NtWriteVirtualMemory((void*)8,ro+200,patch,5,&written)==STATUS_ACCESS_DENIED&&written==0);
 rights=PROCESS_VM_WRITE;pid=200;assert(NtWriteVirtualMemory((void*)8,ro+200,patch,5,&written)==STATUS_ACCESS_DENIED);
 pid=100;queryfail=1;assert(NtWriteVirtualMemory((void*)8,ro+200,patch,5,&written)==STATUS_ACCESS_DENIED);queryfail=0;
 // A writable 4 KB sibling cannot authorize a read-only target on the same 16 KB host page, even with an alias.
 memset(rw+8190,0,5);prot[2]=VPROT_COMMITTED;
 assert(NtWriteVirtualMemory(NtCurrentProcess(),ro+8190,patch,5,&written)==STATUS_ACCESS_VIOLATION&&written==0);
 assert(!memcmp(ro+8190,"\0\0\0\0\0",5));prot[2]=VPROT_COMMITTED|VPROT_WRITE|VPROT_GUARD;
 assert(NtWriteVirtualMemory(NtCurrentProcess(),ro+8190,patch,5,&written)==STATUS_ACCESS_VIOLATION);
 prot[2]=VPROT_WRITE;assert(NtWriteVirtualMemory(NtCurrentProcess(),ro+8190,patch,5,&written)==STATUS_ACCESS_VIOLATION);
 memset(prot,VPROT_COMMITTED|VPROT_WRITECOPY,sizeof(prot));assert(!NtWriteVirtualMemory(NtCurrentProcess(),ro+8190,patch,5,&written));
 assert(NtWriteVirtualMemory(NtCurrentProcess(),ro+200,(void*)1,5,&written)==STATUS_PARTIAL_COPY&&written==0);
 assert(!ios_wow_self_write_target(NtCurrentProcess(),(void*)(wow-1),5));
 assert(!ios_wow_self_write_target(NtCurrentProcess(),(void*)(wow+IOS_WOW_WINDOW_SIZE-2),5));
 wow=0;assert(NtWriteVirtualMemory(NtCurrentProcess(),ro+200,patch,5,&written)==STATUS_ACCESS_DENIED);
 assert(!pthread_mutex_trylock(&virtual_mutex));pthread_mutex_unlock(&virtual_mutex);
 munmap(ro,16384);munmap(rw,16384);
 puts("PASS actual WoW self-write: old server denial retained for native/foreign/unauthorized targets; valid self handles write through RX/RW aliases, per-guest-page permissions, cross-page writes, guards, overflow and failure atomicity");
}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t)/'check.c';p.write_text(code);exe=Path(t)/'check'
 subprocess.run([os.environ.get('CC','cc'),'-std=gnu11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-fno-sanitize-recover=all','-pthread',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
w=(root/'wine/dlls/wow64/virtual.c').read_text()
a=w.index('NTSTATUS WINAPI wow64_NtFlushInstructionCache(');b=w.index('\n}',a)
assert 'pBTCpuFlushInstructionCache2( addr, size )' in w[a:b]
assert 'get_process_port() and write_process_memory() unchanged' in (root/'build/wineserver/mach_ios.c').read_text()
