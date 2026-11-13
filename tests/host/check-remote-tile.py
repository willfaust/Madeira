#!/usr/bin/env python3
"""Check tile-pipeline marshalling and validation."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2];dxmt=Path(os.environ.get('DXMT_SOURCE',root/'dxmt'))
host=(root/'research/remote-metal/host/rmetald.m').read_text();start=host.index('        case RM_OP_NEW_TILE_PIPELINE: {');end=host.index('        case RM_OP_NEW_INDIRECT_COMMAND_BUFFER: {',start);case=host[start:end]
pre=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <string.h>
#include "protocol.h"
#include "winemetal.h"
@interface Function : NSObject <MTLFunction> @end
@implementation Function @end
@interface Archive : NSObject <MTLBinaryArchive> @end
@implementation Archive @end
static unsigned calls;
@interface Device : NSObject <MTLDevice> @end
@implementation Device
-(id<MTLRenderPipelineState>)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)d options:(MTLPipelineOption)o reflection:(MTLAutoreleasedRenderPipelineReflection *)r error:(NSError **)e {
 (void)o;(void)r; assert(d.tileFunction && d.rasterSampleCount==1); calls++; *e=[NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"bad tile"}]; return nil;
}
@end
static id objects[8];static uint32_t status;static struct {struct rm_library_source_result h;char text[RM_LIBRARY_ERROR_MAX];} answer;
static MTLPixelFormat rm_fmt(enum WMTPixelFormat f) { return (MTLPixelFormat)f; }
static id rm_resolve(uint64_t h,uint32_t *err) { if(h>=8 || !objects[h]) {*err=RM_ERR_BAD_HANDLE;return nil;} *err=RM_OK;return objects[h]; }
static uint64_t rm_intern(id o) {return o?6:0;}
static void reply(int fd,const struct rm_hdr *h,uint32_t code,const void *data,uint32_t len) {(void)fd;(void)h;status=code;if(len)memcpy(&answer,data,len);}
static void invoke(void *payload,uint32_t length) {int fd=0;uint32_t err=RM_OK;struct rm_hdr h={.payload_len=length};switch(RM_OP_NEW_TILE_PIPELINE) {
'''
main=r'''
} }
int main(void) { @autoreleasepool {
 objects[1]=[Device new];objects[2]=[Function new];objects[3]=[Archive new];
 struct {struct rm_wmt_info h;struct WMTTileRenderPipelineInfo i;uint64_t archives[2];} p={0};
 p.h=(struct rm_wmt_info){1,sizeof(p.i),2};p.i.tile_function=2;p.i.raster_sample_count=1;p.i.num_binary_archives_for_lookup=2;p.archives[0]=3;p.archives[1]=7;
 invoke(&p,sizeof(p)-1);assert(status==RM_ERR_SHORT_PAYLOAD && !calls);
 invoke(&p,sizeof(p));assert(status==RM_ERR_BAD_HANDLE && !calls);
 p.archives[1]=3;invoke(&p,sizeof(p));assert(status==RM_OK && calls==1 && !answer.h.library && answer.h.error_length==8 && !memcmp(answer.text,"bad tile",8));
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-tile-host-') as t:
 exe=Path(t)/'test';subprocess.run(['xcrun','-sdk','macosx','clang','-fobjc-arc','-Wno-protocol','-Wno-objc-protocol-property-synthesis','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=pre+case+main,text=True,check=True);subprocess.run([str(exe)],check=True)
print('remote tile pipeline host validation passes')
source=(dxmt/'src/winemetal/unix/winemetal_unix.c').read_text();start=source.index('static NTSTATUS\n_MTLDevice_newTileRenderPipelineState(');end=source.index('\n\n/* Remote residency batches',start);handler=source[start:end]
start=source.index('static NTSTATUS _MTLDevice_newTileRenderPipelineState_wow64(');end=source.index('\n\nstatic NTSTATUS _MTLHeap_newBuffer_wow64',start);wrapper=source[start:end]
client=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <string.h>
#include "protocol.h"
#include "winemetal.h"
typedef uint64_t obj_handle_t;typedef uint32_t NTSTATUS;
#define STATUS_SUCCESS 0u
#define STATUS_UNSUCCESSFUL 0xc0000001u
#define STATUS_INVALID_PARAMETER 0xc000000du
struct unixcall_mtldevice_newrenderpso {uint64_t device;struct WMTConstMemoryPointer info;uint64_t ret_error,ret_pso;};
static unsigned char guest[1024];static uint32_t status;
static void *UInt32ToPtr(uint32_t p) {return p?guest+p:NULL;}
static int wmtr_enabled(void) {return 1;}
static MTLPixelFormat to_metal_pixel_format(enum WMTPixelFormat f) {return (MTLPixelFormat)f;}
static uint32_t wmtr_call(uint16_t op,const void *payload,uint32_t len,void *out,uint32_t cap,uint32_t *got) {
 const struct rm_wmt_info *a=payload;const struct WMTTileRenderPipelineInfo *i=(const void *)(a+1);const uint64_t *v=(const void *)(i+1);
 assert(op==RM_OP_NEW_TILE_PIPELINE && len==sizeof(*a)+sizeof(*i)+16 && cap>=sizeof(struct rm_library_source_result));
 assert(a->owner==1 && a->extra_count==2 && !i->binary_archives_for_lookup.ptr && v[0]==3 && v[1]==4);
 if(status!=RM_OK) return status;
 struct rm_library_source_result *r=out;*r=(struct rm_library_source_result){0,4,0};memcpy(r+1,"oops",4);*got=sizeof(*r)+4;return RM_OK;
}
'''
client_end=r'''
int main(void) { @autoreleasepool {
 struct WMTTileRenderPipelineInfo *i=(void *)(guest+16);i->num_binary_archives_for_lookup=2;i->binary_archives_for_lookup.ptr=(void *)(uintptr_t)256;
 uint64_t *a=(void *)(guest+256);a[0]=3;a[1]=4;
 struct unixcall_mtldevice_newrenderpso p={0};p.device=1;p.info.ptr=(void *)(uintptr_t)16;
 assert(_MTLDevice_newTileRenderPipelineState_wow64(&p)==STATUS_SUCCESS && !p.ret_pso && p.ret_error && p.info.ptr==(void *)(uintptr_t)16);
 assert([[(NSError *)(uintptr_t)p.ret_error localizedDescription] isEqualToString:@"oops"]);[(NSError *)(uintptr_t)p.ret_error release];
 status=RM_ERR_BAD_OPCODE;assert(_MTLDevice_newTileRenderPipelineState_wow64(&p)==STATUS_UNSUCCESSFUL && !p.ret_pso && !p.ret_error);
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-tile-client-') as t:
 exe=Path(t)/'test';subprocess.run(['xcrun','-sdk','macosx','clang','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=client+handler+wrapper+client_end,text=True,check=True);subprocess.run([str(exe)],check=True)
print('remote tile pipeline client and 32-bit nested pointers pass')
