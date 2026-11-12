#!/usr/bin/env python3
"""Run the production remote heap handlers with real Metal objects and mock RPC."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
dxmt=Path(os.environ.get('DXMT_SOURCE',root/'dxmt'))
host=(root/'research/remote-metal/host/rmetald.m').read_text()
start=host.index('        case RM_OP_HEAP_NEW_TEXTURE: {')
end=host.index('        case RM_OP_HEAP_TEXTURE_SIZE: {',start)
cases=host[start:end]
pre=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include "protocol.h"
#include "winemetal.h"
static id objects[8]; static unsigned count=1; static uint32_t result; static uint64_t returned;
static MTLPixelFormat rm_fmt(enum WMTPixelFormat value) { return (MTLPixelFormat)value; }
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
 struct { struct rm_heap_new_texture head; struct WMTTextureInfo info; } texture={0};
 texture.head=(struct rm_heap_new_texture){heap,UINT64_MAX}; texture.info.pixel_format=(enum WMTPixelFormat)MTLPixelFormatRGBA8Unorm;
 texture.info.width=32; texture.info.height=32; texture.info.depth=1; texture.info.array_length=1;
 texture.info.type=(enum WMTTextureType)MTLTextureType2D; texture.info.mipmap_level_count=1; texture.info.sample_count=1;
 texture.info.usage=(enum WMTTextureUsage)MTLTextureUsageShaderRead; texture.info.options=(enum WMTResourceOptions)MTLResourceStorageModePrivate;
 invoke(RM_OP_HEAP_NEW_TEXTURE,&texture,sizeof(texture)-1); assert(result==RM_ERR_SHORT_PAYLOAD);
 invoke(RM_OP_HEAP_NEW_TEXTURE,&texture,sizeof(texture)); assert(result==RM_OK && returned && [objects[returned] conformsToProtocol:@protocol(MTLTexture)]);
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
start=source.index('static NTSTATUS\n_MTLHeap_newTexture('); end=source.index('\n\nstatic NTSTATUS\n_MTLDevice_newIndirectCommandBuffer',start)
new_texture=source[start:end]
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
struct unixcall_mtlheap_newtexture { obj_handle_t heap; struct WMTMemoryPointer info; uint64_t offset; obj_handle_t ret; };
static void fill_texture_descriptor(MTLTextureDescriptor *d, struct WMTTextureInfo *i) { (void)d; (void)i; }
static unsigned char guest[1024]; static unsigned calls,registered; static uint32_t status;
static void *UInt32ToPtr(uint32_t p) { return p?guest+p:NULL; }
static int remote_enabled = 1;
static int wmtr_enabled(void) { return remote_enabled; }
@interface SharedHeap : NSObject
- (MTLStorageMode)storageMode;
@end
@implementation SharedHeap
- (MTLStorageMode)storageMode { return MTLStorageModeShared; }
@end
static void wmtr_buf_add(uint64_t h,void *p,uint64_t n,uint32_t opts,int cpu,int owned) { assert(h==42 && !p && n==4096 && opts==32 && !cpu && !owned); registered++; }
static uint32_t wmtr_call(uint16_t op,const void *arg,uint32_t len,void *out,uint32_t outlen,uint32_t *got) {
 (void)got; calls++;
 if(op==RM_OP_HEAP_CREATE) {
  assert(len==sizeof(struct rm_wmt_info)+sizeof(struct WMTHeapInfo) && outlen==sizeof(struct rm_ret_handle));
  const struct rm_wmt_info *h=arg; const struct WMTHeapInfo *i=(const void*)(h+1); assert(h->owner==3 && i->size==65536);
  *(struct rm_ret_handle*)out=(struct rm_ret_handle){17};
 } else if(op==RM_OP_HEAP_NEW_TEXTURE) { assert(len==sizeof(struct rm_heap_new_texture)+sizeof(struct WMTTextureInfo));
  const struct rm_heap_new_texture *a=arg; const struct WMTTextureInfo *i=(const void *)(a+1); assert(a->heap==17 && i->width==32);
  *(struct rm_ret_handle_u64*)out=(struct rm_ret_handle_u64){44,5678};
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
 struct WMTTextureInfo *tex=(void *)(guest+256); tex->width=32;
 struct unixcall_mtlheap_newtexture t={0}; t.heap=17; t.info.ptr=(void *)(uintptr_t)256; t.offset=UINT64_MAX;
 assert(_MTLHeap_newTexture_wow64(&t)==STATUS_SUCCESS && t.ret==44 && tex->gpu_resource_id==5678 && !tex->mach_port);
 status=RM_ERR_BAD_OPCODE; assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_UNSUCCESSFUL && b.ret==0 && registered==1);
 b.ret=99; b.info.ptr=NULL; assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_INVALID_PARAMETER && b.ret==0);
 b.info.ptr=(void *)(uintptr_t)128; b.ret=99; remote_enabled=0; b.heap=(obj_handle_t)(uintptr_t)[SharedHeap new];
 assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_NOT_IMPLEMENTED && b.ret==0);
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-private-heap-client-') as t:
 exe=Path(t)/'test'
 code=client+create+new_buffer+new_texture+'\n'+wrapper+'\nWMT_WOW64_POINTER_WRAPPER(_MTLDevice_newHeap, unixcall_mtldevice_newheap, info)\nWMT_WOW64_POINTER_WRAPPER(_MTLHeap_newTexture, unixcall_mtlheap_newtexture, info)\n'+wow+client_end
 subprocess.run(['xcrun','-sdk','macosx','clang','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=code,text=True,check=True)
 subprocess.run([str(exe)],check=True)
print('remote heap clients and 32-bit wrappers pass')

# A failed unix call must not expose uninitialized handles or sizes to the PE caller.
thunks=(dxmt/'src/winemetal/winemetal_thunks.c').read_text()
start=thunks.index('WINEMETAL_API obj_handle_t\nMTLDevice_newHeap(')
end=thunks.index('WINEMETAL_API obj_handle_t\nMTLDevice_newLibraryWithSource(', start)
thunk_test=r'''
#define WINEMETAL_API
#include <assert.h>
#include "winemetal_thunks.h"
#define UNIX_CALL(code, params) ((void)0)
'''+thunks[start:end]+r'''
int main(void) {
 struct WMTHeapInfo heap={0}; struct WMTBufferInfo buffer={0};
 struct WMTTextureInfo texture={0}; struct WMTIndirectCommandBufferInfo icb={0};
 assert(!MTLDevice_newHeap(1,&heap));
 struct WMTSizeAndAlign a=MTLDevice_heapBufferSizeAndAlign(1,16,0);
 assert(!a.size && !a.align);
 a=MTLDevice_heapTextureSizeAndAlign(1,&texture); assert(!a.size && !a.align);
 assert(!MTLHeap_newBuffer(1,&buffer,0)); assert(!MTLHeap_newTexture(1,&texture,0));
 assert(!MTLDevice_newIndirectCommandBuffer(1,&icb,1,0));
 return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-heap-thunk-') as t:
 exe=Path(t)/'test'
 subprocess.run(['xcrun','-sdk','macosx','clang','-I',str(dxmt/'src/winemetal'),'-x','c','-','-o',str(exe)],input=thunk_test,text=True,check=True)
 subprocess.run([str(exe)],check=True)
print('heap and indirect-buffer thunks return zero on failed unix calls')
