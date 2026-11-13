#!/usr/bin/env python3
"""Test remote texture readback, row padding and 32-bit destination pointers."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2];dxmt=Path(os.environ.get('DXMT_SOURCE',root/'dxmt'))
host=(root/'research/remote-metal/host/rmetald.m').read_text()
start=host.index('static int rm_read_layout(');end=host.index('\n\n/* Replay',start);helper=host[start:end]
start=host.index('        case RM_OP_TEXTURE_READ_LAYOUT: {');end=host.index('        case RM_OP_NEW_TILE_PIPELINE: {',start);cases=host[start:end]
pre=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <string.h>
#include "protocol.h"
#include "winemetal.h"
#define RM_MAX_PAYLOAD (256u << 20)
static id<MTLTexture> texture;static uint32_t status,length_out;static unsigned char response[1024];
static id rm_resolve(uint64_t h,uint32_t *err) {*err=h==1?RM_OK:RM_ERR_BAD_HANDLE;return h==1?texture:nil;}
static void reply(int fd,const struct rm_hdr *h,uint32_t code,const void *data,uint32_t length) {(void)fd;(void)h;status=code;length_out=length;if(length) {assert(length<=sizeof(response));memcpy(response,data,length);}}
static void invoke(uint16_t op,void *payload,uint32_t length) {int fd=0;uint32_t err=RM_OK;struct rm_hdr h={.payload_len=length};switch(op) {
'''
main=r'''
} }
int main(void) { @autoreleasepool {
 struct rm_texture_read_layout layout; assert(rm_read_layout((MTLPixelFormat)WMTPixelFormatBC1_RGBA,&layout) && layout.block_width==4 && layout.block_height==4 && layout.block_bytes==8);
#define CHECK_ASTC(w,h) do { \
 for (unsigned f=0; f<3; f++) { \
  enum WMTPixelFormat formats[]={WMTPixelFormatASTC_##w##x##h##_sRGB,WMTPixelFormatASTC_##w##x##h##_LDR,WMTPixelFormatASTC_##w##x##h##_HDR}; \
  assert(rm_read_layout((MTLPixelFormat)formats[f],&layout) && layout.block_width==w && layout.block_height==h && layout.block_bytes==16); \
 } } while(0)
 CHECK_ASTC(4,4); CHECK_ASTC(5,4); CHECK_ASTC(5,5); CHECK_ASTC(6,5); CHECK_ASTC(6,6);
 CHECK_ASTC(8,5); CHECK_ASTC(8,6); CHECK_ASTC(8,8); CHECK_ASTC(10,5); CHECK_ASTC(10,6);
 CHECK_ASTC(10,8); CHECK_ASTC(10,10); CHECK_ASTC(12,10); CHECK_ASTC(12,12);
#undef CHECK_ASTC
 assert(rm_read_layout((MTLPixelFormat)WMTPixelFormatEAC_R11Snorm,&layout) && layout.block_width==4 && layout.block_height==4 && layout.block_bytes==8);
 assert(rm_read_layout((MTLPixelFormat)WMTPixelFormatETC2_RGB8A1,&layout) && layout.block_bytes==8);
 assert(rm_read_layout((MTLPixelFormat)WMTPixelFormatEAC_RGBA8,&layout) && layout.block_bytes==16);
 assert(rm_read_layout((MTLPixelFormat)WMTPixelFormatGBGR422,&layout) && layout.block_width==2 && layout.block_height==1 && layout.block_bytes==4);
 assert(rm_read_layout((MTLPixelFormat)WMTPixelFormatPVRTC_RGB_2BPP,&layout) && layout.block_width==8 && layout.block_height==4 && layout.block_bytes==8 && layout.reserved==RM_TEXTURE_READ_PVRTC);
 assert(rm_read_layout((MTLPixelFormat)WMTPixelFormatPVRTC_RGBA_4BPP,&layout) && layout.block_width==4 && layout.block_height==4 && layout.block_bytes==8 && layout.reserved==RM_TEXTURE_READ_PVRTC);
 id<MTLDevice> d=MTLCreateSystemDefaultDevice();if(!d)return 77;
 MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:3 height:2 mipmapped:NO];desc.storageMode=MTLStorageModeShared;
 texture=[d newTextureWithDescriptor:desc];if(!texture)return 77;
 uint8_t pixels[24];for(unsigned i=0;i<24;i++)pixels[i]=i+1;
 [texture replaceRegion:MTLRegionMake2D(0,0,3,2) mipmapLevel:0 withBytes:pixels bytesPerRow:12];
 struct rm_arg_handle q={1};invoke(RM_OP_TEXTURE_READ_LAYOUT,&q,sizeof(q));assert(status==RM_OK && length_out==sizeof(layout));memcpy(&layout,response,sizeof(layout));assert(layout.block_width==1 && layout.block_bytes==4);
 struct rm_texture_read_region r={1,0,0,0,3,2,0,0};invoke(RM_OP_TEXTURE_READ_REGION,&r,sizeof(r)-1);assert(status==RM_ERR_SHORT_PAYLOAD);
 invoke(RM_OP_TEXTURE_READ_REGION,&r,sizeof(r));assert(status==RM_OK && length_out==24 && !memcmp(response,pixels,24));
 r.width=4;invoke(RM_OP_TEXTURE_READ_REGION,&r,sizeof(r));assert(status==RM_ERR_SHORT_PAYLOAD);
 r.width=3;r.level=64;invoke(RM_OP_TEXTURE_READ_REGION,&r,sizeof(r));assert(status!=RM_OK);
 desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatASTC_5x4_LDR width:10 height:8 mipmapped:NO]; desc.storageMode=MTLStorageModeShared;
 id<MTLTexture> astc=[d newTextureWithDescriptor:desc];
 if (astc) {
  texture=astc; uint8_t blocks[64]; for(unsigned i=0;i<64;i++)blocks[i]=(uint8_t)(i+1);
  [texture replaceRegion:MTLRegionMake2D(0,0,10,8) mipmapLevel:0 withBytes:blocks bytesPerRow:32];
  r=(struct rm_texture_read_region){1,0,0,0,10,8,0,0}; invoke(RM_OP_TEXTURE_READ_REGION,&r,sizeof(r));
  assert(status==RM_OK && length_out==64 && !memcmp(response,blocks,64));
  r.x=1;invoke(RM_OP_TEXTURE_READ_REGION,&r,sizeof(r));assert(status!=RM_OK);
 } else { puts("real ASTC texture test skipped: format unavailable"); }
 desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)WMTPixelFormatPVRTC_RGB_2BPP width:16 height:16 mipmapped:YES]; desc.storageMode=MTLStorageModeShared;
 id<MTLTexture> pvrtc=[d supportsFamily:MTLGPUFamilyApple2] ? [d newTextureWithDescriptor:desc] : nil;
 if (pvrtc) {
  texture=pvrtc; uint8_t blocks[64], direct[64]={0}; for(unsigned i=0;i<64;i++)blocks[i]=(uint8_t)(i+1);
  [texture replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:blocks bytesPerRow:0];
  [texture getBytes:direct bytesPerRow:0 fromRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0];
  struct rm_texture_read_pvrtc p={{1,0,0,0,16,16,0,0},8,16};
  invoke(RM_OP_TEXTURE_READ_PVRTC,&p,sizeof(p)); assert(status==RM_OK && length_out==16 && !memcmp(response,direct+8,16));
  p.offset=63;p.length=2;invoke(RM_OP_TEXTURE_READ_PVRTC,&p,sizeof(p));assert(status!=RM_OK);
  p.offset=0;p.length=16;p.region.width=8;invoke(RM_OP_TEXTURE_READ_PVRTC,&p,sizeof(p));assert(status!=RM_OK);
  [texture replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:2 withBytes:blocks bytesPerRow:0];
  memset(direct,0,sizeof(direct));
  [texture getBytes:direct bytesPerRow:0 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:2];
  p=(struct rm_texture_read_pvrtc){{1,0,0,0,4,4,2,0},0,32};
  invoke(RM_OP_TEXTURE_READ_PVRTC,&p,sizeof(p));assert(status==RM_OK && length_out==32 && !memcmp(response,direct,32));
  p.offset=32;p.length=1;invoke(RM_OP_TEXTURE_READ_PVRTC,&p,sizeof(p));assert(status!=RM_OK);
 } else { puts("real PVRTC texture test skipped: format unavailable"); }
 }return 0;}
'''
with tempfile.TemporaryDirectory(prefix='madeira-read-host-') as t:
 exe=Path(t)/'test';subprocess.run(['xcrun','-sdk','macosx','clang','-fobjc-arc','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=pre.replace('static void invoke(',helper+'\nstatic void invoke(')+cases+main,text=True,check=True)
 code=subprocess.run([str(exe)]).returncode
 if code==77: print('real Metal texture read test skipped: no device')
 elif code: raise SystemExit(code)
 else: print('remote texture read host and real Metal pass')
source=(dxmt/'src/winemetal/unix/winemetal_unix.c').read_text();start=source.index('static NTSTATUS\n_MTLTexture_getBytes(');end=source.index('\n\n/*\n * Definition from cache.c',start);handler=source[start:end]
start=source.index('#define WMT_WOW64_POINTER_WRAPPER(name, type, field)');end=source.index('\n\nWMT_WOW64_POINTER_WRAPPER(',start);wrapper=source[start:end]
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
struct unixcall_mtltexture_replaceregion {uint64_t texture;struct WMTOrigin origin;struct WMTSize size;uint64_t level,slice;struct WMTMemoryPointer data;uint64_t bytes_per_row,bytes_per_image;};
static unsigned char guest[(9u<<20)];static unsigned calls,chunk_mode;static uint32_t fail;
static void *UInt32ToPtr(uint32_t p) {return p?guest+p:NULL;}
static int wmtr_enabled(void) {return 1;}
static uint32_t wmtr_call(uint16_t op,const void *arg,uint32_t len,void *out,uint32_t cap,uint32_t *got) {
 calls++;if(fail)return fail;
 if(op==RM_OP_TEXTURE_READ_LAYOUT) {assert(len==sizeof(struct rm_arg_handle));*(struct rm_texture_read_layout*)out=chunk_mode==2?(struct rm_texture_read_layout){8,4,8,RM_TEXTURE_READ_PVRTC}:chunk_mode?(struct rm_texture_read_layout){1,1,16,0}:(struct rm_texture_read_layout){4,4,8,0};*got=sizeof(struct rm_texture_read_layout);return RM_OK;}
 if(op==RM_OP_TEXTURE_READ_PVRTC) { const struct rm_texture_read_pvrtc *p=arg;assert(len==sizeof(*p) && p->length==cap); memset(out,p->offset?0x99:0x55,cap);*got=cap;return RM_OK; }
 const struct rm_texture_read_region *a=arg;assert(op==RM_OP_TEXTURE_READ_REGION && len==sizeof(*a) && a->texture==1);
 if(chunk_mode) { assert(a->width==1 && (a->y==0 || a->y==524288)); memset(out,a->y?0x88:0x77,cap);*got=cap;return RM_OK; }
 assert(a->width==8 && a->height==8 && cap==32);
 uint8_t *p=out;memset(p,a->z?0x33:0x11,16);memset(p+16,a->z?0x44:0x22,16);*got=32;return RM_OK;
}
'''
client_end=r'''
int main(void) { @autoreleasepool {
 memset(guest,0xee,sizeof(guest));struct unixcall_mtltexture_replaceregion p={0};p.texture=1;p.size=(struct WMTSize){8,8,2};p.data.ptr=(void *)(uintptr_t)32;p.bytes_per_row=24;p.bytes_per_image=64;
 assert(_MTLTexture_getBytes_wow64(&p)==STATUS_SUCCESS && p.data.ptr==(void *)(uintptr_t)32 && calls==3);
 for(unsigned i=0;i<16;i++) {assert(guest[32+i]==0x11);assert(guest[56+i]==0x22);assert(guest[96+i]==0x33);assert(guest[120+i]==0x44);}
 for(unsigned i=0;i<8;i++) {assert(guest[48+i]==0xee);assert(guest[112+i]==0xee);}
 p.bytes_per_row=15;assert(_MTLTexture_getBytes_wow64(&p)==STATUS_INVALID_PARAMETER);
 p.bytes_per_row=24;fail=RM_ERR_BAD_OPCODE;assert(_MTLTexture_getBytes_wow64(&p)==STATUS_UNSUCCESSFUL);
 fail=0;chunk_mode=1;calls=0;p.size=(struct WMTSize){1,524289,1};p.bytes_per_row=16;p.bytes_per_image=0;
 assert(_MTLTexture_getBytes_wow64(&p)==STATUS_SUCCESS && calls==3 && guest[32]==0x77 && guest[32+(8u<<20)]==0x88);
 chunk_mode=2;calls=0;p.size=(struct WMTSize){8192,4100,1};p.bytes_per_row=0;
 assert(_MTLTexture_getBytes_wow64(&p)==STATUS_SUCCESS && calls==3 && guest[32]==0x55 && guest[32+(8u<<20)]==0x99);
 p.bytes_per_row=8;assert(_MTLTexture_getBytes_wow64(&p)==STATUS_INVALID_PARAMETER);
 calls=0;p.size=(struct WMTSize){4,4,1};p.bytes_per_row=0;guest[64]=0xee;
 assert(_MTLTexture_getBytes_wow64(&p)==STATUS_SUCCESS && calls==2 && guest[32]==0x55 && guest[63]==0x55 && guest[64]==0xee);
 }return 0;}
'''
with tempfile.TemporaryDirectory(prefix='madeira-read-client-') as t:
 exe=Path(t)/'test';code=client+handler+'\n'+wrapper+'\nWMT_WOW64_POINTER_WRAPPER(_MTLTexture_getBytes, unixcall_mtltexture_replaceregion, data)\n'+client_end
 subprocess.run(['xcrun','-sdk','macosx','clang','-I',str(root/'research/remote-metal'),'-I',str(dxmt/'src/winemetal'),'-x','objective-c','-','-framework','Foundation','-framework','Metal','-o',str(exe)],input=code,text=True,check=True);subprocess.run([str(exe)],check=True)
print('remote texture read client padding and 32-bit pointer tests pass')
