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
start=host.index('        case RM_OP_BUFFER_READ: {');end=host.index('        case RM_OP_SUBMIT_WMT_BATCH:',start);cases+=host[start:end]
start=host.index('        case RM_OP_BUFFER_UPLOAD: {');end=host.index('        case RM_OP_NEW_MESH_PSO_INFO:',start);cases+=host[start:end]
pre=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <sys/mman.h>
#include "protocol.h"
#include "winemetal.h"
static id objects[16]; static unsigned count=1; static uint32_t result; static uint64_t returned;
static MTLPixelFormat rm_fmt(enum WMTPixelFormat value) { return (MTLPixelFormat)value; }
static uint64_t rm_intern(id object) { if (!object) return 0; objects[++count]=object; return count; }
static id rm_resolve(uint64_t h,uint32_t *err) { if(h>=16 || !objects[h]) { *err=RM_ERR_BAD_HANDLE; return nil; } *err=RM_OK; return objects[h]; }
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
 p.head.owner=15; invoke(RM_OP_HEAP_CREATE,&p,sizeof(p)); assert(result==RM_ERR_BAD_HANDLE);
 p.head.owner=1; invoke(RM_OP_HEAP_CREATE,&p,sizeof(p)); if(result!=RM_OK) return 77;
 uint64_t heap=returned; assert(heap && [objects[heap] conformsToProtocol:@protocol(MTLHeap)]);
 struct rm_heap_new_buffer b={heap,UINT64_MAX,4096,MTLResourceStorageModePrivate};
 invoke(RM_OP_HEAP_NEW_PRIVATE_BUFFER,&b,sizeof(b)-1); assert(result==RM_ERR_SHORT_PAYLOAD);
 invoke(RM_OP_HEAP_NEW_PRIVATE_BUFFER,&b,sizeof(b)); assert(result==RM_OK && returned && [objects[returned] conformsToProtocol:@protocol(MTLBuffer)]);
 p.info.type=(enum WMTHeapType)MTLHeapTypePlacement;
 invoke(RM_OP_HEAP_CREATE,&p,sizeof(p)); assert(result==RM_OK && returned);
 uint64_t placed=returned; b.heap=placed;b.offset=0;
 invoke(RM_OP_HEAP_NEW_PRIVATE_BUFFER,&b,sizeof(b));assert(result==RM_OK && returned);id<MTLBuffer> first=objects[returned];
 invoke(RM_OP_HEAP_NEW_PRIVATE_BUFFER,&b,sizeof(b));assert(result==RM_OK && returned);id<MTLBuffer> second=objects[returned];
 id<MTLBuffer> readback=[d newBufferWithLength:4096 options:MTLResourceStorageModeShared];
 id<MTLCommandQueue> queue=[d newCommandQueue];id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
 [blit fillBuffer:first range:NSMakeRange(0,4096) value:0x5a];
 [blit copyFromBuffer:second sourceOffset:0 toBuffer:readback destinationOffset:0 size:4096];
 [blit endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);
 for(unsigned n=0;n<4096;n++)assert(((uint8_t *)readback.contents)[n]==0x5a);
 b.offset=UINT64_MAX-1;invoke(RM_OP_HEAP_NEW_PRIVATE_BUFFER,&b,sizeof(b));assert(result==RM_ERR_SHORT_PAYLOAD);
 b.heap=heap;b.offset=UINT64_MAX;
 struct { struct rm_heap_new_texture head; struct WMTTextureInfo info; } texture={0};
 texture.head=(struct rm_heap_new_texture){heap,UINT64_MAX}; texture.info.pixel_format=(enum WMTPixelFormat)MTLPixelFormatRGBA8Unorm;
 texture.info.width=32; texture.info.height=32; texture.info.depth=1; texture.info.array_length=1;
 texture.info.type=(enum WMTTextureType)MTLTextureType2D; texture.info.mipmap_level_count=1; texture.info.sample_count=1;
 texture.info.usage=(enum WMTTextureUsage)MTLTextureUsageShaderRead; texture.info.options=(enum WMTResourceOptions)MTLResourceStorageModePrivate;
 invoke(RM_OP_HEAP_NEW_TEXTURE,&texture,sizeof(texture)-1); assert(result==RM_ERR_SHORT_PAYLOAD);
 invoke(RM_OP_HEAP_NEW_TEXTURE,&texture,sizeof(texture)); assert(result==RM_OK && returned && [objects[returned] conformsToProtocol:@protocol(MTLTexture)]);
 MTLHeapDescriptor *shared=[MTLHeapDescriptor new]; shared.size=1<<20; shared.storageMode=MTLStorageModeShared;shared.type=MTLHeapTypePlacement;
 id<MTLHeap> s=[d newHeapWithDescriptor:shared]; if(s) { uint64_t sh=rm_intern(s); b.heap=sh;b.offset=0;
  invoke(RM_OP_HEAP_NEW_PRIVATE_BUFFER,&b,sizeof(b)); assert(result==RM_ERR_SHORT_PAYLOAD);
  b.options=MTLResourceStorageModeShared;invoke(RM_OP_HEAP_NEW_PRIVATE_BUFFER,&b,sizeof(b));assert(result==RM_OK);id<MTLBuffer> a=objects[returned];
  invoke(RM_OP_HEAP_NEW_PRIVATE_BUFFER,&b,sizeof(b));assert(result==RM_OK);uint64_t ch=returned;id<MTLBuffer> c=objects[ch];
  ((uint8_t *)a.contents)[37]=0x8c;assert(((uint8_t *)c.contents)[37]==0x8c);
  struct rm_buffer_range r={ch,UINT64_MAX,2};invoke(RM_OP_BUFFER_READ,&r,sizeof(r));assert(result==RM_ERR_SHORT_PAYLOAD);
  r.handle=1;r.offset=0;r.length=1;invoke(RM_OP_BUFFER_READ,&r,sizeof(r));assert(result==RM_ERR_WRONG_CLASS);
  struct { struct rm_buffer_range range; uint8_t data[8]; } u={{ch,UINT64_MAX,2},{0}};
  invoke(RM_OP_BUFFER_UPLOAD,&u,sizeof(u));assert(result==RM_ERR_SHORT_PAYLOAD);
 }
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
start=source.index('static NTSTATUS\n_MadeiraMTLDevice_heapTextureSizeAndAlign('); end=source.index('\nstatic NTSTATUS _MadeiraMTLDevice_heapBufferSizeAndAlign_wow64',start)
legacy=source[start:end]
start=source.index('static NTSTATUS _MTLHeap_newBuffer_wow64('); end=source.index('\n#endif',start)
wow=source[start:end]
start=source.index('#define WMT_WOW64_POINTER_WRAPPER(name, type, field)');end=source.index('\n\nWMT_WOW64_POINTER_WRAPPER(',start)
wrapper=source[start:end]
client=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <sys/mman.h>
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
struct unixcall_mtldevice_heaptexturesizealign { obj_handle_t device; struct WMTMemoryPointer info; uint64_t ret_size,ret_align; };
struct unixcall_mtldevice_newplacementheap { obj_handle_t device; uint64_t size,options; obj_handle_t ret; };
struct unixcall_mtlheap_newtextureatoffset { obj_handle_t heap; struct WMTMemoryPointer info; uint64_t offset; obj_handle_t ret; };
struct unixcall_mtldevice_heapbuffersizealign { obj_handle_t device; uint64_t length,options,ret_size,ret_align; };
struct unixcall_mtlheap_newbufferatoffset { obj_handle_t heap; struct WMTMemoryPointer info; uint64_t offset; obj_handle_t ret; };
static MTLResourceOptions madeira_cpu_cache_mode(MTLResourceOptions v) { return v; }
static int wmt_stale_probe_on(void) { return 0; }
static void wmt_freed_set(uintptr_t p,int v) { (void)p;(void)v; }
static void fill_texture_descriptor(MTLTextureDescriptor *d, struct WMTTextureInfo *i) { (void)d; (void)i; }
static unsigned char *guest; static unsigned calls,registered; static uint32_t status;
static void *UInt32ToPtr(uint32_t p) { return p?guest+p:NULL; }
static int remote_enabled = 1;
static int wmtr_enabled(void) { return remote_enabled; }
static int wmtr_heap_register(uint64_t h,uint64_t size) { (void)h;(void)size;return 0; }
static void *wmtr_heap_native_pointer(uint64_t h,uint64_t off,uint64_t n) { (void)h;(void)off;(void)n;return NULL; }
static int wmtr_heap_flush(void) { return 0; }
static int wmtr_heap_sync(void) { return 0; }
static int wmtr_heap_attach(uint64_t h,uint64_t heap,uint64_t off,void *ptr,uint64_t len) { (void)h;(void)heap;(void)off;(void)ptr;(void)len;return 0; }
static void wmtr_buf_remove(uint64_t h) { (void)h; }
@interface SharedHeap : NSObject
- (MTLStorageMode)storageMode;
@end
@implementation SharedHeap
- (MTLStorageMode)storageMode { return MTLStorageModeShared; }
@end
static void wmtr_buf_add(uint64_t h,void *p,uint64_t n,uint32_t opts,int cpu,int owned) { assert(h==42 && n==4096 && !owned); assert((opts==32 && !p && !cpu) || (!opts && p==guest+32768 && cpu)); registered++; }
static uint32_t wmtr_call(uint16_t op,const void *arg,uint32_t len,void *out,uint32_t outlen,uint32_t *got) {
 (void)got; calls++;
 if(op==RM_OP_HEAP_BUFFER_SIZE || op==RM_OP_HEAP_TEXTURE_SIZE) {
  *(struct rm_size_and_align*)out=(struct rm_size_and_align){0x100000020ull,256};
 } else if(op==RM_OP_HEAP_CREATE) {
  assert(len==sizeof(struct rm_wmt_info)+sizeof(struct WMTHeapInfo) && outlen==sizeof(struct rm_ret_handle));
  const struct rm_wmt_info *h=arg; const struct WMTHeapInfo *i=(const void*)(h+1); assert(h->owner==3 && i->size==65536);
  *(struct rm_ret_handle*)out=(struct rm_ret_handle){17};
 } else if(op==RM_OP_HEAP_NEW_TEXTURE) { assert(len==sizeof(struct rm_heap_new_texture)+sizeof(struct WMTTextureInfo));
  const struct rm_heap_new_texture *a=arg; const struct WMTTextureInfo *i=(const void *)(a+1); assert(a->heap==17 && i->width==32);
  *(struct rm_ret_handle_u64*)out=(struct rm_ret_handle_u64){44,5678};
 } else { assert(op==RM_OP_HEAP_NEW_PRIVATE_BUFFER && len==sizeof(struct rm_heap_new_buffer) && outlen==sizeof(struct rm_ret_handle_u64));
  const struct rm_heap_new_buffer *b=arg; assert(b->heap==17 && b->length==4096 && (b->options==32 || b->options==0));
  *(struct rm_ret_handle_u64*)out=(struct rm_ret_handle_u64){42,1234}; }
 return status;
}
'''
client_end=r'''
int main(void) { @autoreleasepool {
 guest=mmap(NULL,1u<<20,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0); assert(guest!=MAP_FAILED);
 struct WMTHeapInfo *heap=(void *)(guest+32); heap->size=65536;
 struct unixcall_mtldevice_newheap h={0}; h.device=3; h.info.ptr=(void *)(uintptr_t)32;
 assert(_MTLDevice_newHeap_wow64(&h)==STATUS_SUCCESS && h.ret==17 && h.info.ptr==(void *)(uintptr_t)32);
 struct WMTBufferInfo *info=(void *)(guest+128); info->length=4096; info->options=(enum WMTResourceOptions)32;
 struct unixcall_mtlheap_newbuffer b={0}; b.heap=17; b.info.ptr=(void *)(uintptr_t)128; b.offset=UINT64_MAX;
 assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_SUCCESS && b.ret==42 && !info->memory.ptr && info->gpu_address==1234 && registered==1);
 struct WMTTextureInfo *tex=(void *)(guest+256); tex->width=32;
 struct unixcall_mtlheap_newtexture t={0}; t.heap=17; t.info.ptr=(void *)(uintptr_t)256; t.offset=UINT64_MAX;
 assert(_MTLHeap_newTexture_wow64(&t)==STATUS_SUCCESS && t.ret==44 && tex->gpu_resource_id==5678 && !tex->mach_port);
 struct unixcall_mtldevice_newplacementheap legacy_heap={3,65536,WMTResourceStorageModePrivate,0};
 assert(_MTLDevice_newPlacementHeap(&legacy_heap)==STATUS_SUCCESS && legacy_heap.ret==17);
 struct unixcall_mtldevice_heapbuffersizealign bs={3,4096,WMTResourceStorageModePrivate,0,0};
 assert(_MadeiraMTLDevice_heapBufferSizeAndAlign(&bs)==STATUS_SUCCESS && bs.ret_size==0x100000020ull && bs.ret_align==256);
 struct unixcall_mtldevice_heaptexturesizealign ts={0};ts.device=3;ts.info.ptr=tex;
 assert(_MadeiraMTLDevice_heapTextureSizeAndAlign(&ts)==STATUS_SUCCESS && ts.ret_size==0x100000020ull && ts.ret_align==256);
 struct unixcall_mtlheap_newbufferatoffset lb={0};lb.heap=17;lb.info.ptr=info;lb.offset=0;
 assert(_MTLHeap_newBufferAtOffset(&lb)==STATUS_SUCCESS && lb.ret==42 && info->gpu_address==1234 && registered==2);
 struct unixcall_mtlheap_newtextureatoffset lt={0};lt.heap=17;lt.info.ptr=tex;lt.offset=0;
 assert(_MTLHeap_newTextureAtOffset(&lt)==STATUS_SUCCESS && lt.ret==44 && tex->gpu_resource_id==5678);
 info->options=0;lb.ret=1;info->gpu_address=1234;
 assert(_MTLHeap_newBufferAtOffset(&lb)==STATUS_SUCCESS && !lb.ret && !info->gpu_address);
 info->options=WMTResourceStorageModePrivate;
 status=RM_ERR_BAD_OPCODE; assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_UNSUCCESSFUL && b.ret==0 && registered==2);
 status=0;info->options=WMTResourceStorageModeShared;info->memory.ptr=(void *)(uintptr_t)32768;b.offset=0;
 assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_SUCCESS && b.ret==42 && info->memory.ptr==(void *)(uintptr_t)32768 && registered==3);
 info->memory.ptr=(void *)(uintptr_t)0xfffffff0u;info->gpu_address=77;
 assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_INVALID_PARAMETER && !b.ret && !info->memory.ptr && !info->gpu_address);
 b.ret=99; b.info.ptr=NULL; assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_INVALID_PARAMETER && b.ret==0);
 b.info.ptr=(void *)(uintptr_t)128; b.ret=99; remote_enabled=0; b.heap=(obj_handle_t)(uintptr_t)[SharedHeap new];
 assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_NOT_IMPLEMENTED && b.ret==0);
 id<MTLDevice> device=MTLCreateSystemDefaultDevice(); assert(device);
 MTLHeapDescriptor *desc=[MTLHeapDescriptor new];desc.size=262144;desc.storageMode=MTLStorageModeShared;desc.type=MTLHeapTypePlacement;
 id<MTLHeap> native_heap=[device newHeapWithDescriptor:desc];assert(native_heap);
 info->length=65536;info->options=0;info->memory.ptr=(void *)(uintptr_t)0x10000;info->gpu_address=WMT_HEAP_GUEST_RESERVATION;
 b.heap=(obj_handle_t)(uintptr_t)native_heap;b.offset=0;
 assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_SUCCESS && b.ret && info->memory.ptr);
 id<MTLBuffer> first=(id<MTLBuffer>)(uintptr_t)b.ret;uint8_t *first_guest=UInt32ToPtr((uint32_t)(uintptr_t)info->memory.ptr);
 struct WMTBufferInfo *other=(void *)(guest+384);other->length=65536;other->options=0;other->memory.ptr=(void *)(uintptr_t)0x40000;other->gpu_address=WMT_HEAP_GUEST_RESERVATION;
 struct unixcall_mtlheap_newbuffer b2={0};b2.heap=b.heap;b2.offset=0;b2.info.ptr=(void *)(uintptr_t)384;
 assert(_MTLHeap_newBuffer_wow64(&b2)==STATUS_SUCCESS && b2.ret && other->memory.ptr);
 id<MTLBuffer> second=(id<MTLBuffer>)(uintptr_t)b2.ret;uint8_t *second_guest=UInt32ToPtr((uint32_t)(uintptr_t)other->memory.ptr);
 first_guest[0]=0x61;first_guest[65535]=0x93;assert(second_guest[0]==0x61 && second_guest[65535]==0x93);
 second_guest[37]=0xaf;assert(first_guest[37]==0xaf && ((uint8_t *)first.contents)[37]==0xaf);
 info->length=UINT32_MAX;info->memory.ptr=(void *)(uintptr_t)0x10000;info->gpu_address=WMT_HEAP_GUEST_RESERVATION;b.ret=99;
 assert(_MTLHeap_newBuffer_wow64(&b)==STATUS_INVALID_PARAMETER && !b.ret && !info->memory.ptr);
 [first release];[second release];[native_heap release];[desc release];assert(munmap(guest,1u<<20)==0);
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-private-heap-client-') as t:
 exe=Path(t)/'test'
 code=client+create+new_buffer+new_texture+legacy+'\n'+wrapper+'\nWMT_WOW64_POINTER_WRAPPER(_MTLDevice_newHeap, unixcall_mtldevice_newheap, info)\nWMT_WOW64_POINTER_WRAPPER(_MTLHeap_newTexture, unixcall_mtlheap_newtexture, info)\n'+wow+client_end
 subprocess.run(['xcrun','-sdk','macosx','clang','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=code,text=True,check=True)
 subprocess.run([str(exe)],check=True)
 subprocess.run(['xcrun','-sdk','iphoneos','clang','-arch','arm64','-fsyntax-only','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-'],input=code,text=True,check=True)
print('remote heap clients and 32-bit wrappers pass')

# A failed unix call must not expose uninitialized handles or sizes to the PE caller.
thunks=(dxmt/'src/winemetal/winemetal_thunks.c').read_text()
start=thunks.index('WINEMETAL_API obj_handle_t\nMTLDevice_newHeap(')
end=thunks.index('WINEMETAL_API obj_handle_t\nMTLDevice_newLibraryWithSource(', start)
thunk_test=r'''
#define WINEMETAL_API
#include <assert.h>
#include <stddef.h>
#include "winemetal_thunks.h"
#define UNIX_CALL(code, params) ((void)0)
#define WINE_UNIX_CALL(code, params) 1
static void wmt_api_census_note(unsigned code) { (void)code; }
'''+thunks[start:end]+r'''
int main(void) {
 struct WMTHeapInfo heap={0}; struct WMTBufferInfo buffer={0};
 struct WMTTextureInfo texture={0}; struct WMTIndirectCommandBufferInfo icb={0};
 assert(!MTLDevice_newHeap(1,&heap));
 struct WMTSizeAndAlign a=MTLDevice_heapBufferSizeAndAlign(1,16,0);
 assert(!a.size && !a.align);
 a=MTLDevice_heapTextureSizeAndAlign(1,&texture); assert(!a.size && !a.align);
 buffer.memory.ptr=(void *)(uintptr_t)16;buffer.gpu_address=123;
 assert(!MTLHeap_newBuffer(1,&buffer,0) && !buffer.memory.ptr && !buffer.gpu_address); assert(!MTLHeap_newTexture(1,&texture,0));
 assert(!MTLDevice_newIndirectCommandBuffer(1,&icb,1,0));
 return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-heap-thunk-') as t:
 exe=Path(t)/'test'
 subprocess.run(['xcrun','-sdk','macosx','clang','-I',str(dxmt/'src/winemetal'),'-x','c','-','-o',str(exe)],input=thunk_test,text=True,check=True)
 subprocess.run([str(exe)],check=True)
print('heap and indirect-buffer thunks return zero on failed unix calls')
