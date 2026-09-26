#!/usr/bin/env python3
"""Compile the production non-suspending sampler with fault-injecting Mach queries."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root/'build/ntdll-unix/server_ios.c').read_text()
start = source.index('static void ios_cpu_diagnostics(void)')
body = source[start:source.index('\n}', start)+2]
code = r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
typedef unsigned mach_msg_type_number_t;
typedef unsigned *thread_act_array_t;
typedef void *thread_info_t;
typedef uintptr_t vm_address_t;
typedef uintptr_t fake_pthread_t;
typedef int fake_mutex_t;
#define pthread_t fake_pthread_t
#define pthread_mutex_t fake_mutex_t
#define PTHREAD_MUTEX_INITIALIZER 0
#define KERN_SUCCESS 0
#define THREAD_IDENTIFIER_INFO 1
#define THREAD_BASIC_INFO 2
#define THREAD_EXTENDED_INFO 3
#define THREAD_IDENTIFIER_INFO_COUNT 1
#define THREAD_BASIC_INFO_COUNT 1
#define THREAD_EXTENDED_INFO_COUNT 1
#define IOS_FRAME_ROLE_MAX 3
typedef struct { uint64_t thread_id; } thread_identifier_info_data_t;
typedef struct { struct { unsigned seconds,microseconds; } user_time,system_time; int run_state; } thread_basic_info_data_t;
typedef struct { char pth_name[64]; } thread_extended_info_data_t;
static uint64_t ios_frame_role_tid[3] = {100,200,400};
static uint64_t clock_ns = 1000000000ull;
static unsigned count = 2, query_calls, releases, arrays, logs, threads_error, info_error;
static uint64_t cpu_ns[300], ids[300];
static uint64_t ios_frame_now_ns(void) { return clock_ns; }
/* ml2000 [spin-probe] hook (covered by check-ml2000-splitlock.py): must see only held ports. */
static unsigned spin_probe_calls;
static void ios_spin_probe(const uint64_t *i, const unsigned *p, const uint64_t *d, unsigned n, uint64_t e)
{ (void)i; (void)d; assert(e && n); for (unsigned k = 0; k < n; k++) assert(p[k]); spin_probe_calls++; }
static int pthread_mutex_trylock(fake_mutex_t *m) { if(*m) return 1; *m=1; return 0; }
static void pthread_mutex_unlock(fake_mutex_t *m) { assert(*m); *m=0; }
static int mach_task_self(void) { return 1; }
static fake_pthread_t pthread_from_mach_thread_np(unsigned port) { return ids[port-1]; }
static int task_threads(int task,thread_act_array_t *p,unsigned *n)
{
    query_calls++;
    if (threads_error) return 1;
    *p=malloc(count * sizeof(unsigned)); assert(*p); *n=count;
    for(unsigned i=0;i<count;i++) (*p)[i]=i+1;
    return 0;
}
static int thread_info(unsigned port,int kind,void *out,unsigned *n)
{
    if(info_error == port) return 1;
    if(kind == 1) ((thread_identifier_info_data_t*)out)->thread_id=ids[port-1];
    if(kind == 2) {
        thread_basic_info_data_t *b=out; memset(b,0,sizeof(*b));
        b->user_time.seconds=cpu_ns[port-1]/1000000000ull;
        b->user_time.microseconds=(cpu_ns[port-1]%1000000000ull)/1000;
        b->run_state=1;
    }
    if(kind == 3) memset(out,'x',sizeof(thread_extended_info_data_t)); /* not terminated */
    return 0;
}
static void mach_port_deallocate(int task,unsigned port) { releases++; }
static void vm_deallocate(int task,uintptr_t p,size_t bytes) { arrays++; free((void*)p); }
static void wine_log_write(const char *fmt, ...)
{
    char out[1024]; va_list args; va_start(args,fmt); vsnprintf(out,sizeof(out),fmt,args); va_end(args);
    assert(strlen(out)<sizeof(out)-1); logs++;
}
''' + body + r'''
int main(void)
{
    ids[0]=100; ids[1]=200;
    ios_cpu_diagnostics(); assert(!query_calls);
    setenv("MADEIRA_CPU_DIAGNOSTICS","1",1);
    ios_cpu_diagnostics(); assert(query_calls==1 && releases==2 && arrays==1 && !logs);
    clock_ns+=5000000000ull; ios_cpu_diagnostics(); assert(query_calls==1);
    clock_ns+=5000000000ull; cpu_ns[0]=1000000000ull; cpu_ns[1]=2000000000ull;
    ios_cpu_diagnostics(); assert(query_calls==2 && releases==4 && logs==3);
    /* Recycled port with new identity must establish a baseline, not subtract old CPU. */
    ids[0]=300; cpu_ns[0]=1000; cpu_ns[1]+=1000000000ull; clock_ns+=10000000000ull;
    ios_cpu_diagnostics(); assert(logs==5 && releases==6);
    info_error=2; clock_ns+=10000000000ull; ios_cpu_diagnostics(); assert(releases==8 && arrays==4);
    threads_error=1; clock_ns+=10000000000ull; ios_cpu_diagnostics(); assert(releases==8 && arrays==4);
    threads_error=info_error=0;
    /* Capacity overflow and thread churn remain bounded; every returned port is released. */
    count=300; for(unsigned i=0;i<count;i++) { ids[i]=1000+i; cpu_ns[i]=1000; }
    ios_cpu_diagnostics(); assert(releases==308 && arrays==5);
    clock_ns+=10000000000ull;
    for(unsigned i=0;i<count;i++) cpu_ns[i]+=1000000000ull;
    ios_cpu_diagnostics(); assert(releases==608 && arrays==6);
    setenv("MADEIRA_CPU_DIAGNOSTICS","0",1);
    clock_ns+=10000000000ull; ios_cpu_diagnostics(); assert(releases==608);
    puts("PASS: production CPU sampler cadence, ID reuse, query failures, port cleanup, 300-thread capacity and rollback");
}
'''
assert 'thread_suspend(' not in body and 'thread_get_state(' not in body
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp)
    (path/'test.c').write_text(code)
    subprocess.run(['clang', '-D_POSIX_C_SOURCE=200809L', '-std=c11', '-O1', '-g',
                    '-fsanitize=address,undefined', str(path/'test.c'), '-o', str(path/'test')], check=True)
    subprocess.run([str(path/'test')], check=True)
