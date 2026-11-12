#!/usr/bin/env python3
"""Run the production remote heap handlers with real Metal objects and mock RPC."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
dxmt=Path(os.environ.get('DXMT_SOURCE',root/'dxmt'))
host=(root/'research/remote-metal/host/rmetald.m').read_text()
start=host.index('        case RM_OP_HEAP_CREATE: {')
end=host.index('        case RM_OP_HEAP_TEXTURE_SIZE: {',start)
cases=host[start:end]
pre=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include "protocol.h"
#include "winemetal.h"
static id objects[8]; static unsigned count=1; static uint32_t result; static uint64_t returned;
static uint64_t rm_intern(id object) { if (!object) return 0; objects[++count]=object; return count; }
static id rm_resolve(uint64_t h,uint32_t *err) { if(h>=8 || !objects[h]) { *err=RM_ERR_BAD_HANDLE; return nil; } *err=RM_OK; return objects[h]; }
static void reply(int fd,const struct rm_hdr *h,uint32_t status,const void *data,uint32_t len) { (void)fd;(void)h;result=status; returned=len>=8?*(const uint64_t*)data:0; }
static void invoke(uint16_t op,void *payload,uint32_t len) { int fd=0; uint32_t err=RM_OK; struct rm_hdr h={.payload_len=len}; switch(op) {
'''
end_src=r'''
} }
int main(void) { @autoreleasepool {
 id<MTLDevice> d=MTLCreateSystemDefaultDevice(); if(!d) return 77; objects[1]=d;
 struct { struct rm_wmt_info head; struct WMTHeapInfo info; } p={0};
 p.head=(struct rm_wmt_info){1,sizeof(p.info),0}; p.info.size=1<<20; p.info.options=(enum WMTResourceOptions)MTLResourceStorageModePrivate;
 invoke(RM_OP_HEAP_CREATE,&p,sizeof(p)-1); assert(result==RM_ERR_SHORT_PAYLOAD);
 p.head.owner=7; invoke(RM_OP_HEAP_CREATE,&p,sizeof(p)); assert(result==RM_ERR_BAD_HANDLE);
 p.head.owner=1; invoke(RM_OP_HEAP_CREATE,&p,sizeof(p)); if(result!=RM_OK) return 77;
 uint64_t heap=returned; assert(heap && [objects[heap] conformsToProtocol:@protocol(MTLHeap)]);
 struct rm_heap_new_buffer b={heap,UINT64_MAX,4096,MTLResourceStorageModePrivate};
 invoke(RM_OP_HEAP_NEW_PRIVATE_BUFFER,&b,sizeof(b)-1); assert(result==RM_ERR_SHORT_PAYLOAD);
 invoke(RM_OP_HEAP_NEW_PRIVATE_BUFFER,&b,sizeof(b)); assert(result==RM_OK && returned && [objects[returned] conformsToProtocol:@protocol(MTLBuffer)]);
 MTLHeapDescriptor *shared=[MTLHeapDescriptor new]; shared.size=1<<20; shared.storageMode=MTLStorageModeShared;
 id<MTLHeap> s=[d newHeapWithDescriptor:shared]; if(s) { uint64_t sh=rm_intern(s); b.heap=sh; invoke(RM_OP_HEAP_NEW_PRIVATE_BUFFER,&b,sizeof(b)); assert(result==RM_ERR_WRONG_CLASS); }
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-private-heap-') as t:
 exe=Path(t)/'test'
 subprocess.run(['xcrun','-sdk','macosx','clang','-fobjc-arc','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=pre+cases+end_src,text=True,check=True)
 status=subprocess.run([str(exe)]).returncode
 if status==77: print('private heap Metal test skipped: no compatible device')
 elif status: raise SystemExit(status)
 else: print('remote heap creation and private buffer handler pass')
source=(dxmt/'src/winemetal/unix/winemetal_unix.c').read_text()
start=source.index('static NTSTATUS\n_MTLDevice_newHeap('); end=source.index('\n\nstatic NTSTATUS\n_MTLDevice_heapBufferSizeAndAlign',start)
create=source[start:end]
start=source.index('static NTSTATUS\n_MTLHeap_newBuffer('); end=source.index('\n\nstatic NTSTATUS\n_MTLHeap_newTexture',start)
new_buffer=source[start:end]
start=source.index('static NTSTATUS _MTLHeap_newBuffer_wow64('); end=source.index('\n#endif',start)
wow=source[start:end]
start=source.index('#define WMT_WOW64_POINTER_WRAPPER(name, type, field)');end=source.index('\n\nWMT_WOW64_POINTER_WRAPPER(',start)
wrapper=source[start:end]
client=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include "protocol.h"
#include "winemetal.h"
typedef uint64_t obj_handle_t; typedef uint32_t NTSTATUS;
#define STATUS_SUCCESS 0u
#define STATUS_UNSUCCESSFUL 0xc0000001u
#define STATUS_INVALID_PARAMETER 0xc000000du
#define STATUS_NOT_IMPLEMENTED 0xc0000002u
struct unixcall_mtldevice_newheap { obj_handle_t device; struct WMTMemoryPointer info; obj_handle_t ret; };
struct unixcall_mtlheap_newbuffer { obj_handle_t heap; struct WMTMemoryPointer info; uint64_t offset; obj_handle_t ret; };
static unsigned char guest[1024]; static unsigned calls,registered; static uint32_t status;
static void *UInt32ToPtr(uint32_t p) { return p?guest+p:NULL; }
static int wmtr_enabled(void) { return 1; }
static void wmtr_buf_add(uint64_t h,void *p,uint64_t n,uint32_t opts,int cpu,int owned) { assert(h==42 && !p && n==4096 && opts==32 && !cpu && !owned); registered++; }
static uint32_t wmtr_call(uint16_t op,const void *arg,uint32_t len,void *out,uint32_t outlen,uint32_t *got) {
 (void)got; calls++;
 if(op==RM_OP_HEAP_CREATE) {
  assert(len==sizeof(struct rm_wmt_info)+sizeof(struct WMTHeapInfo) && outlen==sizeof(struct rm_ret_handle));
  const struct rm_wmt_info *h=arg; const struct WMTHeapInfo *i=(const void*)(h+1); assert(h->owner==3 && i->size==65536);
  *(struct rm_ret_handle*)out=(struct rm_ret_handle){17};
 } else { assert(op==RM_OP_HEAP_NEW_PRIVATE_BUFFER && len==sizeof(struct rm_heap_new_buffer) && outlen==sizeof(struct rm_ret_handle_u64));
  const struct rm_heap_new_buffer *b=arg; assert(b->heap==17 && b->length==4096 && b->options==32);
  *(struct rm_ret_handle_u64*)out=(struct rm_ret_handle_u64){42,1234}; }
 return status;
}
'''
client_end=r'''
int main(void) { @autoreleasepool {
 struct WMTHeapInfo *heap=(void *)(guest+32); heap->size=65536;
 struct unixcall_mtldevice_newheap h={0}; h.device=3; h.info.ptr=(void *)(uintptr_t)32;
 assert(_MTLDevice_newHeap_wow64(&h)==STATUS_SUCCESS && h.ret==17 && h.info.ptr==(void *)(uintptr_t)32);
 struct WMTBufferInfo *info=(void *)(guest+128); info->length=4096; info->options=(enum WMTResourceOptions)32;
 struct unixcall_mtlheap_newbuffer b={0}; b.heap=17; b.info.ptr=(void *)(uintptr_t)128; b.offset=UINT64_MAX;
 assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_SUCCESS && b.ret==42 && !info->memory.ptr && info->gpu_address==1234 && registered==1);
 status=RM_ERR_BAD_OPCODE; assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_UNSUCCESSFUL && b.ret==0 && registered==1);
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-private-heap-client-') as t:
 exe=Path(t)/'test'
 code=client+create+new_buffer+'\n'+wrapper+'\nWMT_WOW64_POINTER_WRAPPER(_MTLDevice_newHeap, unixcall_mtldevice_newheap, info)\n'+wow+client_end
 subprocess.run(['xcrun','-sdk','macosx','clang','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=code,text=True,check=True)
 subprocess.run([str(exe)],check=True)
print('remote heap clients and 32-bit wrappers pass')
