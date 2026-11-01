#!/usr/bin/env python3
"""Compile the actual WoW64 affinity conversion and native thread-attribute consumer."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
def function(s,marker):
 a=s.index(marker);return s[a:s.index('\n}',a)+2]
with tempfile.TemporaryDirectory() as t:
 d=Path(t);path=d/'dlls/wow64/process.c';path.parent.mkdir(parents=True)
 path.write_bytes((root/'wine/dlls/wow64/process.c').read_bytes())
 subprocess.run(['git','-C',str(d),'apply',str(root/'build/ntdll-unix/wow-affinity-attribute.patch')],check=True)
 staged=path.read_text();begin=staged.index('        case PS_ATTRIBUTE_GROUP_AFFINITY:')
 case=staged[begin:staged.index('        case PS_ATTRIBUTE_CLIENT_ID:',begin)]
 native=(root/'build/ntdll-unix/thread_ios.c').read_text();begin=native.index('    case ThreadGroupInformation:',native.index('NTSTATUS WINAPI NtSetInformationThread('))
 validation=native[begin:native.index('\n    case ',begin+5)]
 consumer=function(native,'static NTSTATUS update_attr_list(')
 wrapper=function(staged,'NTSTATUS WINAPI wow64_NtCreateThreadEx(')
 helpers=(root/'wine/dlls/wow64/wow64_private.h').read_text();helper=function(helpers,'static inline void *guest_ptr32(')
 system=(root/'build/ntdll-unix/virtual_ios.c').read_text();mask=function(system,'ULONG_PTR get_system_affinity_mask(')
 code=r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <setjmp.h>
typedef uint32_t ULONG,NTSTATUS;typedef int32_t LONG;typedef uintptr_t ULONG_PTR;typedef size_t SIZE_T;typedef uint16_t WORD;typedef uintptr_t KAFFINITY;typedef void* HANDLE;
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER 0xc000000du
#define STATUS_ACCESS_VIOLATION 0xc0000005u
#define STATUS_NO_MEMORY 0xc0000017u
#define STATUS_ACCESS_DENIED 0xc0000022u
#define ThreadGroupInformation 30
#define SET_THREAD_INFO_AFFINITY 1
#define PS_ATTRIBUTE_CLIENT_ID 3
#define PS_ATTRIBUTE_TEB_ADDRESS 4
#define PS_ATTRIBUTE_GROUP_AFFINITY 5
#define WINAPI
#define min(a,b) ((a)<(b)?(a):(b))
#define HandleToULong(p) ((ULONG)(uintptr_t)(p))
typedef struct { ULONG Mask; WORD Group,Reserved[3]; } GROUP_AFFINITY32;
typedef struct { KAFFINITY Mask; WORD Group,Reserved[3]; } GROUP_AFFINITY;
typedef struct { ULONG Attribute,Size,Value,ReturnLength; } PS_ATTRIBUTE32;
typedef struct { ULONG TotalLength;PS_ATTRIBUTE32 Attributes[1]; } PS_ATTRIBUTE_LIST32;
typedef struct { ULONG_PTR Attribute,Size;union {ULONG_PTR Value;void* ValuePtr;};SIZE_T* ReturnLength; } PS_ATTRIBUTE;
typedef struct { ULONG_PTR TotalLength;PS_ATTRIBUTE Attributes[1]; } PS_ATTRIBUTE_LIST;
typedef struct { HANDLE UniqueProcess,UniqueThread; } CLIENT_ID;
typedef struct { unsigned unused; } TEB;
static struct { ULONG NumberOfProcessors; } process_peb={6};
static __typeof__(process_peb)* peb=&process_peb;
static struct {ULONG LastErrorValue;CLIENT_ID ClientId;} teb;
#define NtCurrentTeb() (&teb)
static ULONG_PTR wow_guest_base;
static LONG InterlockedIncrement(LONG* p){return ++*p;}
static unsigned logs,validator_calls,terminated,closed;static NTSTATUS termination_status;
static HANDLE seen_handle;static ULONG_PTR accepted_mask;
static jmp_buf raised;static NTSTATUS raised_status;static int fail_alloc;static unsigned native_creates;
static _Noreturn void RtlRaiseStatus(NTSTATUS status){raised_status=status;longjmp(raised,1);}
static void log_trace(const char* fmt,...){(void)fmt;logs++;teb.LastErrorValue=999;}
#define ERR(...) log_trace(__VA_ARGS__)
static _Alignas(16) unsigned char temp[64];
static void* Wow64AllocateTemp(SIZE_T n){assert(n==sizeof(GROUP_AFFINITY));if(fail_alloc)return NULL;memset(temp,0xa5,sizeof(temp));return temp;}
struct request {HANDLE handle;ULONG_PTR affinity;unsigned mask;};static struct request request;
#define SERVER_START_REQ(x) do { struct request* req=&request;
#define SERVER_END_REQ } while(0)
static HANDLE wine_server_obj_handle(HANDLE h){return h;}
static NTSTATUS wine_server_call(struct request* r){seen_handle=r->handle;accepted_mask=r->affinity;return 0;}
''' + helper + '\n' + mask + r'''
static NTSTATUS NtSetInformationThread(HANDLE handle,unsigned class,const void* data,SIZE_T length){
 NTSTATUS status;
 validator_calls++;
 switch(class){
''' + validation + r'''
 default:return STATUS_INVALID_PARAMETER;
 }
}
static NTSTATUS NtTerminateThread(HANDLE thread,NTSTATUS status){seen_handle=thread;terminated++;termination_status=status;return 0;}
static NTSTATUS NtClose(HANDLE thread){seen_handle=thread;closed++;return 0;}
''' + consumer + r'''
static void convert(PS_ATTRIBUTE_LIST* ret,const PS_ATTRIBUTE_LIST32* attr32){
 unsigned i=0;ret->TotalLength=sizeof(*ret);ret->Attributes[0].Attribute=attr32->Attributes[0].Attribute;
 ret->Attributes[0].Size=attr32->Attributes[0].Size;ret->Attributes[0].Value=attr32->Attributes[0].Value;
 ret->Attributes[0].ReturnLength=NULL;
 switch(ret->Attributes[0].Attribute){
''' + case + r'''
 default:assert(0);
 }
}
typedef ULONG UINT,ACCESS_MASK;typedef void* PRTL_THREAD_START_ROUTINE;typedef struct {int unused;} OBJECT_ATTRIBUTES32;
struct object_attr64 {int unused;};
static PS_ATTRIBUTE_LIST32* wrapper_attrs;static ULONG wrapper_handle;
static ULONG get_ulong(UINT** args){return *(*args)++;}
static void* get_ptr(UINT** args){ULONG p=get_ulong(args);if(p==0x100)return &wrapper_handle;if(p==0x200)return wrapper_attrs;return guest_ptr32(p);}
static HANDLE get_handle(UINT** args){return (void*)(intptr_t)(int32_t)get_ulong(args);}
static int is_process_wow64(HANDLE p){return p==(void*)(intptr_t)-1;}
static ULONG_PTR get_zero_bits(ULONG_PTR bits){return bits;}
static void* objattr_32to64(struct object_attr64* out,const OBJECT_ATTRIBUTES32* in){(void)out;assert(!in);return NULL;}
static void put_handle(ULONG* out,HANDLE handle){*out=(ULONG)(uintptr_t)handle;}
static PS_ATTRIBUTE_LIST* ps_attributes_32to64(PS_ATTRIBUTE_LIST** out,const PS_ATTRIBUTE_LIST32* in){static PS_ATTRIBUTE_LIST native;convert(&native,in);*out=&native;return &native;}
static void put_ps_attributes(PS_ATTRIBUTE_LIST32* in,const PS_ATTRIBUTE_LIST* out,HANDLE process){(void)in;(void)out;(void)process;}
static NTSTATUS NtCreateThreadEx(HANDLE* out,ACCESS_MASK access,void* oa,HANDLE process,PRTL_THREAD_START_ROUTINE start,void* param,ULONG flags,ULONG_PTR zero,SIZE_T commit,SIZE_T reserve,PS_ATTRIBUTE_LIST* attr){
 (void)access;(void)oa;(void)process;(void)start;(void)param;(void)flags;(void)zero;(void)commit;(void)reserve;native_creates++;
 CLIENT_ID id={(void*)0x1f0,(void*)0x2a0};TEB dummy={0};*out=(void*)0x3c8;return update_attr_list(attr,*out,&id,&dummy);
}
''' + wrapper + r'''
static NTSTATUS run(PS_ATTRIBUTE_LIST32* source){
 PS_ATTRIBUTE_LIST target;CLIENT_ID id={(void*)0x1f0,(void*)0x2a0};TEB dummy={0};
 teb.LastErrorValue=123;convert(&target,source);assert(teb.LastErrorValue==123);
 return update_attr_list(&target,(void*)0x3c8,&id,&dummy);
}
int main(void){
 _Static_assert(sizeof(GROUP_AFFINITY32)==12,"guest layout");_Static_assert(sizeof(GROUP_AFFINITY)==16,"native layout");
 _Static_assert(offsetof(GROUP_AFFINITY32,Group)==4,"guest group offset");_Static_assert(offsetof(GROUP_AFFINITY,Group)==8,"native group offset");
 // Negative control: the old pointer-only conversion reads adjacent 32-bit
 // data as native Reserved[1/2] and rejects an otherwise valid affinity.
 _Alignas(16) unsigned char old[16];memset(old,0xa5,sizeof(old));GROUP_AFFINITY32 guest={1,0,{0,0,0}};memcpy(old,&guest,12);
 assert(NtSetInformationThread((void*)0x3c8,ThreadGroupInformation,old,16)==STATUS_INVALID_PARAMETER);
 // The actual conversion can read a 12-byte input at the last bytes of a
 // readable page. The next page is inaccessible: native-width reads would fault.
 size_t page=(size_t)sysconf(_SC_PAGESIZE);unsigned char* maps=mmap(NULL,page*2,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);assert(maps!=MAP_FAILED);
 assert(!mprotect(maps+page,page,PROT_NONE));GROUP_AFFINITY32* g=(void*)(maps+page-12);*g=guest;
 wow_guest_base=(uintptr_t)maps-0x10000;PS_ATTRIBUTE_LIST32 attrs={sizeof(attrs),{{PS_ATTRIBUTE_GROUP_AFFINITY,12,(ULONG)((uintptr_t)g-wow_guest_base),0}}};
 assert(!mprotect(maps,page,PROT_READ));
 assert(!run(&attrs)&&!terminated&&!closed&&accepted_mask==1&&seen_handle==(void*)0x3c8);
 assert(!memcmp(g,&guest,12));assert(logs==1);
 // Execute the actual WoW64 NtCreateThreadEx wrapper. Its converter is an
 // argument to the native call: allocation failure raises NO_MEMORY before
 // any native thread can be created or terminated.
 wrapper_attrs=&attrs;UINT args[]={0x100,0,0,0xffffffff,0,0,0,0,0,0,0x200};
 fail_alloc=1;unsigned old_creates=native_creates,old_kills=terminated;
 if(!setjmp(raised)){wow64_NtCreateThreadEx(args);assert(0);}assert(raised_status==STATUS_NO_MEMORY);
 assert(native_creates==old_creates&&terminated==old_kills);fail_alloc=0;
 assert(!wow64_NtCreateThreadEx(args)&&native_creates==old_creates+1&&wrapper_handle==0x3c8);
 // Every reported processor can be selected and masks remain zero-extended.
 assert(!mprotect(maps,page,PROT_READ|PROT_WRITE));
 for(unsigned cpu=0;cpu<6;cpu++){g->Mask=1u<<cpu;assert(!run(&attrs)&&accepted_mask==(1u<<cpu));}
 unsigned kills=terminated;
 g->Mask=0;assert(run(&attrs)==STATUS_INVALID_PARAMETER);g->Mask=64;assert(run(&attrs)==STATUS_INVALID_PARAMETER);
 g->Mask=1;g->Group=1;assert(run(&attrs)==STATUS_INVALID_PARAMETER);g->Group=0;
 for(unsigned i=0;i<3;i++){g->Reserved[i]=1;assert(run(&attrs)==STATUS_INVALID_PARAMETER);g->Reserved[i]=0;}
 assert(terminated==kills+6&&closed==terminated&&termination_status==STATUS_INVALID_PARAMETER);
 // Invalid source sizes (including native-size 16) must not touch the source
 // pointer. Native attribute-size validation rejects before reading ValuePtr.
 attrs.Attributes[0].Value=(ULONG)((uintptr_t)(maps+page)-wow_guest_base);
 unsigned before=validator_calls;
 for(unsigned size=0;size<=20;size+=4){if(size==12)continue;attrs.Attributes[0].Size=size;assert(run(&attrs)==STATUS_INVALID_PARAMETER);}
 assert(validator_calls==before);
 attrs.Attributes[0].Value=0;attrs.Attributes[0].Size=12;assert(run(&attrs)==STATUS_ACCESS_VIOLATION);
 PS_ATTRIBUTE_LIST bad={sizeof(bad),{{PS_ATTRIBUTE_GROUP_AFFINITY,12,{.ValuePtr=maps+page},NULL}}};CLIENT_ID id={0};
 assert(update_attr_list(&bad,(void*)0x3c8,&id,NULL)==STATUS_INVALID_PARAMETER&&validator_calls==before+1);
 attrs.Attributes[0].Value=(ULONG)((uintptr_t)g-wow_guest_base);attrs.Attributes[0].Size=12;
 for(unsigned i=0;i<20;i++)assert(!run(&attrs));assert(logs==16);
 munmap(maps,page*2);
 puts("PASS actual affinity attribute conversion/native consumer: old valid-mask rejection reproduced; 12-byte page-edge input widens safely to 16 bytes; CPU bits, group/reserved/zero/out-of-range/size/null rejections, real failure termination, handle and LastError/budget preserved");
}
'''
 p=d/'check.c';p.write_text(code);exe=d/'check'
 subprocess.run([os.environ.get('CC','cc'),'-std=gnu11','-Wall','-Wextra','-Werror','-Wno-misleading-indentation','-fsanitize=address,undefined','-fno-sanitize-recover=all',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
