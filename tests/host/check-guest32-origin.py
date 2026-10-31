#!/usr/bin/env python3
"""Execute bounded guest stack/symbol capture and the staged target-handle resolver."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
code=r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
static unsigned char guest[0x60000],frame[0x100];static unsigned reads;static int denied;
static const uint64_t window=0x600000000ULL;
static int ios_g32_read(uint64_t a,void* out,size_t n){
 reads++;if(denied)return 0;
 if(a>=(uintptr_t)frame&&a-(uintptr_t)frame<=sizeof(frame)&&n<=sizeof(frame)-(a-(uintptr_t)frame)){memcpy(out,(void*)(uintptr_t)a,n);return 1;}
 if(a>=window&&a-window<=sizeof(guest)&&n<=sizeof(guest)-(a-window)){memcpy(out,guest+(a-window),n);return 1;}return 0;
}
static char output[65536];static size_t used;
static int capture(int fd,const char* fmt,...){assert(fd==2);va_list ap;va_start(ap,fmt);int n=vsnprintf(output+used,sizeof(output)-used,fmt,ap);va_end(ap);assert(n>=0&&(size_t)n<sizeof(output)-used);used+=n;return n;}
#define dprintf capture
#include "guest32_origin.h"
static void u16(unsigned p,uint16_t v){assert(p+2<=sizeof(guest));memcpy(guest+p,&v,2);}
static void u32(unsigned p,uint32_t v){assert(p+4<=sizeof(guest));memcpy(guest+p,&v,4);}
static void reg(unsigned p,uint64_t v){memcpy(frame+p,&v,8);}
int main(void){
 // Native TEB is at guest offset 0x10000; TEB32 at offset 0x12000.
 u32(0x1180c,0x2000);u32(0x12000,0x18010);u32(0x12004,0x19000);u32(0x12008,0x18000);u32(0x12030,0x13000);
 u32(0x1300c,0x14000);u32(0x1400c,0x15000);u32(0x15000,0x1400c);u32(0x15018,0x20000);u32(0x15020,0x20000);
 u16(0x1502c,20);u32(0x15030,0x16000);const char* dll="libcef.dll";for(unsigned i=0;i<10;i++)u16(0x16000+2*i,dll[i]);
 reg(0x18,0x21124);reg(0x40,0x18000);reg(0x48,0x18020);
 u32(0x18000,0x21155);u32(0x18004,0xdeadbeef);u32(0x18010,0xffffffff);u32(0x18014,0x21180);
 u32(0x18020,0x18030);u32(0x18024,0x21177);u32(0x18030,0x18020);u32(0x18034,0x21188); // cyclic frame chain
 u16(0x20000,0x5a4d);u32(0x2003c,0x80);u32(0x20080,0x4550);u16(0x20086,1);u32(0x20088,0x12345678);
 u16(0x20094,0xe0);u16(0x20098,0x10b);u32(0x200d8,0xabcdef);
 // .text and a CodeView symbol identity with a private build path.
 u32(0x20180,0x5000);u32(0x20184,0x1000);u32(0x2019c,0x60000020);guest[0x21123]=0xcc;
 u32(0x20128,0x7000);u32(0x2012c,28);u32(0x2700c,2);u32(0x27010,80);u32(0x27014,0x7100);
 u32(0x27100,0x53445352);for(unsigned i=0;i<16;i++)guest[0x27104+i]=i;u32(0x27114,2);
 strcpy((char*)guest+0x27118,"C:\\private\\builder\\libcef.pdb");
 // An exported target resolves without confusing it with a private symbol.
 u32(0x200f8,0x8000);u32(0x200fc,0x100);u32(0x28014,1);u32(0x28018,1);u32(0x2801c,0x8100);u32(0x28020,0x8200);u32(0x28024,0x8300);
 u32(0x28100,0x1100);u32(0x28200,0x8400);u16(0x28300,0);strcpy((char*)guest+0x28400,"ExportedTarget");
 struct ios_g32_origin g;assert(ios_g32_capture(&g,window+0x10000,window,(uintptr_t)frame));
 ios_g32_report(&g,"breakpoint",0x21100);
 assert(strstr(output,"rip+0=libcef.dll+0x1124"));assert(strstr(output,"libcef.dll+0x1123 bytes=cc"));
 assert(strstr(output,"nearest-export=ExportedTarget+0"));
 assert(strstr(output,"stack-candidate+0=libcef.dll+0x1155"));assert(strstr(output,"ebp-return+0=libcef.dll+0x1177"));
 assert(strstr(output,"[guest32-callsite-v1] tag=breakpoint frame=0 return=libcef.dll+0x1177 code=libcef.dll+0x1137 bytes="));
 assert(strstr(output,"seh-handler+0=libcef.dll+0x1180"));assert(!strstr(output,"deadbeef"));
 assert(strstr(output,"pdb=libcef.pdb guid=030201000504070608090A0B0C0D0E0F age=2"));assert(!strstr(output,"private")&&!strstr(output,"builder"));
 size_t before=used;ios_g32_callsite(&g,"cef-assert",0,0x28400);assert(used==before); // data cannot be captured
 ios_g32_callsite(&g,"cef-assert",0,0x21002);assert(strstr(output,"code=libcef.dll+0x1000 bytes=")); // clamp to executable section
 denied=1;before=used;ios_g32_callsite(&g,"cef-assert",0,0x21177);assert(used==before);denied=0;
 assert(reads<2000);unsigned old=reads;u32(0x15000,0x15000);assert(ios_g32_capture(&g,window+0x10000,window,(uintptr_t)frame));assert(reads-old<150);
 // Malformed offsets, unreadable state and out-of-window TEB32 fail closed.
 denied=1;assert(!ios_g32_capture(&g,window+0x10000,window,(uintptr_t)frame));denied=0;
 u32(0x1180c,0x7fffffff);assert(!ios_g32_capture(&g,window+0x10000,window,(uintptr_t)frame));
 puts("PASS actual guest32 capture: owning window, module/RVA/nearest export, INT3 bytes, bounded EBP/SEH/stack candidates, PE/PDB identity, private path removal and malformed/unreadable data");
}
'''
def run(src,name,cpp=False):
 with tempfile.TemporaryDirectory() as t:
  p=Path(t)/(name+'.c');p.write_text(src);exe=Path(t)/name
  subprocess.run([os.environ.get('CC','cc'),'-std=gnu11','-Wall','-Wextra','-Werror','-Wno-misleading-indentation','-fsanitize=address,undefined','-fno-sanitize-recover=all','-I'+str(root/'build/ntdll-unix'),str(p),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)
run(code,'origin')
with tempfile.TemporaryDirectory() as t:
 subprocess.run(['python3',str(root/'tools/build/stage-io-status-abi.py'),'stage',t],check=True)
 s=(Path(t)/'dlls/wow64/syscall.c').read_text();a=s.index('ULONG_PTR wow_guest_base_for_process(');b=s.index('\n}',a)+2
 run(r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
typedef uintptr_t ULONG_PTR;typedef void* HANDLE;
#define GetCurrentProcess() ((void*)(intptr_t)-1)
#define ProcessWineIosWowGuestBase 1010
static uintptr_t wow_guest_base=0x400000000, target=0x500000000;
static unsigned queries;static int failed;
static int NtQueryInformationProcess(HANDLE h,int c,void* p,size_t n,void* r){(void)h;(void)r;assert(c==1010&&n==sizeof(target));queries++;*(uintptr_t*)p=target;return failed;}
''' + s[a:b] + r'''
int main(void){
 assert(wow_guest_base_for_process(GetCurrentProcess())==wow_guest_base&&!queries);
 assert(wow_guest_base_for_process((void*)8)==0x500000000&&queries==1);
 target=0x700000000;assert(wow_guest_base_for_process((void*)8)==target&&queries==2);
 failed=1;assert(!wow_guest_base_for_process((void*)8)&&queries==3);
 failed=0;target=0;assert(!wow_guest_base_for_process((void*)8)&&queries==4);
 wow_guest_base=0;assert(!wow_guest_base_for_process((void*)8)&&queries==4);
 puts("PASS actual staged WoW target resolver: recycled handle gets the new owner, query/native-target failure never borrows the caller window, self requires no query");
}
''','target')
# Execute the actual native process-info branch with an old process object
# whose PEB address has been reused by a live owner.
p=(root/'build/ntdll-unix/process_ios.c').read_text();a=p.index('    case ProcessWineIosWowGuestBase:');b=p.index('    case ProcessImageFileName:',a)
run(r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
typedef uintptr_t ULONG_PTR;typedef void* HANDLE;
#define ProcessWineIosWowGuestBase 1010
#define STATUS_INFO_LENGTH_MISMATCH 1
#define GetCurrentProcess() ((void*)(intptr_t)-1)
struct request {HANDLE handle;} request;
struct reply {uint64_t end_time;uintptr_t peb;} response;
#define SERVER_START_REQ(x) do {struct request* req=&request;struct reply* reply=&response;
#define SERVER_END_REQ }while(0)
static unsigned bindings;static int fail;
static HANDLE wine_server_obj_handle(HANDLE h){return h;}
static void* wine_server_get_ptr(uintptr_t p){return (void*)p;}
static unsigned wine_server_call(struct request* r){(void)r;return fail;}
static uintptr_t ios_wow_base(void){return 0x400000000;}
static uintptr_t ios_wow_base_for_peb(void* p){assert(p==(void*)0x600310000);bindings++;return 0x600000000;}
static unsigned query(HANDLE handle,void* info,size_t size){unsigned ret=0;size_t len;switch(1010){
''' + p[a:b] + r'''
}return ret;}
int main(void){
 uintptr_t value=0;response.peb=0x600310000;
 assert(!query((void*)8,&value,sizeof(value))&&value==0x600000000&&bindings==1);
 response.end_time=123;value=99;
 assert(!query((void*)8,&value,sizeof(value))&&!value&&bindings==1);
 puts("PASS actual native target query rejects a retired process even when its PEB address is reused by a live owner");
}
''','retired')
