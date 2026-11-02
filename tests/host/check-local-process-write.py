#!/usr/bin/env python3
"""Exercise the production Mach writer with real local memory and opt-in guards."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'build/wineserver/mach_ios.c'
text = source.read_text()
start = text.index('int write_process_memory(')
function = text[start:text.index('\n}', start) + 2]
code = r'''
#include <assert.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define WINE_IOS 1
typedef uint64_t client_ptr_t;
typedef uint32_t data_size_t;
#define STATUS_ACCESS_DENIED 1
#define STATUS_NO_MEMORY 2
struct process { mach_port_t trace_data; pid_t unix_pid; };
static unsigned error;
static void set_error(unsigned value) { error=value; }
static void mach_set_error(kern_return_t value) { if (value) error=value; }
static mach_port_t get_process_port(struct process *p) { return p->trace_data; }
static size_t get_page_size(void) { return (size_t)sysconf(_SC_PAGESIZE); }
static int is_rosetta(void) { return 0; }
''' + function + r'''
int main(void)
{
    struct process local={0, getpid()}, foreign={0, getpid()+1};
    char target[32]={0}; const char payload[]="local write fixture";
    data_size_t written=99;
    unsetenv("MADEIRA_LOCAL_PROCESS_WRITE");
    assert(!write_process_memory(&local,(uintptr_t)target,sizeof(payload),payload,&written));
    assert(error==STATUS_ACCESS_DENIED && written==0 && target[0]==0);
    setenv("MADEIRA_LOCAL_PROCESS_WRITE","1",1); error=0;
    assert(write_process_memory(&local,(uintptr_t)target,sizeof(payload),payload,&written));
    assert(written==sizeof(payload) && !memcmp(target,payload,sizeof(payload)));
    assert(!write_process_memory(&foreign,(uintptr_t)target,sizeof(payload),payload,&written));
    assert(error==STATUS_ACCESS_DENIED && written==0);
    setenv("MADEIRA_LOCAL_PROCESS_WRITE","yes",1); error=0;
    assert(!write_process_memory(&local,(uintptr_t)target,sizeof(payload),payload,&written));
    assert(error==STATUS_ACCESS_DENIED && written==0);
    setenv("MADEIRA_LOCAL_PROCESS_WRITE","1",1); error=0;
    assert(!write_process_memory(&local,0,sizeof(payload),payload,&written));
    assert(error && written==0);
    puts("PASS: local opt-in writes bytes; default, invalid opt-in, foreign PID and invalid address are denied");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-local-write-') as temporary:
    directory=Path(temporary)
    (directory/'check.c').write_text(code)
    subprocess.run(['cc','-std=c11','-Wall','-Werror','-fsanitize=address,undefined',
                    str(directory/'check.c'),'-o',str(directory/'check')],check=True)
    subprocess.run([str(directory/'check')],check=True)
