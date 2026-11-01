#!/usr/bin/env python3
"""Execute the bounded MSVC x86 throw decoder without reading thrown objects."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
source=r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned char data[0x50000];static unsigned reads,object_reads;static int deny;
static uint64_t window=0x500000000ull;
static int ios_g32_read(uint64_t a,void* out,size_t n){
 reads++;if(a==window+0x26000)object_reads++;
 if(deny||a<window||a-window>sizeof(data)||n>sizeof(data)-(a-window))return 0;
 memcpy(out,data+(a-window),n);return 1;
}
static char output[16384];static size_t used;
static int capture(int fd,const char* format,...){assert(fd==2);va_list a;va_start(a,format);int n=vsnprintf(output+used,sizeof(output)-used,format,a);va_end(a);assert(n>=0&&(size_t)n<sizeof(output)-used);used+=n;return n;}
#define dprintf capture
#include "guest32_cxx.h"
static void u32(unsigned a,uint32_t v){memcpy(data+a,&v,4);}
int main(void){
 struct ios_g32_origin g={.window=0x500000000ull,.count=1};
 g.modules[0].base=0x20000;g.modules[0].size=0x20000;strcpy(g.modules[0].name,"libcef.dll");
 uint64_t p[3]={0x19930520,0x26000,0x21000};
 u32(0x2100c,0x22000);u32(0x22000,1);u32(0x22004,0x23000);u32(0x23004,0x24000);
 strcpy((char*)data+0x24008,".?AVsystem_error@std@@");strcpy((char*)data+0x26000,"AUTHSECRET");
 ios_g32_cxx_report(&g,1,window+0x28000,p,3);
 assert(strstr(output,"magic=0x19930520 object=0x26000 throwinfo=0x21000"));assert(strstr(output,"type=.?AVsystem_error@std@@"));
 assert(!strstr(output,"AUTHSECRET")&&!object_reads);
 uint32_t pointer;assert(ios_g32_cxx_pointer(&g,window+0x21000,&pointer)&&pointer==0x21000);
 assert(!ios_g32_cxx_pointer(&g,0,&pointer)&&!ios_g32_cxx_pointer(&g,0x600021000ull,&pointer));
 for(unsigned i=0;i<4;i++){
  used=0;output[0]=0;
  if(i==0)p[2]=0; // legitimate rethrow
  if(i==1){p[2]=0x21000;u32(0x22000,0xffffffff);}
  if(i==2){u32(0x22000,1);u32(0x23004,0xfffffff0);}
  if(i==3){u32(0x23004,0x24000);strcpy((char*)data+0x24008,"not a type AUTHSECRET");}
  unsigned before=reads;ios_g32_cxx_report(&g,1,window+0x28000,p,3);
  assert(!strstr(output,"cxx-type")&&!strstr(output,"AUTHSECRET")&&reads-before<120);
 }
 deny=1;ios_g32_cxx_report(&g,1,0,p,3);assert(!object_reads);
 puts("PASS actual x86 throw metadata: raw guest parameters, module-bounded RTTI types, host/guest pointer normalization, rethrows, corrupt counts/addresses, privacy and inaccessible memory");
}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t)/'test.c';p.write_text(source);exe=Path(t)/'test'
 subprocess.run([os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror','-Wno-unused-function','-Wno-misleading-indentation','-fsanitize=address,undefined','-fno-sanitize-recover=all','-I'+str(root/'build/ntdll-unix'),str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
s=(root/'build/ntdll-unix/thread_ios.c').read_text();a=s.index('NTSTATUS WINAPI NtRaiseException(');b=s.index('\n}',a)
assert s[a:b].index('ios_trace_first_cxx(rec)')<s[a:b].index('status = send_debug_event(')
