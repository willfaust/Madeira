#!/usr/bin/env python3
"""Compile the real assertion observer and fault-safe guest32 origin reader."""
from pathlib import Path
import os, subprocess, tempfile
root=Path(__file__).resolve().parents[2]
signal=(root/'build/ntdll-unix/signal_arm64_ios.c').read_text()
start=signal.index('void ios_cef_assert_context(void)');end=signal.index('\n}\n',start)+3
context=signal[start:end]
code=r'''
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "windef.h"
#include "winternl.h"
typedef uint64_t mach_vm_size_t,mach_vm_address_t;
#define KERN_SUCCESS 0
_Alignas(16) static unsigned char native[0x5000],area[0x80],frame[0x100],guest[0x10000];
static TEB *NtCurrentTeb(void) {return (TEB*)native;}
static uintptr_t ios_wow_base(void) {return 0x600000000ull;}
static int mach_task_self(void) {return 1;}
static int deny;
static int mach_vm_read_overwrite(int task,uint64_t a,uint64_t n,uint64_t dst,uint64_t *got) {
 assert(task==1);*got=0;if(deny)return 1;
 const void *p=NULL;
 struct {uintptr_t a;size_t n;} regions[]={{(uintptr_t)native,sizeof(native)},{(uintptr_t)area,sizeof(area)},{(uintptr_t)frame,sizeof(frame)}};
 for(unsigned i=0;i<3;i++)if(a>=regions[i].a && n<=regions[i].n && a-regions[i].a<=regions[i].n-n)p=(void*)(uintptr_t)a;
 if(a>=ios_wow_base() && n<=sizeof(guest) && a-ios_wow_base()<=sizeof(guest)-n)p=guest+(a-ios_wow_base());
 if(!p)return 1;memcpy((void*)(uintptr_t)dst,p,n);*got=n;return 0;
}
static char output[32768];static size_t used;
static int capture(int fd,const char *fmt,...) {assert(fd==2);va_list ap;va_start(ap,fmt);int n=vsnprintf(output+used,sizeof(output)-used,fmt,ap);va_end(ap);assert(n>=0 && (size_t)n<sizeof(output)-used);used+=n;errno=EBADF;return n;}
#define dprintf capture
static int path_calls;
static int ios_guest_log_fd_path(int fd,char *path,size_t size) {path_calls++;errno=EINTR;snprintf(path,size,"/private/account/debug.log");return fd==7;}
''' + signal[signal.index('static int ios_g32_read('):signal.index('/* Read the current thread') ] + context + r'''
#include "cef_log_context.h"
static void put64(unsigned char *p,uint64_t v) {memcpy(p,&v,8);}
static void put32(unsigned char *p,uint32_t v) {memcpy(p,&v,4);}
int main(void) {
 _Static_assert(offsetof(TEB,ClientId.UniqueProcess)==0x40 && offsetof(TEB,Peb)==0x60,"native TEB ABI");
 TEB *teb=NtCurrentTeb();PEB peb={0};RTL_USER_PROCESS_PARAMETERS params={0};
 const char *exe="C:/Steam/bin/cef/cef.win7/steamwebhelper.exe";WCHAR path[100];unsigned len=strlen(exe);for(unsigned i=0;i<len;i++)path[i]=exe[i];
 params.ImagePathName.Buffer=path;params.ImagePathName.Length=len*2;peb.ProcessParameters=&params;teb->Peb=&peb;teb->ClientId.UniqueProcess=(void*)0x64;teb->ClientId.UniqueThread=(void*)0x68;
 teb->TlsSlots[14]=area;put64(area,(uintptr_t)frame);put64(frame+0x18,0x401234);put64(frame+0x40,0x1800);
 put32(native+0x180c,0x2000);put32(native+0x2030,0x1100);put32(guest+0x110c,0x1200);put32(guest+0x120c,0x1300);
 put32(guest+0x1300,0x120c);put32(guest+0x1318,0x400000);put32(guest+0x1320,0x100000);guest[0x132c]=20;put32(guest+0x1330,0x1500);
 const char *mod="libcef.dll";for(unsigned i=0;i<10;i++)guest[0x1500+i*2]=mod[i];put32(guest+0x1800,0x401234);put32(guest+0x1804,0xdeadbeef);
 const char *before="[100:104:1030/233545.1:VERBOSE1:viz.cc(88)] private-url-secret\n";
 errno=EAGAIN;ios_cef_log_observe(7,before,strlen(before));assert(errno==EAGAIN);
 const char *assertion="[1030/233546.058:ERROR:check.cc(376)] Check failed: false. NOTREACHED\n";
 ios_cef_log_observe(7,assertion,strlen(assertion));
 assert(strstr(output,"before=1 source=[100:104"));assert(strstr(output,"candidate=libcef.dll+0x1234"));
 assert(!strstr(output,"private-url-secret") && !strstr(output,"deadbeef") && !strstr(output,"/private/account"));
 for(unsigned i=0;i<12;i++)ios_cef_log_observe(7,before,strlen(before));
 assert(strstr(output,"after=8 source="));assert(!strstr(output,"after=9 source="));
 // An unreadable saved CPU frame remains unresolved and does not dereference it.
 deny=1;errno=EAGAIN;ios_cef_assert_context();assert(errno==EAGAIN);assert(strstr(output,"context unavailable"));deny=0;
 size_t old=used;ios_cef_log_observe(8,assertion,strlen(assertion));assert(used==old);
 ios_cef_log_observe(7,assertion,strlen(assertion));old=used;ios_cef_log_observe(7,assertion,strlen(assertion));assert(used==old);
 puts("PASS real CEF observer: adjacent source tags, guest32 module candidates, unreadable contexts, privacy, event bounds and errno");
}
'''
# Avoid a test-only naming collision with Wine's NtCurrentTeb inline implementation.
code=code.replace('static TEB *NtCurrentTeb(void)', 'static TEB *test_current_teb(void)').replace('return (TEB*)native;}','return (TEB*)native;}\n#define NtCurrentTeb test_current_teb')
with tempfile.TemporaryDirectory() as tmp:
 src=Path(tmp)/'main.c';binary=Path(tmp)/'check';src.write_text(code)
 subprocess.run([os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror','-Wno-misleading-indentation','-fsanitize=address,undefined','-fno-sanitize-recover=all','-I',str(root/'wine/include'),'-I',str(root/'build/ntdll-unix'),str(src),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
