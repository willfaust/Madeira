#!/usr/bin/env python3
"""Execute the read-only CEF state probe with exact identity/opcode gates."""
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
static unsigned char image[0xb42a000];static unsigned reads;static int denied;
static const uint32_t base=0x10000000;static const uint64_t window=0x500000000ULL;
static int ios_g32_read(uint64_t a,void* p,size_t n){reads++;if(denied||a<window+base||a-window-base>sizeof(image)||n>sizeof(image)-(a-window-base))return 0;memcpy(p,image+a-window-base,n);return 1;}
static char output[4096];static int capture(int fd,const char* fmt,...){assert(fd==2);va_list ap;va_start(ap,fmt);int n=vsnprintf(output,sizeof(output),fmt,ap);va_end(ap);return n;}
#define dprintf capture
#include "guest32_origin.h"
#include "cef_atexit_context.h"
static void u16(unsigned a,uint16_t n){memcpy(image+a,&n,2);}static void u32(unsigned a,uint32_t n){memcpy(image+a,&n,4);}
int main(void){
 u16(0,0x5a4d);u32(0x3c,0x80);u32(0x80,0x4550);u16(0x86,2);u16(0x94,0xe0);u16(0x98,0x10b);
 u32(0x128,0xa900000);u32(0x12c,28);u32(0xa90000c,2);u32(0xa900010,24);u32(0xa900014,0xa900100);
 u32(0xa900100,0x53445352);const unsigned char guid[]={0x5b,0x3c,0x13,0x4d,0xbe,0x4f,0x47,0x41,0x4c,0x4c,0x44,0x20,0x50,0x44,0x42,0x2e};memcpy(image+0xa900104,guid,16);u32(0xa900114,1);
 u32(0x180,0x9600000);u32(0x184,0x1000);u32(0x19c,0x60000020);
 u32(0x1a8,0xb2a000);u32(0x1ac,0xa900000);u32(0x1c4,0xc0000040);
 unsigned char helper[]={0x55,0x89,0xe5,0x8b,0x45,0x10,0x8b,0x4d,0x0c,0x8b,0x55,0x08,0x89,0x0a,0x85,0xc9,0x0f,0x94,0xc1,0x85,0xc0,0x0f,0x94,0xc2,0x08,0xca,0x75,0x0c,0xff,0x75,0x14,0x50,0xe8,0xcb,0x83,0,0,0x83,0xc4,8,0x5d,0xc3};memcpy(image+0xdf4990,helper,sizeof(helper));
 unsigned c=0xdfcd80;image[c+0x61]=0x8b;image[c+0x62]=0x35;u32(c+0x63,base+0xac00000);image[c+0x67]=0x85;image[c+0x68]=0xf6;image[c+0x69]=0x74;image[c+0x6a]=0x49;
 image[c+0xb4]=0xe8;u32(c+0xb5,0x592f960-(c+0xb9));
 unsigned a=0x8e44e7;image[a+1]=0xbf;u32(a+2,base+0xac00010);image[a+47]=0x57;image[a+48]=0x68;u32(a+49,base+0x8e6ac0);image[a+53]=0x68;u32(a+54,base+0xac00014);image[a+58]=0x57;image[a+59]=0xe8;u32(a+60,0xdf4990-0x8e4527);
 u32(0xac00010,base+0xac00014);
 struct ios_g32_origin g={0};g.window=window;g.count=1;g.modules[0].base=base;g.modules[0].size=sizeof(image);strcpy(g.modules[0].name,"libcef.dll");
 struct ios_cef_atexit_state s;assert(ios_cef_atexit_capture(&g,&g.modules[0],&s));assert(s.top_rva==0xac00000&&!s.top&&s.lazy==s.object);
 ios_cef_atexit_report(&g);assert(strstr(output,"manager-null=1")&&strstr(output,"published=1"));assert(reads<200);
 u32(0xac00000,0x12340000);assert(ios_cef_atexit_capture(&g,&g.modules[0],&s)&&s.top==0x12340000); // object never dereferenced
 image[0xa900104]^=1;assert(!ios_cef_atexit_capture(&g,&g.modules[0],&s));image[0xa900104]^=1;
 u32(0xa900114,2);assert(!ios_cef_atexit_capture(&g,&g.modules[0],&s));u32(0xa900114,1);
 image[0xdf4990]^=1;assert(!ios_cef_atexit_capture(&g,&g.modules[0],&s));image[0xdf4990]^=1;
 u32(c+0x63,base+0x1000);assert(!ios_cef_atexit_capture(&g,&g.modules[0],&s));u32(c+0x63,base+0xac00000);
 u32(c+0xb5,0);assert(!ios_cef_atexit_capture(&g,&g.modules[0],&s));u32(c+0xb5,0x592f960-(c+0xb9));
 image[a+59]=0x90;assert(!ios_cef_atexit_capture(&g,&g.modules[0],&s));image[a+59]=0xe8;
 denied=1;assert(!ios_cef_atexit_capture(&g,&g.modules[0],&s));denied=0;
 puts("PASS CEF read-only AtExit probe: exact PDB, code, branch target and section gates; manager null/non-null and published singleton observed; mismatched/unreadable inputs fail closed");
}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t)/'test.c';p.write_text(code);exe=Path(t)/'test'
 subprocess.run([os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror','-Wno-unused-function','-Wno-misleading-indentation','-fsanitize=address,undefined','-fno-sanitize-recover=all','-I'+str(root/'build/ntdll-unix'),str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
