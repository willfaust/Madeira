#!/usr/bin/env python3
"""Test remote shader-source compilation and 32-bit argument translation."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]; dxmt=Path(os.environ.get('DXMT_SOURCE',root/'dxmt'))
host=(root/'research/remote-metal/host/rmetald.m').read_text()
start=host.index('        case RM_OP_LIBRARY_SOURCE: {');end=host.index('        case RM_OP_COUNTER_NEW_TIMESTAMP: {',start);case=host[start:end]
pre=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <string.h>
#include "protocol.h"
static id<MTLDevice> device; static id saved; static uint32_t status,len_out; static struct { struct rm_library_source_result h; uint8_t text[RM_LIBRARY_ERROR_MAX]; } answer;
static id rm_resolve(uint64_t h,uint32_t *err) { *err=h==1?RM_OK:RM_ERR_BAD_HANDLE;return h==1?device:nil; }
static uint64_t rm_intern(id obj) { saved=obj;return obj?2:0; }
static void reply(int fd,const struct rm_hdr *h,uint32_t code,const void *data,uint32_t len) { (void)fd;(void)h;status=code;len_out=len;if(len) memcpy(&answer,data,len); }
static void invoke(void *payload,uint32_t length) { int fd=0;uint32_t err=RM_OK;struct rm_hdr h={.payload_len=length};switch(RM_OP_LIBRARY_SOURCE) {
'''
main=r'''
} }
int main(void) { @autoreleasepool {
 device=MTLCreateSystemDefaultDevice(); if(!device) return 77;
 struct { struct rm_library_source h; char text[512]; } p={0}; p.h.device=1;
 const char *src="#include <metal_stdlib>\nusing namespace metal; kernel void k() {}";
 p.h.length=strlen(src); memcpy(p.text,src,p.h.length);
 invoke(&p,sizeof(p.h)-1); assert(status==RM_ERR_SHORT_PAYLOAD);
 invoke(&p,sizeof(p.h)+p.h.length-1); assert(status==RM_ERR_SHORT_PAYLOAD);
 p.h.device=9; invoke(&p,sizeof(p.h)+p.h.length); assert(status==RM_ERR_BAD_HANDLE);
 p.h.device=1; invoke(&p,sizeof(p.h)+p.h.length); assert(status==RM_OK && answer.h.library==2 && [saved conformsToProtocol:@protocol(MTLLibrary)]);
 src="this is not shader code"; p.h.length=strlen(src); memcpy(p.text,src,p.h.length);
 invoke(&p,sizeof(p.h)+p.h.length); assert(status==RM_OK && !answer.h.library && answer.h.error_length && len_out==sizeof(answer.h)+answer.h.error_length);
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-source-host-') as t:
 exe=Path(t)/'test'; subprocess.run(['xcrun','-sdk','macosx','clang','-fobjc-arc','-I',str(root/'research/remote-metal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=pre+case+main,text=True,check=True)
 result=subprocess.run([str(exe)]).returncode
 if result==77: print('Metal source compile test skipped: no device')
 elif result: raise SystemExit(result)
 else: print('remote shader source compilation and diagnostics pass')
source=(dxmt/'src/winemetal/unix/winemetal_unix.c').read_text()
start=source.index('static NTSTATUS\n_MTLDevice_newLibraryWithSource(');end=source.index('\n\nstatic NTSTATUS\n_MTLTexture_getBytes',start);handler=source[start:end]
start=source.index('static NTSTATUS\n_NSObject_description(');end=source.index('\n\n/* PIPELINE ARCHIVE',start);description=source[start:end]
start=source.index('#define WMT_WOW64_POINTER_WRAPPER(name, type, field)');end=source.index('\n\nWMT_WOW64_POINTER_WRAPPER(',start);wrapper=source[start:end]
client=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <string.h>
#include "protocol.h"
#include "winemetal.h"
typedef uint64_t obj_handle_t; typedef uint32_t NTSTATUS;
#define STATUS_SUCCESS 0u
#define STATUS_UNSUCCESSFUL 0xc0000001u
#define STATUS_INVALID_PARAMETER 0xc000000du
struct unixcall_mtldevice_newlibrarywithsource { uint64_t device; struct WMTConstMemoryPointer source; uint64_t length,ret_error,ret_library; };
struct unixcall_generic_obj_obj_ret { uint64_t handle,ret; };
static unsigned char guest[256]; static int fail,short_reply;
static void *UInt32ToPtr(uint32_t p) { return p?guest+p:NULL; }
static int wmtr_enabled(void) { return 1; }
static NTSTATUS wmtr_unimplemented(const char *name) { (void)name;return STATUS_UNSUCCESSFUL; }
static uint32_t wmtr_call(uint16_t op,const void *arg,uint32_t len,void *out,uint32_t cap,uint32_t *got) {
 const struct rm_library_source *a=arg; assert(op==RM_OP_LIBRARY_SOURCE && len==sizeof(*a)+4 && a->device==1 && !memcmp(a+1,"test",4));
 assert(cap>=sizeof(struct rm_library_source_result)+4); struct rm_library_source_result *r=out;
 *r=(struct rm_library_source_result){fail?0:3,fail?4:0,0}; if(fail) memcpy(r+1,"oops",4); *got=short_reply?1:sizeof(*r)+r->error_length; return RM_OK;
}
'''
client_end=r'''
int main(void) { @autoreleasepool {
 memcpy(guest+16,"test",4); struct unixcall_mtldevice_newlibrarywithsource p={0}; p.device=1;p.source.ptr=(void *)(uintptr_t)16;p.length=4;
 assert(_MTLDevice_newLibraryWithSource_wow64(&p)==STATUS_SUCCESS && p.ret_library==3 && !p.ret_error && p.source.ptr==(void *)(uintptr_t)16);
 fail=1; assert(_MTLDevice_newLibraryWithSource_wow64(&p)==STATUS_SUCCESS && !p.ret_library && p.ret_error);
 struct unixcall_generic_obj_obj_ret d={p.ret_error,0}; assert(_NSObject_description(&d)==STATUS_SUCCESS && d.ret);
 assert([[(NSObject *)(uintptr_t)d.ret description] containsString:@"oops"]); [(NSObject *)(uintptr_t)p.ret_error release];
 short_reply=1; assert(_MTLDevice_newLibraryWithSource_wow64(&p)==STATUS_UNSUCCESSFUL && !p.ret_error && !p.ret_library);
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-source-client-') as t:
 exe=Path(t)/'test';code=client+description+handler+'\n'+wrapper+'\nWMT_WOW64_POINTER_WRAPPER(_MTLDevice_newLibraryWithSource, unixcall_mtldevice_newlibrarywithsource, source)\n'+client_end
 subprocess.run(['xcrun','-sdk','macosx','clang','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=code,text=True,check=True);subprocess.run([str(exe)],check=True)
print('remote shader source client, errors and 32-bit wrapper pass')
