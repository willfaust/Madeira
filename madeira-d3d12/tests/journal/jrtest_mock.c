/* list-journal test, x64 PE half: madeira_list_journal.inc.c (the ARM64EC replay
 * code, here compiled for x64) over mock list_* methods that log every call.
 * Loaded natively by jrtest.c; no imports, no C library.
 *
 * Build: x86_64-w64-mingw32-clang -O1 -shared -nostdlib -ffreestanding -fno-builtin
 *        -Wl,--image-base=0x10000000 -Wl,--entry= -I<pe src> jrtest_mock.c -o jrtest_mock.dll */
#include <windows.h>
#include <d3d12.h>
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include "madeira_list_journal.h"

/* ---- freestanding support --------------------------------------------------- */
void *memset(void *d, int c, size_t n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, size_t n) { unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }
int memcmp(const void *a, const void *b, size_t n) { const unsigned char *p = a, *q = b; for (; n; n--, p++, q++) if (*p != *q) return *p - *q; return 0; }
static unsigned char arena[1 << 22]; static size_t arena_used; int fail_malloc;
void *malloc(size_t n) { void *p; if (fail_malloc || arena_used + n > sizeof arena) return NULL; p = arena + arena_used; arena_used += (n + 15) & ~15ull; return p; }
void free(void *p) { (void)p; }
void qsort(void *b, size_t n, size_t s, int (*cmp)(const void *, const void *)) { (void)b; (void)n; (void)s; (void)cmp; }
int snprintf(char *b, size_t n, const char *f, ...) { (void)f; if (n) b[0] = 0; return 0; }
int _fltused;
static void d3d12_log(const char *fmt, ...) { (void)fmt; }
static long long mad_cfg_int_pe(const char *key, long long dflt) { (void)key; return dflt; }
static int mad_scbv_on(void) { return 0; }
void madeira_d3d12_note_unimplemented(const char *iface, const char *method) { (void)iface; (void)method; }
static HRESULT mad_pd_get(const void *obj, REFGUID guid, UINT *data_size, void *data) { (void)obj; (void)guid; (void)data_size; (void)data; return E_FAIL; }
static HRESULT mad_pd_set(const void *obj, REFGUID guid, UINT data_size, const void *data) { (void)obj; (void)guid; (void)data_size; (void)data; return E_FAIL; }
static HRESULT mad_pd_set_iface(const void *obj, REFGUID guid, const IUnknown *data) { (void)obj; (void)guid; (void)data; return E_FAIL; }
#include "madeira_d3d12_stubs.h"

/* ---- the runtime's shapes ----------------------------------------------------- */
struct mad_jr_seen {
    const void *pso, *rs[2], *heaps[2];
    UINT64 root[2][16];
    UINT16 root_valid[2];
    UINT topology; UINT8 topology_valid, ib_valid, vb_valid, vp_valid, sc_valid;
    D3D12_INDEX_BUFFER_VIEW ib;
    D3D12_VERTEX_BUFFER_VIEW vb[4];
    D3D12_VIEWPORT vp;
    D3D12_RECT sc;
};
struct mad_list {
    void *vtbl; LONG refs; const IID *iid; const char *name;
    struct mad_journal jr;
    struct mad_jr_seen jr_seen;
};
struct mad_resource { unsigned char pad[0x70]; UINT64 gpu_address; };
static struct { ID3D12GraphicsCommandList7Vtbl v7; void *OMSetFrontAndBackStencilRef; } g_list_vtbl8;
static ID3D12Device10Vtbl g_device_vtbl; static ID3D12CommandQueueVtbl g_queue_vtbl; static ID3D12CommandAllocatorVtbl g_alloc_vtbl;
static ID3D12FenceVtbl g_fence_vtbl; static ID3D12Resource2Vtbl g_res_vtbl; static ID3D12DescriptorHeapVtbl g_heap_vtbl;
static ID3D12PipelineStateVtbl g_pso_vtbl; static ID3D12RootSignatureVtbl g_rootsig_vtbl;

/* ---- the call log --------------------------------------------------------------- */
struct event { uint32_t method; uint32_t pad; uint64_t a[7]; };
__declspec(dllexport) struct event events[1 << 16];
__declspec(dllexport) uint32_t nevents;
static uint64_t sum(const void *p, size_t n)
{
    const unsigned char *b = p; uint64_t h = 1469598103934665603ull;
    if (!p) return 0xdead;
    while (n--) h = (h ^ *b++) * 1099511628211ull;
    return h;
}
#define LOG(m, ...) do { uint64_t v_[7] = { __VA_ARGS__ }; struct event *e_ = &events[nevents++ & 0xffff]; e_->method = m; memcpy(e_->a, v_, sizeof v_); } while (0)
#define SLOT(m) (offsetof(ID3D12GraphicsCommandList7Vtbl, m) / sizeof(void *))
typedef ID3D12GraphicsCommandList L;

