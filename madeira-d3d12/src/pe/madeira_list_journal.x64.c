/* madeira-d3d12 list-journal, x64 part (see madeira_list_journal.h).
 *
 * Built with the x86_64 compiler and linked into the ARM64EC DLL, so an x64
 * game's calls to these methods stay in emulated x64 code instead of crossing
 * into ARM64EC. Each method appends one record to the list's journal. When the
 * record does not fit, the journal is flushed (one crossing) and the append is
 * tried again; a call the journal cannot hold (too many views, constants, ...)
 * flushes and goes to the ARM64EC method directly, so the order is kept.
 *
 * Each method's fast path makes no call, so it needs no stack frame; anything
 * else is a tail call to its out-of-line slow_* twin.
 *
 * No C library calls here: a call from this object would bind to an x64 import
 * this DLL does not have. Variable-size copies use rep movsb, which FEX turns
 * into its native copy. */
#include <windows.h>
#include <d3d12.h>
#include <stddef.h>
#include "madeira_list_journal.h"

#define SLOT(method) ((uint32_t)(offsetof(ID3D12GraphicsCommandList7Vtbl, method) / sizeof(void *)))
#define JOURNAL(list) ((struct mad_journal *)((char *)(list) + MAD_JR_OFFSET))
/* The list's struct mad_jr_ctx: the pointer just before its vtable's first slot
 * (never a RIP-relative global; see madeira_list_journal.h). */
#define CTX(list) (*(struct mad_jr_ctx *const *)((const char *)*(void *const *)(list) - 8))
#define ORIGINAL(method, type) ((type)CTX(list)->target[SLOT(method)])

typedef ID3D12GraphicsCommandList List;

static inline void copy_bytes(void *destination, const void *source, size_t count)
{
    __asm__ volatile("rep movsb" : "+D"(destination), "+S"(source), "+c"(count) : : "memory");
}

/* A record of `size` bytes (a multiple of 8) at the end of the journal, or NULL
 * when it does not fit. Makes no call. */
static inline struct mad_jr_head *take(List *list, uint32_t size, uint16_t op, uint32_t a)
{
    struct mad_journal *journal = JOURNAL(list);
    struct mad_jr_head *head;
    if (__builtin_expect(journal->cap - journal->used < size, 0)) return NULL;
    head = (struct mad_jr_head *)(journal->buf + journal->used);
    journal->used += size;
    head->op = op;
    head->size = (uint16_t)size;
    head->a = a;
    return head;
}

/* Replays what the journal holds (and allocates it the first time); non-zero
 * when a record of `size` bytes fits afterwards. */
static int make_room(List *list, uint32_t size)
{
    struct mad_journal *journal = JOURNAL(list);
    if (journal->used || !journal->buf) CTX(list)->flush(list);
    return journal->cap - journal->used >= size;
}

static inline uint32_t round8(uint32_t size)
{
    return (size + 7) & ~7u;
}

#define SLOW __attribute__((noinline))

/* ---- pipeline state and root signatures ---------------------------------- */

