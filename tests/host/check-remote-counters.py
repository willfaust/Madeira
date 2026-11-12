#!/usr/bin/env python3
"""Exercise remote counter and sampled-blit request handlers."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]; dxmt=Path(os.environ.get('DXMT_SOURCE',root/'dxmt'))
host=(root/'research/remote-metal/host/rmetald.m').read_text()
start=host.index('        case RM_OP_COUNTER_NEW_TIMESTAMP: {'); end=host.index('        case RM_OP_HEAP_NEW_TEXTURE: {',start)
cases=host[start:end]
pre=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include "protocol.h"
@interface Sample : NSObject <MTLCounterSampleBuffer> @end
@implementation Sample
-(NSUInteger)sampleCount { return 8; }
-(NSData *)resolveCounterRange:(NSRange)r { (void)r; uint64_t x=0x12345678; return [NSData dataWithBytes:&x length:sizeof(x)]; }
@end
@interface CounterSet : NSObject <MTLCounterSet> @end
@implementation CounterSet
-(NSString *)name { return MTLCommonCounterSetTimestamp; }
@end
@interface Device : NSObject <MTLDevice> @end
@implementation Device
-(NSArray *)counterSets { return @[[CounterSet new]]; }
-(id<MTLCounterSampleBuffer>)newCounterSampleBufferWithDescriptor:(MTLCounterSampleBufferDescriptor *)d error:(NSError **)e { (void)e; assert(d.sampleCount==8); return [Sample new]; }
@end
@interface Encoder : NSObject <MTLBlitCommandEncoder> @end
@implementation Encoder @end
static unsigned created,closed,opened; static unsigned long g_enc_seq;
@interface CommandBuffer : NSObject <MTLCommandBuffer> @end
@implementation CommandBuffer
-(id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)d { (void)d; created++; return [Encoder new]; }
@end
static id objects[8]; static uint32_t status; static unsigned len_out; static uint64_t data_out;
static id rm_resolve(uint64_t h,uint32_t *err) { if(h>=8 || !objects[h]) { *err=RM_ERR_BAD_HANDLE; return nil; } *err=RM_OK; return objects[h]; }
static uint64_t rm_intern(id o) { objects[4]=o; return o ? 4 : 0; }
static void rm_enc_end_open_on_cb(id cb,const char *name) { (void)cb;(void)name;closed++; }
static void rm_enc_opened(id encoder,id cb) { (void)encoder;(void)cb;opened++; }
static void reply(int fd,const struct rm_hdr *h,uint32_t code,const void *data,uint32_t len) { (void)fd;(void)h;status=code;len_out=len; if(len>=8) data_out=*(const uint64_t*)data; }
static void invoke(uint16_t op,void *payload,uint32_t length) { int fd=0; uint32_t err=RM_OK; struct rm_hdr h={.payload_len=length}; switch(op) {
'''
main=r'''
} }
int main(void) { @autoreleasepool {
 objects[1]=[Device new]; objects[2]=[Sample new]; objects[3]=[CommandBuffer new];
 struct rm_counter_new c={1,8,1}; invoke(RM_OP_COUNTER_NEW_TIMESTAMP,&c,sizeof(c)-1); assert(status==RM_ERR_SHORT_PAYLOAD);
 invoke(RM_OP_COUNTER_NEW_TIMESTAMP,&c,sizeof(c)); assert(status==RM_OK && data_out==4);
 struct rm_counter_resolve r={2,1,2,8}; invoke(RM_OP_COUNTER_RESOLVE,&r,sizeof(r)); assert(status==RM_OK && len_out==8 && data_out==0x12345678);
 r.start=7; r.count=2; invoke(RM_OP_COUNTER_RESOLVE,&r,sizeof(r)); assert(status==RM_ERR_SHORT_PAYLOAD);
 r.start=0; r.count=1; r.data_length=RM_CHUNK_BYTES+1; invoke(RM_OP_COUNTER_RESOLVE,&r,sizeof(r)); assert(status==RM_ERR_SHORT_PAYLOAD);
 struct { struct rm_blit_samples h; struct rm_sample_attachment a[5]; } p={0}; p.h.cmdbuf=3; p.h.count=5;
 invoke(RM_OP_BLIT_WITH_SAMPLES,&p,sizeof(p)); assert(status==RM_ERR_SHORT_PAYLOAD && !created && !closed);
 p.h.count=2; p.a[0].buffer=2; p.a[1].buffer=7; invoke(RM_OP_BLIT_WITH_SAMPLES,&p,sizeof(p.h)+2*sizeof(p.a[0])); assert(status==RM_ERR_BAD_HANDLE && !created && !closed);
 p.h.count=0; invoke(RM_OP_BLIT_WITH_SAMPLES,&p,sizeof(p.h)); assert(status==RM_OK && created==1 && closed==1 && opened==1);
 } return 0; }
'''
# The mock encoder needs a label setter because the production handler labels it.
pre=pre.replace('@implementation Encoder @end','@implementation Encoder\n-(void)setLabel:(NSString *)label { (void)label; }\n@end')
with tempfile.TemporaryDirectory(prefix='madeira-counter-host-') as t:
 exe=Path(t)/'test'; subprocess.run(['xcrun','-sdk','macosx','clang','-fobjc-arc','-Wno-protocol','-Wno-objc-protocol-property-synthesis','-Wno-mismatched-return-types','-I',str(root/'research/remote-metal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=pre+cases+main,text=True,check=True);subprocess.run([str(exe)],check=True)
print('remote counter and sampled-blit host validation passes')
source=(dxmt/'src/winemetal/unix/winemetal_unix.c').read_text()
start=source.index('static NTSTATUS\n_MTLCounterSampleBuffer_newTimestampBuffer(');end=source.index('\n\nstatic NTSTATUS\n_MTLCommandBuffer_property',start)
handlers=source[start:end]
start=source.index('#define WMT_WOW64_POINTER_WRAPPER(name, type, field)');end=source.index('\n\nWMT_WOW64_POINTER_WRAPPER(',start)
wrapper=source[start:end]
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
struct unixcall_mtlcountersamplebuffer_newtimestampbuffer { uint64_t device; uint32_t sample_count,shared; uint64_t ret; };
struct unixcall_mtlcountersamplebuffer_resolvecounterrange { uint64_t sample_buffer; uint32_t start,len; struct WMTMemoryPointer data_out; uint64_t data_length; };
struct unixcall_mtlcommandbuffer_blitcommandencoderwithsamplebuffers { uint64_t cmdbuf; struct WMTMemoryPointer attachments; uint64_t num_attachments,ret; };
static unsigned char guest[1024]; static uint32_t result; static unsigned calls;
static void *UInt32ToPtr(uint32_t p) { return p?guest+p:NULL; }
static int wmtr_enabled(void) { return 1; }
static uint32_t wmtr_call(uint16_t op,const void *arg,uint32_t len,void *out,uint32_t cap,uint32_t *got) {
 calls++; if(result!=RM_OK) return result;
 if(op==RM_OP_COUNTER_NEW_TIMESTAMP) { const struct rm_counter_new *a=arg; assert(len==sizeof(*a) && a->device==1 && a->count==8); *(struct rm_ret_handle*)out=(struct rm_ret_handle){2}; }
 else if(op==RM_OP_COUNTER_RESOLVE) { const struct rm_counter_resolve *a=arg; assert(len==sizeof(*a) && a->buffer==2 && cap==8); *(uint64_t*)out=0x12345678; *got=8; }
 else { const struct rm_blit_samples *a=arg; const struct rm_sample_attachment *v=(const void *)(a+1); assert(op==RM_OP_BLIT_WITH_SAMPLES && a->cmdbuf==3 && a->count==1 && len==sizeof(*a)+sizeof(*v) && v->buffer==2 && v->start==1 && v->end==2); *(struct rm_ret_handle*)out=(struct rm_ret_handle){4}; }
 return RM_OK;
}
'''
main=r'''
int main(void) { @autoreleasepool {
 struct unixcall_mtlcountersamplebuffer_newtimestampbuffer c={1,8,1,0}; assert(_MTLCounterSampleBuffer_newTimestampBuffer(&c)==STATUS_SUCCESS && c.ret==2);
 struct unixcall_mtlcountersamplebuffer_resolvecounterrange r={0}; r.sample_buffer=2; r.start=0; r.len=1; r.data_out.ptr=(void *)(uintptr_t)32; r.data_length=8;
 assert(_MTLCounterSampleBuffer_resolveCounterRange_wow64(&r)==STATUS_SUCCESS && *(uint64_t*)(guest+32)==0x12345678 && r.data_out.ptr==(void *)(uintptr_t)32);
 struct WMTSampleBufferAttachmentInfo *a=(void *)(guest+128); *a=(struct WMTSampleBufferAttachmentInfo){2,1,2};
 struct unixcall_mtlcommandbuffer_blitcommandencoderwithsamplebuffers b={0}; b.cmdbuf=3; b.attachments.ptr=(void *)(uintptr_t)128; b.num_attachments=1;
 assert(_MTLCommandBuffer_blitCommandEncoderWithSampleBuffers_wow64(&b)==STATUS_SUCCESS && b.ret==4 && b.attachments.ptr==(void *)(uintptr_t)128);
 b.num_attachments=5; assert(_MTLCommandBuffer_blitCommandEncoderWithSampleBuffers_wow64(&b)==STATUS_INVALID_PARAMETER && b.ret==0 && calls==3);
 result=RM_ERR_BAD_OPCODE; c.ret=9; assert(_MTLCounterSampleBuffer_newTimestampBuffer(&c)==STATUS_UNSUCCESSFUL && c.ret==0);
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-counter-client-') as t:
 exe=Path(t)/'test'
 code=client+handlers+'\n'+wrapper+'\nWMT_WOW64_POINTER_WRAPPER(_MTLCounterSampleBuffer_resolveCounterRange, unixcall_mtlcountersamplebuffer_resolvecounterrange, data_out)\nWMT_WOW64_POINTER_WRAPPER(_MTLCommandBuffer_blitCommandEncoderWithSampleBuffers, unixcall_mtlcommandbuffer_blitcommandencoderwithsamplebuffers, attachments)\n'+main
 subprocess.run(['xcrun','-sdk','macosx','clang','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=code,text=True,check=True)
 subprocess.run([str(exe)],check=True)
print('remote counter and sampled-blit clients and 32-bit wrappers pass')
real=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include "protocol.h"
static id objects[8]; static uint32_t status; static uint64_t returned; static unsigned len_out; static unsigned long g_enc_seq;
static id rm_resolve(uint64_t h,uint32_t *err) { if(h>=8 || !objects[h]) { *err=RM_ERR_BAD_HANDLE; return nil; } *err=RM_OK; return objects[h]; }
static uint64_t rm_intern(id o) { if(!o) return 0; for(unsigned i=4;i<8;i++) if(!objects[i]) { objects[i]=o; return i; } return 0; }
static void rm_enc_end_open_on_cb(id cb,const char *name) { (void)cb;(void)name; }
static void rm_enc_opened(id enc,id cb) { (void)enc;(void)cb; }
static void reply(int fd,const struct rm_hdr *h,uint32_t code,const void *data,uint32_t len) { (void)fd;(void)h;status=code;len_out=len; if(len>=8) memcpy(&returned,data,8); }
static void invoke(uint16_t op,void *payload,uint32_t length) { int fd=0;uint32_t err=RM_OK;struct rm_hdr h={.payload_len=length};switch(op) {
'''
real_end=r'''
} }
int main(void) { @autoreleasepool {
 id<MTLDevice> d=MTLCreateSystemDefaultDevice(); if(!d || ![d supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) return 77;
 objects[1]=d; struct rm_counter_new create={1,8,1}; invoke(RM_OP_COUNTER_NEW_TIMESTAMP,&create,sizeof(create)); if(status!=RM_OK || !returned) return 77;
 uint64_t sample=returned; id<MTLCommandQueue> q=[d newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer]; objects[2]=cb;
 struct {struct rm_blit_samples h; struct rm_sample_attachment a;} p={{2,1,0},{sample,0,1}};
 invoke(RM_OP_BLIT_WITH_SAMPLES,&p,sizeof(p)); if(status!=RM_OK || !returned) return 77;
 [(id<MTLBlitCommandEncoder>)objects[returned] endEncoding]; [cb commit]; [cb waitUntilCompleted]; if(cb.status != MTLCommandBufferStatusCompleted) return 77;
 struct rm_counter_resolve r={sample,0,1,8}; invoke(RM_OP_COUNTER_RESOLVE,&r,sizeof(r)); assert(status==RM_OK && len_out==8);
 } return 0; }
'''
with tempfile.TemporaryDirectory(prefix='madeira-counter-metal-') as t:
 exe=Path(t)/'test'; subprocess.run(['xcrun','-sdk','macosx','clang','-fobjc-arc','-I',str(root/'research/remote-metal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=real+cases+real_end,text=True,check=True)
 status=subprocess.run([str(exe)]).returncode
 if status==77: print('real Metal counter test skipped: no compatible device')
 elif status: raise SystemExit(status)
 else: print('real Metal counter sample and resolve pass')