static void STDMETHODCALLTYPE list_SetPipelineState(L *t, ID3D12PipelineState *p) { LOG(SLOT(SetPipelineState), (uintptr_t)t, (uintptr_t)p); }
static void STDMETHODCALLTYPE list_SetGraphicsRootSignature(L *t, ID3D12RootSignature *p) { LOG(SLOT(SetGraphicsRootSignature), (uintptr_t)t, (uintptr_t)p); }
static void STDMETHODCALLTYPE list_SetComputeRootSignature(L *t, ID3D12RootSignature *p) { LOG(SLOT(SetComputeRootSignature), (uintptr_t)t, (uintptr_t)p); }
#define ADDR(m) static void STDMETHODCALLTYPE list_##m(L *t, UINT i, D3D12_GPU_VIRTUAL_ADDRESS a) { LOG(SLOT(m), (uintptr_t)t, i, a); }
ADDR(SetGraphicsRootConstantBufferView) ADDR(SetGraphicsRootShaderResourceView) ADDR(SetGraphicsRootUnorderedAccessView)
ADDR(SetComputeRootConstantBufferView) ADDR(SetComputeRootShaderResourceView) ADDR(SetComputeRootUnorderedAccessView)
#define TABLE(m) static void STDMETHODCALLTYPE list_##m(L *t, UINT i, D3D12_GPU_DESCRIPTOR_HANDLE h) { LOG(SLOT(m), (uintptr_t)t, i, h.ptr); }
TABLE(SetGraphicsRootDescriptorTable) TABLE(SetComputeRootDescriptorTable)
#define CONST1(m) static void STDMETHODCALLTYPE list_##m(L *t, UINT i, UINT d, UINT o) { LOG(SLOT(m), (uintptr_t)t, i, d, o); }
CONST1(SetGraphicsRoot32BitConstant) CONST1(SetComputeRoot32BitConstant)
#define CONSTN(m) static void STDMETHODCALLTYPE list_##m(L *t, UINT i, UINT n, const void *d, UINT o) { LOG(SLOT(m), (uintptr_t)t, i, n, n ? sum(d, n * 4) : 0, o); }
CONSTN(SetGraphicsRoot32BitConstants) CONSTN(SetComputeRoot32BitConstants)
static void STDMETHODCALLTYPE list_IASetPrimitiveTopology(L *t, D3D12_PRIMITIVE_TOPOLOGY p) { LOG(SLOT(IASetPrimitiveTopology), (uintptr_t)t, p); }
static void STDMETHODCALLTYPE list_IASetIndexBuffer(L *t, const D3D12_INDEX_BUFFER_VIEW *v) { LOG(SLOT(IASetIndexBuffer), (uintptr_t)t, v != NULL, v ? sum(v, sizeof *v) : 0); }
static void STDMETHODCALLTYPE list_IASetVertexBuffers(L *t, UINT s, UINT n, const D3D12_VERTEX_BUFFER_VIEW *v) { LOG(SLOT(IASetVertexBuffers), (uintptr_t)t, s, n, v != NULL, v && n ? sum(v, n * sizeof *v) : 0); }
static void STDMETHODCALLTYPE list_RSSetViewports(L *t, UINT n, const D3D12_VIEWPORT *v) { LOG(SLOT(RSSetViewports), (uintptr_t)t, n, n ? sum(v, n * sizeof *v) : 0); }
static void STDMETHODCALLTYPE list_RSSetScissorRects(L *t, UINT n, const D3D12_RECT *v) { LOG(SLOT(RSSetScissorRects), (uintptr_t)t, n, n ? sum(v, n * sizeof *v) : 0); }
static void STDMETHODCALLTYPE list_OMSetStencilRef(L *t, UINT r) { LOG(SLOT(OMSetStencilRef), (uintptr_t)t, r); }
static void STDMETHODCALLTYPE list_OMSetBlendFactor(L *t, const FLOAT *f) { LOG(SLOT(OMSetBlendFactor), (uintptr_t)t, f != NULL, f ? sum(f, 16) : 0); }
static void STDMETHODCALLTYPE list_SetDescriptorHeaps(L *t, UINT n, ID3D12DescriptorHeap *const *h) { LOG(SLOT(SetDescriptorHeaps), (uintptr_t)t, n, h != NULL, h && n ? sum(h, n * 8) : 0); }
static void STDMETHODCALLTYPE list_DrawInstanced(L *t, UINT a, UINT b, UINT c, UINT d) { LOG(SLOT(DrawInstanced), (uintptr_t)t, a, b, c, d); }
static void STDMETHODCALLTYPE list_DrawIndexedInstanced(L *t, UINT a, UINT b, UINT c, INT d, UINT e) { LOG(SLOT(DrawIndexedInstanced), (uintptr_t)t, a, b, c, (uint32_t)d, e); }
static void STDMETHODCALLTYPE list_Dispatch(L *t, UINT x, UINT y, UINT z) { LOG(SLOT(Dispatch), (uintptr_t)t, x, y, z); }
static void STDMETHODCALLTYPE list_ResourceBarrier(L *t, UINT n, const D3D12_RESOURCE_BARRIER *b) { LOG(SLOT(ResourceBarrier), (uintptr_t)t, n, n ? sum(b, n * sizeof *b) : 0); }
/* Not journaled: reached through the trampolines. */
static HRESULT STDMETHODCALLTYPE list_Close(L *t) { LOG(SLOT(Close), (uintptr_t)t); return 0x1234; }
static void STDMETHODCALLTYPE list_ClearDepthStencilView(L *t, D3D12_CPU_DESCRIPTOR_HANDLE h, D3D12_CLEAR_FLAGS f, FLOAT depth, UINT8 s, UINT n, const D3D12_RECT *r)
{ union { FLOAT f; UINT32 u; } d = { depth }; LOG(SLOT(ClearDepthStencilView), (uintptr_t)t, h.ptr, f, d.u, s, n, (uintptr_t)r); }
static void STDMETHODCALLTYPE list_CopyBufferRegion(L *t, ID3D12Resource *d, UINT64 doff, ID3D12Resource *s, UINT64 soff, UINT64 n)
{ LOG(SLOT(CopyBufferRegion), (uintptr_t)t, (uintptr_t)d, doff, (uintptr_t)s, soff, n); }

