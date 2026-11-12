#!/usr/bin/env python3
"""Exercise the production residency encoder and wire validation."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
dxmt = Path(os.environ.get('DXMT_SOURCE', root / 'dxmt'))
source = (dxmt / 'src/winemetal/unix/winemetal_unix.c').read_text()
start = source.index('static NTSTATUS\nwmt_remote_residency_batch(')
end = source.index('\n\nstatic NTSTATUS\n_MTLDevice_newResidencySet', start)
helper = source[start:end]
start = source.index('#define WMT_WOW64_POINTER_WRAPPER(name, type, field)')
end = source.index('\n\nWMT_WOW64_POINTER_WRAPPER(', start)
wrapper = source[start:end]
prelude = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "protocol.h"
typedef uint64_t obj_handle_t;
typedef uint32_t NTSTATUS;
#define STATUS_INVALID_PARAMETER 0xc000000du
#define STATUS_UNSUCCESSFUL 0xc0000001u
#define STATUS_SUCCESS 0u
static uint32_t calls, response;
static uint32_t wmtr_call(uint16_t op, const void *data, uint32_t length,
                          void *out, uint32_t outlen, uint32_t *got) {
  (void)out; (void)outlen; (void)got;
  assert(op == RM_OP_RESIDENCY_BATCH);
  const struct rm_residency_batch *p = data;
  assert(rm_residency_batch_valid(p, length));
  if (p->count) {
    const uint64_t *v = (const uint64_t *)(p + 1);
    assert(p->count == 2 && v[0] == 0x8000000000000011ULL && v[1] == 0x8000000000000022ULL);
  }
  calls++;
  return response;
}
'''
wow = r'''
static unsigned char guest[256];
static void *UInt32ToPtr(uint32_t address) { return address ? guest + address : NULL; }
struct fake_ptr { void *ptr; };
struct args { uint64_t set; struct fake_ptr allocations; uint64_t count; };
static NTSTATUS add(void *ptr) {
  struct args *a = ptr;
  return wmt_remote_residency_batch(a->set, RM_RESIDENCY_ADD, a->allocations.ptr, a->count);
}
''' + wrapper + r'''
WMT_WOW64_POINTER_WRAPPER(add, args, allocations)
'''
main = r'''
int main(void) {
  obj_handle_t v[2] = {0x8000000000000011ULL, 0x8000000000000022ULL};
  assert(wmt_remote_residency_batch(0, RM_RESIDENCY_PROBE, NULL, 0) == STATUS_SUCCESS);
  assert(wmt_remote_residency_batch(9, RM_RESIDENCY_ADD, v, 2) == STATUS_SUCCESS);
  assert(wmt_remote_residency_batch(9, RM_RESIDENCY_REMOVE, v, 2) == STATUS_SUCCESS);
  assert(wmt_remote_residency_batch(9, RM_RESIDENCY_REMOVE_ALL, NULL, 0) == STATUS_SUCCESS);
  assert(wmt_remote_residency_batch(9, RM_RESIDENCY_ADD, NULL, 2) == STATUS_INVALID_PARAMETER);
  assert(wmt_remote_residency_batch(9, RM_RESIDENCY_ADD, v, UINT64_MAX) == STATUS_INVALID_PARAMETER);
  assert(calls == 4);
  memcpy(guest + 8, v, sizeof v);
  struct args shifted = {9, {(void *)(uintptr_t)8}, 2};
  assert(add_wow64(&shifted) == STATUS_SUCCESS && shifted.allocations.ptr == (void *)(uintptr_t)8);
  assert(calls == 5);
  response = RM_ERR_BAD_OPCODE;
  assert(wmt_remote_residency_batch(0, RM_RESIDENCY_PROBE, NULL, 0) == STATUS_UNSUCCESSFUL);
  struct rm_residency_batch p = {9, RM_RESIDENCY_ADD, 2};
  assert(!rm_residency_batch_valid(&p, sizeof p));
  p.count = UINT32_MAX; assert(!rm_residency_batch_valid(&p, sizeof p));
  p.count = 0; p.action = 99; assert(!rm_residency_batch_valid(&p, sizeof p));
  p.action = RM_RESIDENCY_PROBE; assert(!rm_residency_batch_valid(&p, sizeof p));
  p.set = 0; assert(rm_residency_batch_valid(&p, sizeof p));
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-residency-') as tmp:
    exe = Path(tmp) / 'test'
    subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I',
                    str(root / 'research/remote-metal'), '-x', 'c', '-', '-o', str(exe)],
                   input=prelude + helper + wow + main, text=True, check=True)
    subprocess.run([str(exe)], check=True)
print('remote residency wire validation and encoding pass')

# Run the actual host case against fake Metal objects. It validates all handles
# before mutating a set, so one invalid entry cannot apply a partial batch.
host = (root / 'research/remote-metal/host/rmetald.m').read_text()
start = host.index('        case RM_OP_RESIDENCY_BATCH: {')
end = host.index('        case RM_OP_RESIDENCY_ADD: {', start)
case = host[start:end]
objc = r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdlib.h>
#include "protocol.h"
@interface FakeAllocation : NSObject <MTLAllocation> @end
@implementation FakeAllocation @end
@interface FakeSet : NSObject <MTLResidencySet>
@property unsigned adds;
@property unsigned removes;
@property unsigned clears;
@end
@implementation FakeSet
- (void)addAllocations:(id<MTLAllocation> const *)a count:(NSUInteger)n { (void)a; self.adds += n; }
- (void)removeAllocations:(id<MTLAllocation> const *)a count:(NSUInteger)n { (void)a; self.removes += n; }
- (void)removeAllAllocations { self.clears++; }
@end
static FakeSet *test_set;
static FakeAllocation *test_alloc;
static unsigned reply_status;
static id rm_resolve(uint64_t x, uint32_t *err) {
  *err = RM_OK;
  if (x == 1) return test_set;
  if (x == 2) return test_alloc;
  *err = RM_ERR_BAD_HANDLE; return nil;
}
static void reply(int fd, const struct rm_hdr *h, uint32_t status, const void *v, uint32_t len) {
  (void)fd; (void)h; (void)v; (void)len; reply_status = status;
}
static void invoke(void *payload, uint32_t length) {
  struct rm_hdr h = { .payload_len = length }; uint32_t err = RM_OK; int fd = 0;
  switch (RM_OP_RESIDENCY_BATCH) {
'''
objc_end = r'''
  }
}
int main(void) { @autoreleasepool {
  test_set = [FakeSet new]; test_alloc = [FakeAllocation new];
  struct { struct rm_residency_batch h; uint64_t entries[2]; } p = {{1, RM_RESIDENCY_ADD, 2}, {2, 99}};
  invoke(&p, sizeof p); assert(reply_status == RM_ERR_BAD_HANDLE && test_set.adds == 0);
  p.entries[1] = 2; invoke(&p, sizeof p); assert(reply_status == RM_OK && test_set.adds == 2);
  p.h.action = RM_RESIDENCY_REMOVE; invoke(&p, sizeof p); assert(reply_status == RM_OK && test_set.removes == 2);
  p.h.action = RM_RESIDENCY_REMOVE_ALL; p.h.count = 0; invoke(&p, sizeof p.h);
  assert(reply_status == RM_OK && test_set.clears == 1);
  p.h.action = RM_RESIDENCY_PROBE; p.h.set = 0; invoke(&p, sizeof p.h); assert(reply_status == RM_OK);
  p.h.count = 100; invoke(&p, sizeof p.h); assert(reply_status == RM_ERR_SHORT_PAYLOAD);
} }
'''
with tempfile.TemporaryDirectory(prefix='madeira-residency-host-') as tmp:
    exe = Path(tmp) / 'test'
    subprocess.run(['xcrun', '-sdk', 'macosx', 'clang', '-fobjc-arc', '-Wno-protocol', '-Wno-objc-protocol-property-synthesis', '-Wno-mismatched-parameter-types', '-I',
                    str(root / 'research/remote-metal'), '-x', 'objective-c', '-', '-framework', 'Foundation',
                    '-framework', 'Metal', '-o', str(exe)], input=objc + case + objc_end, text=True, check=True)
    subprocess.run([str(exe)], check=True)
print('remote host residency batches validate before mutation')

# Exercise the same handler with a real Metal device when one is available.
real = objc.replace('static FakeSet *test_set;', 'static id<MTLResidencySet> test_set;').replace(
    'static FakeAllocation *test_alloc;', 'static id<MTLAllocation> test_alloc;')
real_end = r'''
  }
}
int main(void) { @autoreleasepool {
  id<MTLDevice> d = MTLCreateSystemDefaultDevice();
  if (!d) return 77;
  if (@available(macOS 15.0, *)) {
    MTLResidencySetDescriptor *desc = [MTLResidencySetDescriptor new]; NSError *error = nil;
    test_set = [d newResidencySetWithDescriptor:desc error:&error];
    test_alloc = [d newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    if (!test_set || !test_alloc) return 77;
    struct { struct rm_residency_batch h; uint64_t entries[2]; } p = {{1, RM_RESIDENCY_ADD, 2}, {2, 99}};
    invoke(&p, sizeof p); assert(reply_status == RM_ERR_BAD_HANDLE && test_set.allocationCount == 0);
    p.h.count = 1; invoke(&p, sizeof p.h + 8); assert(reply_status == RM_OK && test_set.allocationCount == 1);
    [test_set commit];
    p.h.action = RM_RESIDENCY_REMOVE; invoke(&p, sizeof p.h + 8);
    assert(reply_status == RM_OK); [test_set commit]; assert(test_set.allocationCount == 0);
    p.h.action = RM_RESIDENCY_ADD; invoke(&p, sizeof p.h + 8); assert(test_set.allocationCount == 1);
    p.h.action = RM_RESIDENCY_REMOVE_ALL; p.h.count = 0; invoke(&p, sizeof p.h);
    assert(reply_status == RM_OK); [test_set commit]; assert(test_set.allocationCount == 0);
    return 0;
  }
  return 77;
} }
'''
with tempfile.TemporaryDirectory(prefix='madeira-residency-metal-') as tmp:
    exe = Path(tmp) / 'test'
    subprocess.run(['xcrun', '-sdk', 'macosx', 'clang', '-fobjc-arc', '-Wno-protocol',
                    '-Wno-objc-protocol-property-synthesis', '-Wno-mismatched-parameter-types', '-I',
                    str(root / 'research/remote-metal'), '-x', 'objective-c', '-', '-framework', 'Foundation',
                    '-framework', 'Metal', '-o', str(exe)], input=real + case + real_end, text=True, check=True)
    result = subprocess.run([str(exe)], check=False)
    if result.returncode == 77:
        print('real Metal residency test skipped: no compatible device')
    else:
        result.check_returncode()
        print('real Metal residency add, remove and clear pass')

# Exercise the command-buffer timing RPC using a real local Metal command buffer.
start = host.index('        case RM_OP_COMMAND_BUFFER_PROPERTY: {')
end = host.index('        case RM_OP_CMDBUF_STATUS: {', start)
property_case = host[start:end]
property_source = r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include "protocol.h"
#include "winemetal.h"
static id<MTLCommandBuffer> command_buffer;
static uint32_t reply_status;
static uint64_t value;
static id rm_resolve(uint64_t h, uint32_t *err) {
  *err = h == 1 ? RM_OK : RM_ERR_BAD_HANDLE;
  return h == 1 ? command_buffer : nil;
}
static void reply(int fd, const struct rm_hdr *h, uint32_t status, const void *p, uint32_t n) {
  (void)fd; (void)h; reply_status = status; value = 0;
  if (p && n == sizeof(struct rm_ret_u64)) value = ((const struct rm_ret_u64 *)p)->value;
}
static void invoke(void *payload, uint32_t n) {
  struct rm_hdr h = {.payload_len = n}; uint32_t err = RM_OK; int fd = 0;
  switch (RM_OP_COMMAND_BUFFER_PROPERTY) {
'''
property_end = r'''
  }
}
int main(void) { @autoreleasepool {
  id<MTLDevice> d = MTLCreateSystemDefaultDevice(); if (!d) return 77;
  id<MTLCommandQueue> q = [d newCommandQueue]; command_buffer = [q commandBuffer];
  if (!command_buffer) return 77;
  struct rm_arg_handle_u64 a = {1, WMTCommandBufferPropertyGPUStartTime};
  invoke(&a, sizeof a); assert(reply_status == RM_OK && value == 0);
  [command_buffer commit]; [command_buffer waitUntilCompleted];
  a.arg = WMTCommandBufferPropertyGPUEndTime; invoke(&a, sizeof a);
  assert(reply_status == RM_OK && value == (uint64_t)(command_buffer.GPUEndTime * 1000000000.0));
  a.handle = 9; invoke(&a, sizeof a); assert(reply_status == RM_ERR_BAD_HANDLE);
  invoke(&a, sizeof a - 1); assert(reply_status == RM_ERR_SHORT_PAYLOAD);
  return 0;
} }
'''
with tempfile.TemporaryDirectory(prefix='madeira-remote-property-') as tmp:
    exe = Path(tmp) / 'test'
    subprocess.run(['xcrun', '-sdk', 'macosx', 'clang', '-fobjc-arc', '-I',
                    str(root / 'research/remote-metal'), '-I', str(dxmt / 'src/winemetal'),
                    '-x', 'objective-c', '-', '-framework', 'Foundation', '-framework', 'Metal', '-o', str(exe)],
                   input=property_source + property_case + property_end, text=True, check=True)
    result = subprocess.run([str(exe)], check=False)
    if result.returncode == 77:
        print('real Metal command-buffer property test skipped: no compatible device')
    else:
        result.check_returncode()
        print('real Metal command-buffer property test passed')

# Test the production guest handler, including an older host's bad-opcode reply.
start = source.index('static NTSTATUS\n_MTLCommandBuffer_property(')
end = source.index('\n\nstatic NTSTATUS\n_MTLDevice_newTileRenderPipelineState', start)
property_handler = source[start:end]
guest_property = r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include "protocol.h"
#include "winemetal.h"
typedef uint32_t NTSTATUS;
#define STATUS_SUCCESS 0u
#define STATUS_UNSUCCESSFUL 0xc0000001u
struct unixcall_generic_obj_uint64_uint64_ret { uint64_t handle, arg, ret; };
static uint32_t response;
static int wmtr_enabled(void) { return 1; }
static uint32_t wmtr_call(uint16_t op, const void *arg, uint32_t size, void *out, uint32_t cap, uint32_t *got) {
  (void)got; assert(op == RM_OP_COMMAND_BUFFER_PROPERTY && size == sizeof(struct rm_arg_handle_u64));
  const struct rm_arg_handle_u64 *a = arg; assert(a->handle == 77 && a->arg == 2);
  assert(cap == sizeof(struct rm_ret_u64));
  ((struct rm_ret_u64 *)out)->value = response == RM_OK ? 1234 : 0;
  return response;
}
'''
guest_end = r'''
int main(void) {
  struct unixcall_generic_obj_uint64_uint64_ret a = {77, 2, 999};
  assert(_MTLCommandBuffer_property(&a) == STATUS_SUCCESS && a.ret == 1234);
  response = RM_ERR_BAD_OPCODE; a.ret = 999;
  assert(_MTLCommandBuffer_property(&a) == STATUS_UNSUCCESSFUL && a.ret == 0);
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-remote-property-guest-') as tmp:
    exe = Path(tmp) / 'test'
    subprocess.run(['xcrun', '-sdk', 'macosx', 'clang', '-I',
                    str(root / 'research/remote-metal'), '-I', str(dxmt / 'src/winemetal'),
                    '-x', 'objective-c', '-', '-framework', 'Foundation', '-framework', 'Metal', '-o', str(exe)],
                   input=guest_property + property_handler + guest_end, text=True, check=True)
    subprocess.run([str(exe)], check=True)
print('remote command-buffer guest handler passes')
