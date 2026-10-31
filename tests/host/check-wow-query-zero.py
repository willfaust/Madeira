#!/usr/bin/env python3
"""Execute the production WoW64 query branch against distinct host/guest maps."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as t:
 d=Path(t);subprocess.run(['python3',str(root/'tools/build/stage-io-status-abi.py'),'stage',str(d/'wine')],check=True)
 source=(d/'wine/dlls/wow64/virtual.c').read_text()
 start=source.index('NTSTATUS WINAPI wow64_NtQueryVirtualMemory(')
 body=source[start:source.index('    case MemoryMappedFilenameInformation:  /* MEMORY_SECTION_NAME */',start)]
 body+='''    default: return STATUS_INVALID_INFO_CLASS;
    }
    if (!status || status == STATUS_INFO_LENGTH_MISMATCH) put_size( retlen, res_len );
    return status;
}'''
 header=(d/'wine/dlls/wow64/wow64_private.h').read_text()
 def fn(marker):
  a=header.index(marker);return header[a:header.index('\n}',a)+2]
 helpers='\n'.join(fn(x) for x in ['static inline void *guest_ptr32(', 'static inline ULONG host_ptr32(',
 'static inline ULONG host_ptr32_in(', 'static inline void *retarget_ptr('])
 code=r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
typedef uint32_t UINT,ULONG,NTSTATUS;typedef int32_t LONG;typedef uintptr_t ULONG_PTR;typedef size_t SIZE_T;typedef void* HANDLE;
#define WINAPI
#define STATUS_INFO_LENGTH_MISMATCH 0xc0000004u
#define STATUS_INVALID_PARAMETER 0xc000000du
#define STATUS_INVALID_INFO_CLASS 0xc0000003u
#define STATUS_ACCESS_DENIED 0xc0000022u
typedef enum {MemoryBasicInformation,MemoryMappedFilenameInformation,MemoryRegionInformation,
 MemoryWorkingSetExInformation,MemoryImageInformation} MEMORY_INFORMATION_CLASS;
typedef struct {void* BaseAddress;void* AllocationBase;ULONG AllocationProtect;SIZE_T RegionSize;ULONG State,Protect,Type;} MEMORY_BASIC_INFORMATION;
typedef struct {ULONG BaseAddress,AllocationBase,AllocationProtect,RegionSize,State,Protect,Type;} MEMORY_BASIC_INFORMATION32;
static ULONG_PTR wow_guest_base=0x600000000ull,highest_user_address=0x7ffeffff;
static const ULONG_PTR target_window=0x500000000ull;
static MEMORY_BASIC_INFORMATION32 output;static ULONG retlen;
static struct {ULONG LastErrorValue;} teb;
#define NtCurrentTeb() (&teb)
static unsigned queries,logs;static int deny;static HANDLE seen_handle;static uintptr_t seen_address;
static void capture(const char* format,...){(void)format;logs++;teb.LastErrorValue=999;}
#define ERR(...) capture(__VA_ARGS__)
static LONG InterlockedIncrement(LONG* p){return ++*p;}
''' + helpers + r'''
static ULONG get_ulong(UINT** args){return *(*args)++;}
static HANDLE get_handle(UINT** args){return (void*)(intptr_t)(int32_t)get_ulong(args);}
static void* get_ptr(UINT** args){ULONG a=get_ulong(args);if(a==0x200)return &output;if(a==0x204)return &retlen;return guest_ptr32(a);}
static void put_size(ULONG* p,SIZE_T n){if(p)*p=(ULONG)n;}
static ULONG_PTR wow_guest_base_for_process(HANDLE h){if(h==(void*)8)return target_window;if(h==(void*)(intptr_t)-1)return wow_guest_base;return 0;}
static NTSTATUS NtQueryVirtualMemory(HANDLE h,void* a,MEMORY_INFORMATION_CLASS c,void* b,SIZE_T n,SIZE_T* result){
 assert(c==MemoryBasicInformation&&n==sizeof(MEMORY_BASIC_INFORMATION));queries++;seen_handle=h;seen_address=(uintptr_t)a;
 if(deny)return STATUS_ACCESS_DENIED;
 MEMORY_BASIC_INFORMATION* info=b;memset(info,0,sizeof(*info));if(result)*result=n;
 uintptr_t window=h==(void*)8?target_window:wow_guest_base;
 if(!a){
  // Actual iOS map floor exceeds the entire guest's 2 GB user range.
  info->BaseAddress=0;info->RegionSize=0x100a94000ull;info->State=0x2000;info->Protect=1;return 0;
 }
 assert((uintptr_t)a>=window&&(uintptr_t)a-window<=0xffffffffull);
 uintptr_t guest=(uintptr_t)a-window;if(guest>highest_user_address)return STATUS_INVALID_PARAMETER;
 info->BaseAddress=a;info->AllocationBase=a;
 if(guest<0x10000){info->RegionSize=0x10000-guest;info->State=0x2000;info->Protect=1;}
 else if(guest<0x40000){info->RegionSize=0x40000-guest;info->State=0x1000;info->Protect=4;}
 else {info->RegionSize=highest_user_address+1-guest;info->State=0x10000;info->Protect=1;}
 return 0;
}
''' + body + r'''
static NTSTATUS query(uint32_t handle,uint32_t address,uint32_t length){
 UINT args[]={handle,address,MemoryBasicInformation,0x200,length,0x204};return wow64_NtQueryVirtualMemory(args);
}
static unsigned walk(uint32_t handle){
 uint64_t address=0;unsigned committed=0,count=0;
 while(address<=highest_user_address){
  assert(count++<8);assert(!query(handle,address,sizeof(output)));assert(output.BaseAddress==address&&output.RegionSize);
  if(output.State==0x1000)committed++;address+=output.RegionSize;
 }
 return committed;
}
int main(void){
 // Reproduce the old NULL-preserving pointer conversion. It returns a
 // host reservation covering the whole guest range and skips its heap.
 MEMORY_BASIC_INFORMATION native;
 assert(!NtQueryVirtualMemory((void*)8,NULL,MemoryBasicInformation,&native,sizeof(native),NULL));
 assert(native.RegionSize>highest_user_address&&native.State!=0x1000);
 assert(!retarget_ptr(target_window,NULL));assert(!guest_ptr32(0)); // preserve optional-pointer semantics
 teb.LastErrorValue=123;
 assert(!query(8,0,sizeof(output)));assert(seen_address==target_window&&seen_handle==(void*)8);
 assert(output.BaseAddress==0&&output.RegionSize==0x10000&&output.Protect==1&&retlen==sizeof(output));
 assert(teb.LastErrorValue==123&&logs==1);
 assert(walk(8)==1);assert(walk(0xffffffff)==1); // cross-process and self maps both enumerate the heap
 highest_user_address=0xffffffff;assert(walk(8)==1);assert(walk(0xffffffff)==1); // full LAA window never produces a zero-size region
 highest_user_address=0x7ffeffff;
 assert(!query(8,0x10000,sizeof(output)));assert(seen_address==target_window+0x10000&&output.BaseAddress==0x10000&&output.State==0x1000);
 unsigned before=queries;retlen=0;
 assert(query(8,0x80000000,sizeof(output))==STATUS_INVALID_PARAMETER&&queries==before);
 assert(query(8,0,sizeof(output)-1)==STATUS_INFO_LENGTH_MISMATCH&&retlen==sizeof(output));
 deny=1;retlen=0x1234;assert(query(8,0,sizeof(output))==STATUS_ACCESS_DENIED&&retlen==0x1234&&teb.LastErrorValue==123);deny=0;
 for(unsigned i=0;i<20;i++)assert(!query(8,0,sizeof(output)));assert(logs==12);
 puts("PASS actual staged WoW64 query: old host-NULL map skips guest memory, query-zero now uses self/target window and enumerates readable heap; nonzero pointers, optional NULL, limits, handle, NTSTATUS, length, error state and bounded diagnostics preserved");
}
'''
 src=d/'query.c';src.write_text(code);exe=d/'query'
 subprocess.run([os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror','-Wno-misleading-indentation','-fsanitize=address,undefined','-fno-sanitize-recover=all',str(src),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