/* The x64 half lives in the real DLL; mad_jr_install is not run here. */
void *const mad_jr_list_tramps[MAD_JR_SLOTS];
void *const mad_jr_count_tramps[MAD_JR_SLOTS];
const struct mad_jr_method mad_jr_x64_methods[1];
char mad_res_gva_x64[1];

#include "madeira_list_journal.inc.c"

/* ---- what the harness needs ----------------------------------------------------- */
struct mock_api {
    void (*flush)(void *);
    void *method[MAD_JR_SLOTS];   /* the mock behind each slot (NULL: not mocked) */
    int *fail_malloc;
    size_t list_size, jr_offset, seen_offset;
    uint32_t slots[32];                /* the mocked slots, in the order of mock_api's list */
};
__declspec(dllexport) void mock_api(struct mock_api *api)
{
    memset(api, 0, sizeof *api);
    api->flush = mad_jr_flush;
    unsigned k = 0;
#define M(m) (api->method[SLOT(m)] = (void *)list_##m, api->slots[k++] = SLOT(m))
    M(SetPipelineState); M(SetGraphicsRootSignature); M(SetComputeRootSignature);
    M(SetGraphicsRootConstantBufferView); M(SetGraphicsRootShaderResourceView); M(SetGraphicsRootUnorderedAccessView);
    M(SetComputeRootConstantBufferView); M(SetComputeRootShaderResourceView); M(SetComputeRootUnorderedAccessView);
    M(SetGraphicsRootDescriptorTable); M(SetComputeRootDescriptorTable);
    M(SetGraphicsRoot32BitConstant); M(SetComputeRoot32BitConstant); M(SetGraphicsRoot32BitConstants); M(SetComputeRoot32BitConstants);
    M(IASetPrimitiveTopology); M(IASetIndexBuffer); M(IASetVertexBuffers); M(RSSetViewports); M(RSSetScissorRects);
    M(OMSetStencilRef); M(OMSetBlendFactor); M(SetDescriptorHeaps); M(DrawInstanced); M(DrawIndexedInstanced);
    M(Dispatch); M(ResourceBarrier); M(Close); M(ClearDepthStencilView); M(CopyBufferRegion);
#undef M
    api->fail_malloc = &fail_malloc;
    api->list_size = sizeof(struct mad_list);
    api->jr_offset = offsetof(struct mad_list, jr);
    api->seen_offset = offsetof(struct mad_list, jr_seen);
}
__declspec(dllexport) void mock_census(LONG64 *ops, LONG64 *repeats)
{
    unsigned k;
    for (k = 0; k < JR_OP_COUNT; k++) { ops[k] = g_jr_ops[k]; repeats[k] = g_jr_redundant[k]; g_jr_ops[k] = g_jr_redundant[k] = 0; }
}
__declspec(dllexport) void mock_set_census(int on) { g_jr_census = (uint8_t)on; }
int DllMainCRTStartup(void *a, unsigned b, void *c) { (void)a; (void)b; (void)c; return 1; }
