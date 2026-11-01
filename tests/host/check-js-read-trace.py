#!/usr/bin/env python3
"""Real staged read watcher: offsets, reused buffers, ownership and interval coverage."""
from pathlib import Path
import subprocess,tempfile,shutil
root=Path(__file__).resolve().parents[2]
header=root/'build/ntdll-unix/js_read_trace.h'
source=r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
typedef void *HANDLE;typedef unsigned long ULONG;typedef unsigned int UINT;
typedef union {long long QuadPart;} LARGE_INTEGER;
typedef struct {void *Peb;} TEB;
static TEB teb={(void *)0x400000000};
#define NtCurrentTeb() (&teb)
#include "HEADER"
static struct ios_js_entry *entry(void *owner,HANDLE handle) {
 for(unsigned i=0;i<IOS_JSTRACK_MAX;i++)if(ios_js_track[i].owner==(uintptr_t)owner&&ios_js_track[i].handle==handle&&ios_js_track[i].generation)return &ios_js_track[i];
 return NULL;
}
static void sample(int fd,HANDLE handle,unsigned char *buffer,int length,long long off) {
 LARGE_INTEGER offset={.QuadPart=off};assert(pread(fd,buffer,length,off)==length);
 errno=EAGAIN;ios_js_read_note(handle,fd,buffer,length,length,&offset);assert(errno==EAGAIN);
}
int main(int argc,char **argv) {
 assert(argc==2);char name[1024],other[1024];snprintf(name,sizeof(name),"%s/steamui-library.js",argv[1]);snprintf(other,sizeof(other),"%s/steamui-other.js",argv[1]);
 int fd=open(name,O_CREAT|O_RDWR,0600),fd2=open(other,O_CREAT|O_RDWR,0600);assert(fd>=0&&fd2>=0);assert(!ftruncate(fd,100)&&!ftruncate(fd2,100));
 HANDLE handle=(HANDLE)0x88;unsigned char buffer[128];errno=EAGAIN;ios_js_track_add(handle,name);assert(errno==EAGAIN);
 struct ios_js_entry *first=entry(teb.Peb,handle);assert(first);uint64_t generation=first->generation;
 for(int i=0;i<3;i++){int n=i==2?20:40;assert(read(fd,buffer,n)==n);ios_js_read_note(handle,fd,buffer,n,n,NULL);}
 assert(first->bytes==100&&first->unknown_bytes==100&&ios_js_known_bytes(first)==0);
 sample(fd,handle,buffer,60,0);sample(fd,handle,buffer,60,0);assert(ios_js_known_bytes(first)==60);
 sample(fd,handle,buffer,20,80);assert(ios_js_known_bytes(first)==80);
 sample(fd,handle,buffer,40,40);assert(ios_js_known_bytes(first)==100&&first->range_count==1&&!first->coverage_incomplete);
 LARGE_INTEGER current={.QuadPart=-2};ios_js_read_note(handle,fd,buffer,1,1,&current);assert(first->unknown_bytes==101);
 uint64_t bytes=first->bytes;ios_js_read_note(handle,fd2,buffer,1,1,NULL);assert(first->bytes==bytes);
 teb.Peb=(void *)0x500000000;ios_js_read_note(handle,fd,buffer,1,1,NULL);assert(first->bytes==bytes);
 ios_js_track_add(handle,name);struct ios_js_entry *second=entry(teb.Peb,handle);assert(second&&second!=first&&second->generation!=generation);
 sample(fd,handle,buffer,10,10);assert(ios_js_known_bytes(second)==10&&ios_js_known_bytes(first)==100);
 teb.Peb=(void *)0x400000000;ios_js_track_add(handle,other);assert(first->generation!=generation&&first->bytes==0&&ios_js_known_bytes(first)==0);
 generation=first->generation;assert(!ftruncate(fd2,200));sample(fd2,handle,buffer,10,0);assert(first->size==200&&first->generation!=generation&&ios_js_known_bytes(first)==10);
 struct ios_js_entry clipped={.size=10000};for(unsigned i=0;i<65;i++)ios_js_add_range(&clipped,3*i,3*i+1);assert(clipped.coverage_incomplete&&ios_js_known_bytes(&clipped)==64);
 close(fd);close(fd2);puts("PASS current-position reads never claim coverage; duplicates/out-of-order/gaps merge correctly; process/handle generations isolated; errno and range bounds preserved");
}
'''.replace('HEADER',str(header))
with tempfile.TemporaryDirectory() as t:
 p=Path(t)/'check.c';p.write_text(source);exe=Path(t)/'check'
 subprocess.run([shutil.which('clang') or 'cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-fno-omit-frame-pointer','-pthread',str(p),'-o',str(exe)],check=True)
 out=subprocess.run([str(exe),t],check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True).stdout
 assert 'offset=current-position' in out and 'file-offset-coverage-complete=1' in out
 assert 'off=-1' not in out and 'fully read' not in out and 'NOT contiguous' not in out
 print(out,end='')
# Run the actual build.sh staging transformation against the pinned Wine file.
build=(root/'build/ntdll-unix/build.sh').read_text();a=build.index('source, output, header = map(Path, sys.argv[1:])');b=build.index('\nPYCODE',a)
with tempfile.TemporaryDirectory() as t:
 output=Path(t)/'file.c';namespace={'Path':Path,'sys':type('Args',(),{'argv':['stage',str(root/'wine/dlls/ntdll/unix/file.c'),str(output),str(root/'build/ntdll-unix/io_status_trace.h')]})}
 exec(build[a:b],namespace)
 staged=output.read_text();assert str(header) in staged and '[js-watch] %s fully read' not in staged and 'ios_srcwatch_arm_for' not in staged
 print('PASS actual Wine staging replaces the obsolete buffer-contiguity tracker; pinned Wine file remains untouched')
