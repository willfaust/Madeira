#!/usr/bin/env python3
"""Check the real failure census against synthetic mappings and attribution overflow."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root/'build/ntdll-unix/virtual_ios.c').read_text()
start = source.index('static void ios_wow_va_census(')
body = source[start:source.index('\n}', start)+2]
code = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
typedef uintptr_t ULONG_PTR;
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define IOS_WOW_GUEST_FLOOR 0x110000
#define IOS_WOW_WINDOW_SIZE 0x100000000ull
#define IOS_WOW_ARENA_CHUNK 0x4000000
#define SEC_IMAGE 0x1000000
#define SEC_FILE 0x800000
#define VPROT_COMMITTED 0x20
#define limit_2g 0x80000000ull
struct file_view { void *base; size_t size; unsigned protect,madeira_creator_tid; };
static struct file_view mappings[200];
static unsigned mapping_count;
static int madeira_va_diagnostics;
static uintptr_t ios_wow_base(void) { return 0x7100000000ull; }
static uintptr_t get_wow_user_space_limit(void) { return 0xffff0000ull; }
static int ios_view_is_builtin(void *p) { return 0; }
#define WINE_RB_FOR_EACH_ENTRY(v,t,ty,e) for(unsigned vi=0; vi<mapping_count && ((v=&mappings[vi]),1); vi++)
static char output[32000];
static void report(int fd,const char *fmt,...)
{
    va_list args; va_start(args,fmt);
    size_t n=strlen(output); vsnprintf(output+n,sizeof(output)-n,fmt,args);
    va_end(args);
}
#define dprintf report
''' + body + r'''
static void run(void) {
    output[0]=0;
    ios_wow_va_census((void*)(ios_wow_base()+0x110000),(void*)(ios_wow_base()+IOS_WOW_WINDOW_SIZE),0x230000);
}
int main(void)
{
    mapping_count=3;
    for(unsigned i=0;i<3;i++) mappings[i]=(struct file_view){(void*)(ios_wow_base()+0x200000+i*0x400000),0x200000,VPROT_COMMITTED,0x100};
    run(); assert(!strstr(output,"[va-origin]"));
    madeira_va_diagnostics=1;
    run(); assert(strstr(output,"tid=0100 size=0x200000 live=3 bytes=6144KiB"));
    mappings[2].protect=SEC_IMAGE;
    run(); assert(strstr(output,"live=2 bytes=4096KiB"));
    mappings[1].size=0x10000;
    run(); assert(strstr(output,"live=1 bytes=2048KiB"));
    mapping_count=200;
    for(unsigned i=0;i<200;i++) mappings[i]=(struct file_view){(void*)(ios_wow_base()+0x200000+i*0x400000),0x100000,VPROT_COMMITTED,i+1};
    run(); assert(strstr(output,"tracked-pairs=128 overflow=73728KiB"));
    mapping_count=0; run(); assert(strstr(output,"tracked-pairs=0 overflow=0KiB"));
    puts("PASS: production VA census exact grouping, file/small exclusion, empty window, overflow and rollback");
}
'''
assert 'new_view->madeira_creator_tid = view->madeira_creator_tid;' in source
with tempfile.TemporaryDirectory() as tmp:
    path=Path(tmp)
    (path/'test.c').write_text(code)
    subprocess.run(['clang', '-std=c11', '-O1', '-g', '-fsanitize=address,undefined',
                    str(path/'test.c'), '-o', str(path/'test')], check=True)
    subprocess.run([str(path/'test')], check=True)
