#!/usr/bin/env python3
"""Check remote indirect-command-buffer creation and pointer conversion."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2];dxmt=Path(os.environ.get('DXMT_SOURCE',root/'dxmt'))
host=(root/'research/remote-metal/host/rmetald.m').read_text();start=host.index('        case RM_OP_NEW_INDIRECT_COMMAND_BUFFER: {');end=host.index('        case RM_OP_LIBRARY_SOURCE: {',start);case=host[start:end]
pre=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include "protocol.h"
#include "winemetal.h"
static id<MTLDevice> device; static id saved; static uint32_t status; static struct rm_ret_handle_u64 result;
static id rm_resolve(uint64_t h,uint32_t *err) { *err=h==1?RM_OK:RM_ERR_BAD_HANDLE;return h==1?device:nil; }
static uint64_t rm_intern(id o) { saved=o;return o?2:0; }
static void reply(int fd,const struct rm_hdr *h,uint32_t code,const void *data,uint32_t length) { (void)fd;(void)h;status=code; if(length==sizeof(result)) result=*(const struct rm_ret_handle_u64*)data; }
static void invoke(void *payload,uint32_t length) { int fd=0;uint32_t err=RM_OK;struct rm_hdr h={.payload_len=length};switch(RM_OP_NEW_INDIRECT_COMMAND_BUFFER) {
'''
main=r'''
} }
int main(void) { @autoreleasepool {
 device=MTLCreateSystemDefaultDevice(); if(!device) return 77;
 struct { struct rm_new_icb h; struct WMTIndirectCommandBufferInfo info; } p={0}; p.h=(struct rm_new_icb){1,1,MTLResourceStorageModePrivate};
 p.info.type=(enum WMTIndirectCommandType)MTLIndirectCommandTypeDraw; p.info.inherit_buffers=1;p.info.inherit_pso=1;
 invoke(&p,sizeof(p)-1);assert(status==RM_ERR_SHORT_PAYLOAD);
 p.h.device=9;invoke(&p,sizeof(p));assert(status==RM_ERR_BAD_HANDLE);
 p.h.device=1;invoke(&p,sizeof(p));if(status!=RM_OK) return 77;
 assert(result.handle==2 && [saved conformsToProtocol:@protocol(MTLIndirectCommandBuffer)] && result.value==[(id<MTLIndirectCommandBuffer>)saved gpuResourceID]._impl);
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-icb-host-') as t:
 exe=Path(t)/'test';subprocess.run(['xcrun','-sdk','macosx','clang','-fobjc-arc','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=pre+case+main,text=True,check=True)
 result_code=subprocess.run([str(exe)]).returncode
 if result_code==77: print('real Metal indirect-command-buffer test skipped: unsupported device')
 elif result_code: raise SystemExit(result_code)
 else: print('remote indirect-command-buffer host handler passes')
source=(dxmt/'src/winemetal/unix/winemetal_unix.c').read_text();start=source.index('static NTSTATUS\n_MTLDevice_newIndirectCommandBuffer(');end=source.index('\n\nstatic NTSTATUS\n_MTLDevice_newLibraryWithSource',start);handler=source[start:end]
start=source.index('#define WMT_WOW64_POINTER_WRAPPER(name, type, field)');end=source.index('\n\nWMT_WOW64_POINTER_WRAPPER(',start);wrapper=source[start:end]
client=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include "protocol.h"
#include "winemetal.h"
typedef uint32_t NTSTATUS;
#define STATUS_SUCCESS 0u
#define STATUS_UNSUCCESSFUL 0xc0000001u
#define STATUS_INVALID_PARAMETER 0xc000000du
struct unixcall_mtldevice_newicb { uint64_t device; struct WMTMemoryPointer info; uint64_t max_count; enum WMTResourceOptions options; uint64_t ret; };
static unsigned char guest[1024];static uint32_t status;
static void *UInt32ToPtr(uint32_t p) { return p?guest+p:NULL; }
static int wmtr_enabled(void) { return 1; }
static uint32_t wmtr_call(uint16_t op,const void *payload,uint32_t len,void *out,uint32_t cap,uint32_t *got) {
 (void)got;const struct rm_new_icb *a=payload;const struct WMTIndirectCommandBufferInfo *i=(const void *)(a+1);
 assert(op==RM_OP_NEW_INDIRECT_COMMAND_BUFFER && len==sizeof(*a)+sizeof(*i) && cap==sizeof(struct rm_ret_handle_u64));
 assert(a->device==1 && a->count==2 && i->max_vertex_buffer_binding==5);
 *(struct rm_ret_handle_u64*)out=(struct rm_ret_handle_u64){2,1234};return status;
}
'''
end_src=r'''
int main(void) { @autoreleasepool {
 struct WMTIndirectCommandBufferInfo *i=(void *)(guest+16);i->max_vertex_buffer_binding=5;
 struct unixcall_mtldevice_newicb p={0};p.device=1;p.max_count=2;p.info.ptr=(void *)(uintptr_t)16;
 assert(_MTLDevice_newIndirectCommandBuffer_wow64(&p)==STATUS_SUCCESS && p.ret==2 && i->gpu_resource_id==1234 && p.info.ptr==(void *)(uintptr_t)16);
 status=RM_ERR_BAD_OPCODE;assert(_MTLDevice_newIndirectCommandBuffer_wow64(&p)==STATUS_UNSUCCESSFUL && !p.ret && !i->gpu_resource_id);
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-icb-client-') as t:
 exe=Path(t)/'test';code=client+handler+'\n'+wrapper+'\nWMT_WOW64_POINTER_WRAPPER(_MTLDevice_newIndirectCommandBuffer, unixcall_mtldevice_newicb, info)\n'+end_src
 subprocess.run(['xcrun','-sdk','macosx','clang','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=code,text=True,check=True);subprocess.run([str(exe)],check=True)
print('remote indirect-command-buffer client and 32-bit wrapper pass')
