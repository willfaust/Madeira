#!/usr/bin/env python3
"""Exercise remote heap aliases, upload failures, and concurrent CPU/GPU changes."""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
dxmt = Path(os.environ.get('DXMT_SOURCE', root / 'dxmt'))
source = (dxmt / 'src/winemetal/unix/wmt_remote_client.h').read_text()
types = source[source.index('struct wmtr_heap {'):source.index('\n/* Upload only what CHANGED.')]
registry = source[source.index('#define WMTR_BUF_CHUNK'):source.index('\nstatic int wmtr_buf_lookup(uint64_t handle, struct wmtr_buf *out);')]
logic = source[source.index('static int wmtr_heap_attach('):source.index('\n/* ---- ml821:', source.index('static int wmtr_heap_attach('))]
pre = r'''
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include "protocol.h"
#define WMT_HEAP_AUTO_SHADOW (UINT64_C(1) << 63)
static uint8_t host[65536];
static int fail_upload, uploads;
static uint64_t handle_offset(uint64_t handle) { assert(handle == 2 || handle == 3); return handle == 2 ? 0 : 4096; }
static int wmtr_buf_upload(uint64_t handle, const void *src, uint64_t offset, uint64_t length) {
 if (fail_upload) return -1;
 uploads++;
 assert(handle_offset(handle)+offset+length<=sizeof(host)); memcpy(host+handle_offset(handle)+offset,src,length);return 0;
}
static uint32_t wmtr_call(uint16_t op,const void *input,uint32_t len,void *out,uint32_t cap,uint32_t *got) {
 if (op==RM_OP_BUFFER_UPLOAD_MULTI) {
  const struct rm_buffer_range *ranges;const uint8_t *data;
  assert(rm_multi_ok(input,len,&ranges,&data));if(fail_upload)return RM_ERR_SHORT_PAYLOAD;
  const struct rm_buffer_multi *h=input;size_t off=0;uploads++;
  for(unsigned i=0;i<h->count;i++) {assert(handle_offset(ranges[i].handle)+ranges[i].offset+ranges[i].length<=sizeof(host));
   memcpy(host+handle_offset(ranges[i].handle)+ranges[i].offset,data+off,ranges[i].length);off+=ranges[i].length;}
  return RM_OK;
 }
 assert(op==RM_OP_BUFFER_READ && len==sizeof(struct rm_buffer_range));
 const struct rm_buffer_range *r=input;assert(cap==r->length && handle_offset(r->handle)+r->offset+cap<=sizeof(host));
 memcpy(out,host+handle_offset(r->handle)+r->offset,cap);*got=cap;return RM_OK;
}
'''
main = r'''
int main(void) {
 uint8_t guest[65536]={0};
 assert(!wmtr_heap_register(1,sizeof(guest)));
 wmtr_buf_add(2,guest,65536,0,1,0);assert(!wmtr_heap_attach(2,1,0,guest,65536));
 wmtr_buf_add(3,guest+4096,8192,0,1,0);assert(!wmtr_heap_attach(3,1,4096,guest+4096,8192));
 guest[4097]=0x11;guest[4098]=0x22;assert(!wmtr_heap_flush());
 assert(host[4097]==0x11 && host[4098]==0x22);
 host[4097]=0x33;guest[4098]=0x44;assert(!wmtr_heap_sync());
 assert(guest[4097]==0x33 && guest[4098]==0x44);assert(!wmtr_heap_flush());
 assert(host[4097]==0x33 && host[4098]==0x44);
 guest[120]=0x73;assert(!wmtr_heap_sync() && guest[120]==0x73);assert(!wmtr_heap_flush() && host[120]==0x73);
 guest[65535]=0x75;uploads=0;assert(!wmtr_heap_flush() && host[65535]==0x75 && uploads==1);
 for(unsigned i=0;i<65536;i+=2) guest[i]^=0xff;
 uploads=0;assert(!wmtr_heap_flush() && !memcmp(host,guest,65536) && uploads<=65);
 uint8_t before=host[4100];guest[4100]=before^0xff;fail_upload=1;assert(wmtr_heap_flush());assert(host[4100]==before);
 fail_upload=0;assert(!wmtr_heap_flush() && host[4100]==guest[4100]);
 uint8_t data[2]={0xa1,0xb2};assert(!wmtr_heap_update(3,7,data,2));assert(host[4103]==0xa1 && guest[4104]==0xb2);
 assert(wmtr_heap_update(3,UINT64_MAX,data,2));
 wmtr_heap_reference(1,0);assert(wmtr_heaps);wmtr_buf_remove(2);assert(wmtr_heaps);wmtr_buf_remove(3);assert(!wmtr_heaps);
 assert(!wmtr_heap_register(9,65536));uint64_t off=UINT64_MAX;void *native_a=wmtr_heap_native_pointer(9,&off,8192);assert(native_a && off==0);
 wmtr_buf_add(2,native_a,8192,0,1,0);assert(!wmtr_heap_attach(2,9,off,native_a,8192));
 off=UINT64_MAX;void *native_b=wmtr_heap_native_pointer(9,&off,8192);assert(native_b && off==8192 && (uint8_t *)native_b==(uint8_t *)native_a+8192);
 off=65535;assert(!wmtr_heap_native_pointer(9,&off,2));wmtr_heap_reference(9,0);wmtr_buf_remove(2);assert(!wmtr_heaps);
 return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-shared-heap-') as t:
    exe=Path(t)/'test'
    subprocess.run(['xcrun','clang','-std=c11','-D_DARWIN_C_SOURCE','-pthread','-I',str(root/'research/remote-metal'),'-x','c','-','-o',str(exe)],input=pre+types+registry+logic+main,text=True,check=True)
    subprocess.run([str(exe)],check=True)
print('remote shared heap aliases, CPU/GPU merge and failed uploads pass')
arena_test = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <pthread.h>
typedef uint64_t obj_handle_t; typedef size_t SIZE_T; typedef pthread_mutex_t SRWLOCK;
#define SRWLOCK_INIT PTHREAD_MUTEX_INITIALIZER
#define MEM_RESERVE 1
#define MEM_WRITE_WATCH 2
#define MEM_COMMIT 4
#define MEM_RELEASE 8
#define PAGE_READWRITE 0
#define WMT_HEAP_AUTO_SHADOW (UINT64_C(1) << 63)
#define AcquireSRWLockExclusive pthread_mutex_lock
#define ReleaseSRWLockExclusive pthread_mutex_unlock
static unsigned frees;
static void *VirtualAlloc(void *p,SIZE_T n,unsigned flags,unsigned protect) {
 (void)protect; return flags & MEM_RESERVE ? calloc(1,n) : p;
}
static int VirtualFree(void *p,SIZE_T n,unsigned flags) { (void)n;(void)flags;frees++;free(p);return 1; }
#include "wmt_heap_arena.h"
int main(void) {
 assert(wmt_heap_create(1,65536));void *a,*b;struct wmt_heap_buffer *ta,*tb;
 assert(wmt_heap_begin(1,0,8192,&a,&ta)==1);wmt_heap_finish(ta,2);
 assert(wmt_heap_begin(1,4096,8192,&b,&tb)==1);wmt_heap_finish(tb,3);
 ((uint8_t *)a)[4096]=0x42;assert(((uint8_t *)b)[0]==0x42);
 void *automatic;struct wmt_heap_buffer *tc;assert(wmt_heap_begin(1,UINT64_MAX,8192,&automatic,&tc)==1);
 assert((uint8_t *)automatic==(uint8_t *)a+12288 && tc->offset==12288);wmt_heap_finish(tc,0);
 assert(wmt_heap_begin(1,65535,2,&b,&tb)==-1);
 wmt_heap_reference(1,0);assert(!frees);wmt_heap_reference(2,1);wmt_heap_reference(2,0);
 wmt_heap_reference(2,0);assert(!frees);wmt_heap_reference(3,0);assert(frees==1);
 assert(wmt_heap_begin(1,0,1,&b,&tb)==0);return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-guest-heap-') as t:
    exe=Path(t)/'test'
    subprocess.run(['xcrun','clang','-std=c11','-pthread','-I',str(dxmt/'src/winemetal'),'-x','c','-','-o',str(exe)],input=arena_test,text=True,check=True)
    subprocess.run([str(exe)],check=True)
print('guest heap aliases and lifetime pass')