#define POINTER_METHOD(method, type, op)                                                       \
static void STDMETHODCALLTYPE journal_##method(List *list, type *object);                      \
static SLOW void slow_##method(List *list, type *object)                                       \
{                                                                                              \
    if (make_room(list, 16)) journal_##method(list, object);                                   \
    else ORIGINAL(method, void (STDMETHODCALLTYPE *)(List *, type *))(list, object);           \
}                                                                                              \
static void STDMETHODCALLTYPE journal_##method(List *list, type *object)                       \
{                                                                                              \
    struct mad_jr_head *head = take(list, 16, op, 0);                                          \
    if (!head) { slow_##method(list, object); return; }                                        \
    *(uint64_t *)(head + 1) = (uintptr_t)object;                                               \
}
POINTER_METHOD(SetPipelineState, ID3D12PipelineState, JR_PSO)
POINTER_METHOD(SetGraphicsRootSignature, ID3D12RootSignature, JR_ROOTSIG)
POINTER_METHOD(SetComputeRootSignature, ID3D12RootSignature, JR_CROOTSIG)

/* ---- root arguments ------------------------------------------------------- */

#define ROOT_VALUE_METHOD(method, type, value_of, op)                                          \
static void STDMETHODCALLTYPE journal_##method(List *list, UINT index, type value);            \
static SLOW void slow_##method(List *list, UINT index, type value)                             \
{                                                                                              \
    if (make_room(list, 16)) journal_##method(list, index, value);                             \
    else ORIGINAL(method, void (STDMETHODCALLTYPE *)(List *, UINT, type))(list, index, value); \
}                                                                                              \
static void STDMETHODCALLTYPE journal_##method(List *list, UINT index, type value)             \
{                                                                                              \
    struct mad_jr_head *head = take(list, 16, op, index);                                      \
    if (!head) { slow_##method(list, index, value); return; }                                  \
    *(uint64_t *)(head + 1) = value_of;                                                        \
}
ROOT_VALUE_METHOD(SetGraphicsRootConstantBufferView, D3D12_GPU_VIRTUAL_ADDRESS, value, JR_ROOT_CBV)
ROOT_VALUE_METHOD(SetGraphicsRootShaderResourceView, D3D12_GPU_VIRTUAL_ADDRESS, value, JR_ROOT_SRV)
ROOT_VALUE_METHOD(SetGraphicsRootUnorderedAccessView, D3D12_GPU_VIRTUAL_ADDRESS, value, JR_ROOT_UAV)
ROOT_VALUE_METHOD(SetComputeRootConstantBufferView, D3D12_GPU_VIRTUAL_ADDRESS, value, JR_CROOT_CBV)
ROOT_VALUE_METHOD(SetComputeRootShaderResourceView, D3D12_GPU_VIRTUAL_ADDRESS, value, JR_CROOT_SRV)
ROOT_VALUE_METHOD(SetComputeRootUnorderedAccessView, D3D12_GPU_VIRTUAL_ADDRESS, value, JR_CROOT_UAV)
ROOT_VALUE_METHOD(SetGraphicsRootDescriptorTable, D3D12_GPU_DESCRIPTOR_HANDLE, value.ptr, JR_ROOT_TABLE)
ROOT_VALUE_METHOD(SetComputeRootDescriptorTable, D3D12_GPU_DESCRIPTOR_HANDLE, value.ptr, JR_CROOT_TABLE)

#define ROOT_CONSTANT_METHOD(method, op)                                                       \
static void STDMETHODCALLTYPE journal_##method(List *list, UINT index, UINT data, UINT offset); \
static SLOW void slow_##method(List *list, UINT index, UINT data, UINT offset)                 \
{                                                                                              \
    if (make_room(list, 16)) journal_##method(list, index, data, offset);                      \
    else ORIGINAL(method, void (STDMETHODCALLTYPE *)(List *, UINT, UINT, UINT))(list, index, data, offset); \
}                                                                                              \
static void STDMETHODCALLTYPE journal_##method(List *list, UINT index, UINT data, UINT offset)  \
{                                                                                              \
    struct mad_jr_head *head = take(list, 16, op, index);                                      \
    if (!head) { slow_##method(list, index, data, offset); return; }                           \
    ((uint32_t *)(head + 1))[0] = data;                                                        \
    ((uint32_t *)(head + 1))[1] = offset;                                                      \
}
ROOT_CONSTANT_METHOD(SetGraphicsRoot32BitConstant, JR_ROOT_CONST)
ROOT_CONSTANT_METHOD(SetComputeRoot32BitConstant, JR_CROOT_CONST)

/* Calls with an array argument: `limit_ok` decides whether the journal takes the
 * call at all, `size` is its record size. */
#define ARRAY_METHOD(method, params, args, types, limit_ok, size, op, a, fill)                 \
static void STDMETHODCALLTYPE journal_##method params;                                         \
static SLOW void slow_##method params                                                          \
{                                                                                              \
    if ((limit_ok) && make_room(list, (size))) { journal_##method args; return; }              \
    if (JOURNAL(list)->used) CTX(list)->flush(list);                                           \
    ORIGINAL(method, void (STDMETHODCALLTYPE *) types) args;                                   \
}                                                                                              \
static void STDMETHODCALLTYPE journal_##method params                                          \
{                                                                                              \
    struct mad_jr_head *head = (limit_ok) ? take(list, (size), op, (a)) : NULL;                \
    if (!head) { slow_##method args; return; }                                                 \
    fill;                                                                                      \
}

ARRAY_METHOD(SetGraphicsRoot32BitConstants, (List *list, UINT index, UINT count, const void *data, UINT offset),
             (list, index, count, data, offset), (List *, UINT, UINT, const void *, UINT),
             count <= MAD_JR_MAX_CONSTS && (data || !count), round8(16 + count * 4), JR_ROOT_CONSTS, index,
             ((uint32_t *)(head + 1))[0] = count; ((uint32_t *)(head + 1))[1] = offset;
             copy_bytes((uint32_t *)(head + 1) + 2, data, count * 4))
ARRAY_METHOD(SetComputeRoot32BitConstants, (List *list, UINT index, UINT count, const void *data, UINT offset),
             (list, index, count, data, offset), (List *, UINT, UINT, const void *, UINT),
             count <= MAD_JR_MAX_CONSTS && (data || !count), round8(16 + count * 4), JR_CROOT_CONSTS, index,
             ((uint32_t *)(head + 1))[0] = count; ((uint32_t *)(head + 1))[1] = offset;
             copy_bytes((uint32_t *)(head + 1) + 2, data, count * 4))

/* ---- input assembler, rasterizer, output merger ---------------------------- */

ARRAY_METHOD(IASetPrimitiveTopology, (List *list, D3D12_PRIMITIVE_TOPOLOGY topology), (list, topology),
             (List *, D3D12_PRIMITIVE_TOPOLOGY), 1, 8, JR_TOPOLOGY, (uint32_t)topology, (void)0)
ARRAY_METHOD(IASetIndexBuffer, (List *list, const D3D12_INDEX_BUFFER_VIEW *view), (list, view),
             (List *, const D3D12_INDEX_BUFFER_VIEW *), 1, view ? 24 : 8, view ? JR_IB : JR_IB_NULL, 0,
             if (view) *(D3D12_INDEX_BUFFER_VIEW *)(head + 1) = *view)
ARRAY_METHOD(IASetVertexBuffers, (List *list, UINT start, UINT count, const D3D12_VERTEX_BUFFER_VIEW *views),
             (list, start, count, views), (List *, UINT, UINT, const D3D12_VERTEX_BUFFER_VIEW *),
             count <= MAD_JR_MAX_VIEWS, 16 + (views ? count * 16 : 0), JR_VBS, start,
             ((uint32_t *)(head + 1))[0] = count; ((uint32_t *)(head + 1))[1] = views != NULL;
             if (views && count) copy_bytes((uint32_t *)(head + 1) + 2, views, count * 16))
ARRAY_METHOD(RSSetViewports, (List *list, UINT count, const D3D12_VIEWPORT *viewports), (list, count, viewports),
             (List *, UINT, const D3D12_VIEWPORT *), count <= MAD_JR_MAX_RECTS && (viewports || !count),
             8 + count * 24, JR_VIEWPORTS, count, if (count) copy_bytes(head + 1, viewports, count * 24))
ARRAY_METHOD(RSSetScissorRects, (List *list, UINT count, const D3D12_RECT *rects), (list, count, rects),
             (List *, UINT, const D3D12_RECT *), count <= MAD_JR_MAX_RECTS && (rects || !count),
             8 + count * 16, JR_SCISSORS, count, if (count) copy_bytes(head + 1, rects, count * 16))
ARRAY_METHOD(OMSetStencilRef, (List *list, UINT reference), (list, reference), (List *, UINT),
             1, 8, JR_STENCIL_REF, reference, (void)0)
ARRAY_METHOD(OMSetBlendFactor, (List *list, const FLOAT *factor), (list, factor), (List *, const FLOAT *),
             1, 24, JR_BLEND_FACTOR, factor != NULL, if (factor) copy_bytes(head + 1, factor, 16))
ARRAY_METHOD(SetDescriptorHeaps, (List *list, UINT count, ID3D12DescriptorHeap *const *heaps), (list, count, heaps),
             (List *, UINT, ID3D12DescriptorHeap *const *), count <= MAD_JR_MAX_HEAPS && heaps,
             8 + count * 8, JR_HEAPS, count, if (count) copy_bytes(head + 1, heaps, count * 8))

/* ---- draws, dispatches, barriers ------------------------------------------ */

ARRAY_METHOD(DrawInstanced, (List *list, UINT vertex_count, UINT instance_count, UINT vertex_start, UINT instance_start),
             (list, vertex_count, instance_count, vertex_start, instance_start), (List *, UINT, UINT, UINT, UINT),
             1, 24, JR_DRAW, vertex_count,
             ((uint32_t *)(head + 1))[0] = instance_count; ((uint32_t *)(head + 1))[1] = vertex_start;
             ((uint32_t *)(head + 1))[2] = instance_start)
ARRAY_METHOD(DrawIndexedInstanced, (List *list, UINT index_count, UINT instance_count, UINT index_start, INT base_vertex, UINT instance_start),
             (list, index_count, instance_count, index_start, base_vertex, instance_start), (List *, UINT, UINT, UINT, INT, UINT),
             1, 24, JR_DRAW_INDEXED, index_count,
             ((uint32_t *)(head + 1))[0] = instance_count; ((uint32_t *)(head + 1))[1] = index_start;
             ((uint32_t *)(head + 1))[2] = (uint32_t)base_vertex; ((uint32_t *)(head + 1))[3] = instance_start)
ARRAY_METHOD(Dispatch, (List *list, UINT x, UINT y, UINT z), (list, x, y, z), (List *, UINT, UINT, UINT),
             1, 16, JR_DISPATCH, x, ((uint32_t *)(head + 1))[0] = y; ((uint32_t *)(head + 1))[1] = z)
ARRAY_METHOD(ResourceBarrier, (List *list, UINT count, const D3D12_RESOURCE_BARRIER *barriers), (list, count, barriers),
             (List *, UINT, const D3D12_RESOURCE_BARRIER *), count <= MAD_JR_MAX_BARRIERS && (barriers || !count),
             8 + count * 32, JR_BARRIERS, count, if (count) copy_bytes(head + 1, barriers, count * 32))

#define METHOD(name) { SLOT(name), (void *)journal_##name }
const struct mad_jr_method mad_jr_x64_methods[] = {
    METHOD(SetPipelineState),
    METHOD(SetGraphicsRootSignature),
    METHOD(SetComputeRootSignature),
    METHOD(SetGraphicsRootConstantBufferView),
    METHOD(SetGraphicsRootShaderResourceView),
    METHOD(SetGraphicsRootUnorderedAccessView),
    METHOD(SetComputeRootConstantBufferView),
    METHOD(SetComputeRootShaderResourceView),
    METHOD(SetComputeRootUnorderedAccessView),
    METHOD(SetGraphicsRootDescriptorTable),
    METHOD(SetComputeRootDescriptorTable),
    METHOD(SetGraphicsRoot32BitConstant),
    METHOD(SetComputeRoot32BitConstant),
    METHOD(SetGraphicsRoot32BitConstants),
    METHOD(SetComputeRoot32BitConstants),
    METHOD(IASetPrimitiveTopology),
    METHOD(IASetIndexBuffer),
    METHOD(IASetVertexBuffers),
    METHOD(RSSetViewports),
    METHOD(RSSetScissorRects),
    METHOD(OMSetStencilRef),
    METHOD(OMSetBlendFactor),
    METHOD(SetDescriptorHeaps),
    METHOD(DrawInstanced),
    METHOD(DrawIndexedInstanced),
    METHOD(Dispatch),
    METHOD(ResourceBarrier),
    { 0, NULL }
};

_Static_assert(sizeof(D3D12_INDEX_BUFFER_VIEW) == 16, "index buffer view");
_Static_assert(sizeof(D3D12_VERTEX_BUFFER_VIEW) == 16, "vertex buffer view");
_Static_assert(sizeof(D3D12_VIEWPORT) == 24, "viewport");
_Static_assert(sizeof(D3D12_RECT) == 16, "rect");
_Static_assert(sizeof(D3D12_RESOURCE_BARRIER) == 32, "barrier");
