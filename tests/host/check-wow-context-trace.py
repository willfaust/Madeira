#!/usr/bin/env python3
"""Run the production capture observer with Wine's actual tagged context union."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'build/wineserver/mach_ios.c').read_text()
a=s.index('static void ios_trace_captured_context(');b=s.index('\n}',a)+2
observer=s[a:b]
p=(root/'wine/include/wine/server_protocol.h').read_text()
a=p.index('enum context_exec_space');b=p.index('\n#define SERVER_CTX_CONTROL',a)
layout=p[a:b]
code=r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#define __int64 long long
#define IMAGE_FILE_MACHINE_I386 0x14c
#define IMAGE_FILE_MACHINE_AMD64 0x8664
#define IMAGE_FILE_MACHINE_ARM64 0xaa64
#define SERVER_CTX_CONTROL 1
''' + layout + r'''
struct thread {unsigned id;uintptr_t teb;};
static char output[32768];static size_t used;static unsigned messages;
static int capture(FILE* stream,const char* fmt,...){
 assert(stream==stderr);va_list ap;va_start(ap,fmt);int n=vsnprintf(output+used,sizeof(output)-used,fmt,ap);va_end(ap);
 assert(n>=0&&(size_t)n<sizeof(output)-used);used+=n;messages++;errno=EIO;return n;
}
#define fprintf capture
''' + observer + r'''
int main(void){
 struct thread thread={0x154,0x500190000ull};struct context_data native={0},wow={0},before;
 native.ctl.arm64_regs.pc=0x246bf9370ull;native.ctl.arm64_regs.sp=0x15dacfb00ull;
 wow.machine=IMAGE_FILE_MACHINE_I386;wow.flags=0x3f;
 wow.ctl.i386_regs.eip=0x3d0000;wow.ctl.i386_regs.ebp=0xf20e3d8;wow.ctl.i386_regs.esp=0xf20e3c0;wow.ctl.i386_regs.eflags=0x287;
 // Negative control reproduces the misleading values from the old log.
 assert(wow.ctl.x86_64_regs.rip==0xf20e3d8003d0000ull&&wow.ctl.x86_64_regs.rsp==0x2870f20e3c0ull);
 before=wow;errno=EINTR;ios_trace_captured_context(&thread,&native,&wow,1);
 assert(!memcmp(&before,&wow,sizeof(wow))&&errno==EINTR);
 assert(strstr(output,"guest-machine=014c guest-flags=0000003f guest-view=i386 guest-pc=0x3d0000 guest-sp=0xf20e3c0"));
 assert(!strstr(output,"f20e3d8003d0000")&&!strstr(output,"2870f20e3c0"));
 assert(strstr(output,"native_pc=0x246bf9370 native_sp=0x15dacfb00"));
 memset(&wow,0,sizeof(wow));wow.machine=IMAGE_FILE_MACHINE_AMD64;wow.flags=SERVER_CTX_CONTROL;
 wow.ctl.x86_64_regs.rip=0x140123456ull;wow.ctl.x86_64_regs.rsp=0x7fff123456ull;before=wow;
 ios_trace_captured_context(&thread,&native,&wow,1);assert(!memcmp(&before,&wow,sizeof(wow)));
 assert(strstr(output,"guest-view=amd64 guest-pc=0x140123456 guest-sp=0x7fff123456"));
 // A missing/unknown/control-less view is unavailable, never guessed as AMD64.
 size_t mark=used;wow.machine=IMAGE_FILE_MACHINE_ARM64;ios_trace_captured_context(&thread,NULL,&wow,0);
 assert(strstr(output+mark,"guest-view=unavailable")&&!strstr(output+mark,"0x140123456"));
 mark=used;wow.machine=IMAGE_FILE_MACHINE_I386;wow.flags=0;ios_trace_captured_context(&thread,NULL,&wow,0);
 assert(strstr(output+mark,"guest-view=unavailable"));
 ios_trace_captured_context(&thread,NULL,NULL,0);
 for(unsigned i=0;i<80;i++)ios_trace_captured_context(&thread,&native,&wow,1);
 assert(messages==48&&errno==EINTR);
 puts("PASS actual context observer: old i386/AMD64 union artifact reproduced, machine/control tags choose correct PC/SP, missing/unknown contexts unavailable, state and errno unchanged, 48-event bound");
}
'''
with tempfile.TemporaryDirectory() as t:
 src=Path(t)/'check.c';src.write_text(code);exe=Path(t)/'check'
 subprocess.run([os.environ.get('CC','cc'),'-std=gnu11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-fno-sanitize-recover=all',str(src),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
