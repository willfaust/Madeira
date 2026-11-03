/* madeira-d3d12 list-journal, ARM64EC part (see madeira_list_journal.h).
 * Included by madeira_d3d12.c after the list_* methods it replays.
 *
 * madeira.cfg list-journal = 1 (default 0): the hot command-list methods and
 * ID3D12Resource::GetGPUVirtualAddress run as x64 code, without a crossing per
 * call; the list replays its journal here.
 * madeira.cfg api-census = 1 (default 0): every 5 s with the [perf] lines, a
 * [d3d12-census] line counts the game's D3D12 calls per frame by method (all
 * interfaces the runtime builds), and, with the journal, how many of its state
 * sets repeat what is already bound. For finding work the game itself does that
 * could be avoided. Both are read once, when the first device is created. */

/* The trampolines' state, one per interface; each vtable's jr_ctx points at its
 * own (madeira_list_journal.h: the x64 code finds it through the object). */
static struct mad_jr_ctx g_jr_list_ctx;
static struct mad_jr_ctx g_jr_ctx[8];   /* g_jr_counted, in order */
static uint8_t g_jr_census;

static int g_jr_on = -1;
static int g_jr_installed;   /* build_vtables leaves the tables alone from then on */
static LONG64 g_jr_ops[JR_OP_COUNT], g_jr_redundant[JR_OP_COUNT];
static LONG64 g_jr_flushes, g_jr_records, g_jr_barrier_entries, g_jr_const_words;

#define MAD_LIST_SLOT_COUNT (sizeof g_list_vtbl8 / sizeof(void *))
_Static_assert(MAD_LIST_SLOT_COUNT <= MAD_JR_SLOTS, "list slots");
_Static_assert(offsetof(struct mad_jr_ctx, calls) == MAD_JR_CTX_CALLS, "ctx calls offset (madeira_list_journal.h)");
_Static_assert(offsetof(struct mad_jr_ctx, flush) == MAD_JR_CTX_FLUSH, "ctx flush offset");
_Static_assert(offsetof(struct mad_jr_ctx, census) == MAD_JR_CTX_CENSUS, "ctx census offset");
_Static_assert(offsetof(ID3D12Resource2Vtbl, GetGPUVirtualAddress) / sizeof(void *) == MAD_RES_GVA_SLOT, "GetGPUVirtualAddress slot");
_Static_assert(offsetof(struct mad_list, jr) == MAD_JR_OFFSET, "journal offset (madeira_list_journal.h)");
_Static_assert(offsetof(struct mad_list, jr.used) == MAD_JR_USED_OFFSET, "journal fill offset");
_Static_assert(offsetof(struct mad_resource, gpu_address) == MAD_RES_GPU_ADDRESS_OFFSET, "resource gpu_address offset");

/* api-census with the journal: did this state set change anything? Per list,
 * since the last Reset. */
static int mad_jr_repeats(struct mad_list *l, const struct mad_jr_head *h)
{
    struct mad_jr_seen *s = &l->jr_seen;
    const UINT64 *v = (const UINT64 *)(h + 1);
    int bp, same;
    switch (h->op) {
    case JR_PSO:
        same = s->pso == (const void *)(uintptr_t)v[0];
        s->pso = (const void *)(uintptr_t)v[0];
        return same;
    case JR_ROOTSIG: case JR_CROOTSIG:
        bp = h->op == JR_CROOTSIG;
        same = s->rs[bp] == (const void *)(uintptr_t)v[0];
        if (!same) { s->rs[bp] = (const void *)(uintptr_t)v[0]; s->root_valid[bp] = 0; }
        return same;
    case JR_ROOT_CBV: case JR_ROOT_SRV: case JR_ROOT_UAV: case JR_ROOT_TABLE:
    case JR_CROOT_CBV: case JR_CROOT_SRV: case JR_CROOT_UAV: case JR_CROOT_TABLE:
        bp = h->op >= JR_CROOT_CBV;
        if (h->a >= 16) return 0;
        same = (s->root_valid[bp] >> h->a & 1) && s->root[bp][h->a] == v[0];
        s->root[bp][h->a] = v[0]; s->root_valid[bp] |= (UINT16)(1u << h->a);
        return same;
    case JR_TOPOLOGY:
        same = s->topology_valid && s->topology == h->a;
        s->topology = h->a; s->topology_valid = 1;
        return same;
    case JR_IB:
        same = s->ib_valid && !memcmp(&s->ib, h + 1, sizeof s->ib);
        memcpy(&s->ib, h + 1, sizeof s->ib); s->ib_valid = 1;
        return same;
    case JR_VBS: {
        const UINT32 *p = (const UINT32 *)(h + 1);
        UINT start = h->a, n = p[0], k;
        const D3D12_VERTEX_BUFFER_VIEW *views = (const D3D12_VERTEX_BUFFER_VIEW *)(p + 2);
        if (!p[1] || !n || start + n > 4) return 0;
        same = 1;
        for (k = 0; k < n; k++) {
            if (!(s->vb_valid >> (start + k) & 1) || memcmp(&s->vb[start + k], &views[k], sizeof views[k])) same = 0;
            s->vb[start + k] = views[k]; s->vb_valid |= (UINT8)(1u << (start + k));
        }
        return same;
    }
    case JR_VIEWPORTS:
        if (h->a != 1) return 0;
        same = s->vp_valid && !memcmp(&s->vp, h + 1, sizeof s->vp);
        memcpy(&s->vp, h + 1, sizeof s->vp); s->vp_valid = 1;
        return same;
    case JR_SCISSORS:
        if (h->a != 1) return 0;
        same = s->sc_valid && !memcmp(&s->sc, h + 1, sizeof s->sc);
        memcpy(&s->sc, h + 1, sizeof s->sc); s->sc_valid = 1;
        return same;
    case JR_HEAPS:
        if (h->a > 2) return 0;
        same = !memcmp(s->heaps, h + 1, h->a * sizeof(void *)) && (h->a == 2 || !s->heaps[1]);
        memset(s->heaps, 0, sizeof s->heaps); memcpy(s->heaps, h + 1, h->a * sizeof(void *));
        return same;
    }
    return 0;
}

/* Replays the journal through the list_* methods, in order, then empties it.
 * The first call allocates it. Runs on the thread recording the list. */
static void mad_jr_flush(void *This)
{
    struct mad_list *l = (struct mad_list *)This;
    struct mad_journal *j = &l->jr;
    const UINT8 *p, *end;
    LONG64 ops[JR_OP_COUNT] = { 0 }, repeats[JR_OP_COUNT] = { 0 }, records = 0, barriers = 0, words = 0;
    ID3D12GraphicsCommandList *list = (ID3D12GraphicsCommandList *)This;
    if (!j->buf) {
        j->buf = malloc(MAD_JR_BYTES);
        j->cap = j->buf ? MAD_JR_BYTES : 0;
        j->used = 0;
        return;
    }
    p = j->buf; end = j->buf + j->used;
    while (p < end) {
        const struct mad_jr_head *h = (const struct mad_jr_head *)p;
        const UINT64 *v = (const UINT64 *)(h + 1);
        const UINT32 *w = (const UINT32 *)(h + 1);
        D3D12_GPU_DESCRIPTOR_HANDLE table;
        switch (h->op) {
        case JR_PSO: list_SetPipelineState(list, (ID3D12PipelineState *)(uintptr_t)v[0]); break;
        case JR_ROOTSIG: list_SetGraphicsRootSignature(list, (ID3D12RootSignature *)(uintptr_t)v[0]); break;
        case JR_CROOTSIG: list_SetComputeRootSignature(list, (ID3D12RootSignature *)(uintptr_t)v[0]); break;
        case JR_ROOT_CBV: list_SetGraphicsRootConstantBufferView(list, h->a, v[0]); break;
        case JR_ROOT_SRV: list_SetGraphicsRootShaderResourceView(list, h->a, v[0]); break;
        case JR_ROOT_UAV: list_SetGraphicsRootUnorderedAccessView(list, h->a, v[0]); break;
        case JR_ROOT_TABLE: table.ptr = v[0]; list_SetGraphicsRootDescriptorTable(list, h->a, table); break;
        case JR_CROOT_CBV: list_SetComputeRootConstantBufferView(list, h->a, v[0]); break;
        case JR_CROOT_SRV: list_SetComputeRootShaderResourceView(list, h->a, v[0]); break;
        case JR_CROOT_UAV: list_SetComputeRootUnorderedAccessView(list, h->a, v[0]); break;
        case JR_CROOT_TABLE: table.ptr = v[0]; list_SetComputeRootDescriptorTable(list, h->a, table); break;
        case JR_ROOT_CONST: list_SetGraphicsRoot32BitConstant(list, h->a, w[0], w[1]); words++; break;
        case JR_CROOT_CONST: list_SetComputeRoot32BitConstant(list, h->a, w[0], w[1]); words++; break;
        case JR_ROOT_CONSTS: list_SetGraphicsRoot32BitConstants(list, h->a, w[0], w[0] ? w + 2 : NULL, w[1]); words += w[0]; break;
        case JR_CROOT_CONSTS: list_SetComputeRoot32BitConstants(list, h->a, w[0], w[0] ? w + 2 : NULL, w[1]); words += w[0]; break;
        case JR_TOPOLOGY: list_IASetPrimitiveTopology(list, (D3D12_PRIMITIVE_TOPOLOGY)h->a); break;
        case JR_IB: list_IASetIndexBuffer(list, (const D3D12_INDEX_BUFFER_VIEW *)(h + 1)); break;
        case JR_IB_NULL: list_IASetIndexBuffer(list, NULL); break;
        case JR_VBS: list_IASetVertexBuffers(list, h->a, w[0], w[1] ? (const D3D12_VERTEX_BUFFER_VIEW *)(w + 2) : NULL); break;
        case JR_VIEWPORTS: list_RSSetViewports(list, h->a, h->a ? (const D3D12_VIEWPORT *)(h + 1) : NULL); break;
        case JR_SCISSORS: list_RSSetScissorRects(list, h->a, h->a ? (const D3D12_RECT *)(h + 1) : NULL); break;
        case JR_STENCIL_REF: list_OMSetStencilRef(list, h->a); break;
        case JR_BLEND_FACTOR: list_OMSetBlendFactor(list, h->a ? (const FLOAT *)(h + 1) : NULL); break;
        case JR_DRAW: list_DrawInstanced(list, h->a, w[0], w[1], w[2]); break;
        case JR_DRAW_INDEXED: list_DrawIndexedInstanced(list, h->a, w[0], w[1], (INT)w[2], w[3]); break;
        case JR_DISPATCH: list_Dispatch(list, h->a, w[0], w[1]); break;
        case JR_BARRIERS: list_ResourceBarrier(list, h->a, h->a ? (const D3D12_RESOURCE_BARRIER *)(h + 1) : NULL); barriers += h->a; break;
        case JR_HEAPS: list_SetDescriptorHeaps(list, h->a, (ID3D12DescriptorHeap *const *)(h + 1)); break;
        default: {
            static LONG said;
            if (!InterlockedExchange(&said, 1))
                d3d12_log("[madeira-d3d12] list-journal: unknown record %u (size %u); the rest of this journal is dropped\n", h->op, h->size);
            p = end;
            continue;
        }
        }
        if (g_jr_census) {
            ops[h->op]++;
            if (mad_jr_repeats(l, h)) repeats[h->op]++;
        }
        records++;
        p += h->size;
    }
    j->used = 0;
    if (g_jr_census) {
        unsigned k;
        for (k = 1; k < JR_OP_COUNT; k++) {
            if (ops[k]) InterlockedAdd64(&g_jr_ops[k], ops[k]);
            if (repeats[k]) InterlockedAdd64(&g_jr_redundant[k], repeats[k]);
        }
        InterlockedIncrement64(&g_jr_flushes);
        InterlockedAdd64(&g_jr_records, records);
        if (barriers) InterlockedAdd64(&g_jr_barrier_entries, barriers);
        if (words) InterlockedAdd64(&g_jr_const_words, words);
    }
}

/* api-census: the interfaces whose slots go through counting trampolines. */
static const struct {
    const char *iface;
    const char *const *names;
    unsigned count;
    void *table;
} g_jr_counted[] = {
#define MAD_JR_COUNTED(prefix, name, table) { prefix, madeira_slots_##name, sizeof madeira_slots_##name / sizeof(char *), &table }
    MAD_JR_COUNTED("dev", ID3D12Device10, g_device_vtbl),
    MAD_JR_COUNTED("queue", ID3D12CommandQueue, g_queue_vtbl),
    MAD_JR_COUNTED("alloc", ID3D12CommandAllocator, g_alloc_vtbl),
    MAD_JR_COUNTED("fence", ID3D12Fence, g_fence_vtbl),
    MAD_JR_COUNTED("res", ID3D12Resource2, g_res_vtbl),
    MAD_JR_COUNTED("heap", ID3D12DescriptorHeap, g_heap_vtbl),
    MAD_JR_COUNTED("pso", ID3D12PipelineState, g_pso_vtbl),
    MAD_JR_COUNTED("rootsig", ID3D12RootSignature, g_rootsig_vtbl),
#undef MAD_JR_COUNTED
};

/* After every build_vtables (it refills all slots with the ARM64EC methods). */
static void mad_jr_install(void)
{
    void **slots = (void **)&g_list_vtbl8;
    unsigned i, k;
    const struct mad_jr_method *m;
    if (g_jr_installed) return;   /* the tables kept their trampolines (build_vtables returned early) */
    if (g_jr_on < 0) {
        int journal = mad_cfg_int_pe("list-journal", 0) ? 1 : 0;
        g_jr_census = mad_cfg_int_pe("api-census", 0) ? 1 : 0;
        if (journal && mad_scbv_on() > 0) {
            d3d12_log("[madeira-d3d12] list-journal off: static-cbv reads descriptor tables while a list records\n");
            journal = 0;
        }
        g_jr_on = journal;
        if (journal || g_jr_census)
            d3d12_log("[madeira-d3d12] list-journal = %d, api-census = %d: %s\n", journal, g_jr_census,
                      journal ? "hot list methods and GetGPUVirtualAddress run as x64, lists replay at Close" : "calls counted only");
    }
    /* Every table gets its jr_ctx first: the x64 GetGPUVirtualAddress reads the
     * resource table's even with api-census off. */
    g_jr_list_ctx.flush = mad_jr_flush;
    g_jr_list_ctx.census = g_jr_census;
    slots[-1] = &g_jr_list_ctx;
    for (k = 0; k < sizeof g_jr_counted / sizeof g_jr_counted[0]; k++) {
        g_jr_ctx[k].census = g_jr_census;
        ((void **)g_jr_counted[k].table)[-1] = &g_jr_ctx[k];
    }
    if (g_jr_on || g_jr_census) {
        for (i = 0; i < MAD_LIST_SLOT_COUNT; i++) { g_jr_list_ctx.target[i] = slots[i]; slots[i] = mad_jr_list_tramps[i]; }
        if (g_jr_on) for (m = mad_jr_x64_methods; m->fn; m++) slots[m->slot] = m->fn;
    }
    if (g_jr_census) {
        for (k = 0; k < sizeof g_jr_counted / sizeof g_jr_counted[0]; k++) {
            void **table = (void **)g_jr_counted[k].table;
            for (i = 0; i < g_jr_counted[k].count; i++) {
                g_jr_ctx[k].target[i] = table[i];
                table[i] = mad_jr_count_tramps[i];
            }
        }
    }
    /* After the census: the x64 GetGPUVirtualAddress counts in the resource ctx itself. */
    if (g_jr_on) g_res_vtbl.GetGPUVirtualAddress = (void *)mad_res_gva_x64;
    g_jr_installed = g_jr_on || g_jr_census;
}

static const char *const g_jr_op_method[JR_OP_COUNT] = {
    [JR_PSO] = "SetPipelineState", [JR_ROOTSIG] = "SetGraphicsRootSignature", [JR_CROOTSIG] = "SetComputeRootSignature",
    [JR_ROOT_CBV] = "SetGraphicsRootConstantBufferView", [JR_ROOT_SRV] = "SetGraphicsRootShaderResourceView",
    [JR_ROOT_UAV] = "SetGraphicsRootUnorderedAccessView", [JR_ROOT_TABLE] = "SetGraphicsRootDescriptorTable",
    [JR_CROOT_CBV] = "SetComputeRootConstantBufferView", [JR_CROOT_SRV] = "SetComputeRootShaderResourceView",
    [JR_CROOT_UAV] = "SetComputeRootUnorderedAccessView", [JR_CROOT_TABLE] = "SetComputeRootDescriptorTable",
    [JR_ROOT_CONST] = "SetGraphicsRoot32BitConstant", [JR_ROOT_CONSTS] = "SetGraphicsRoot32BitConstants",
    [JR_CROOT_CONST] = "SetComputeRoot32BitConstant", [JR_CROOT_CONSTS] = "SetComputeRoot32BitConstants",
    [JR_TOPOLOGY] = "IASetPrimitiveTopology", [JR_IB] = "IASetIndexBuffer", [JR_IB_NULL] = "IASetIndexBuffer(NULL)",
    [JR_VBS] = "IASetVertexBuffers", [JR_VIEWPORTS] = "RSSetViewports", [JR_SCISSORS] = "RSSetScissorRects",
    [JR_STENCIL_REF] = "OMSetStencilRef", [JR_BLEND_FACTOR] = "OMSetBlendFactor", [JR_DRAW] = "DrawInstanced",
    [JR_DRAW_INDEXED] = "DrawIndexedInstanced", [JR_DISPATCH] = "Dispatch", [JR_BARRIERS] = "ResourceBarrier",
    [JR_HEAPS] = "SetDescriptorHeaps",
};

struct mad_jr_count { const char *prefix, *name; LONG64 n, repeats; };
static int mad_jr_count_cmp(const void *a, const void *b)
{
    LONG64 x = ((const struct mad_jr_count *)a)->n, y = ((const struct mad_jr_count *)b)->n;
    return x < y ? 1 : x > y ? -1 : 0;
}

/* Every 5 s from mad_perf_present: the calls of the last window, per frame. */
static void mad_jr_report(LONG presents, double wall)
{
    struct mad_jr_count c[MAD_JR_SLOTS * 9 + JR_OP_COUNT];
    unsigned n = 0, i, k, shown;
    double np = presents > 0 ? (double)presents : 1.0;
    char line[960]; int len;
    LONG64 ops[JR_OP_COUNT], rep[JR_OP_COUNT], draws, sets = 0, repeated = 0;
    if (!g_jr_census) return;
    for (k = 1; k < JR_OP_COUNT; k++) { ops[k] = InterlockedExchange64(&g_jr_ops[k], 0); rep[k] = InterlockedExchange64(&g_jr_redundant[k], 0); }
    for (i = 0; i < MAD_LIST_SLOT_COUNT; i++) {
        LONG64 v = (ULONG)InterlockedExchange((LONG *)&g_jr_list_ctx.calls[i], 0);
        if (!v) continue;
        c[n].prefix = "list"; c[n].name = i < sizeof madeira_slots_ID3D12GraphicsCommandList7 / sizeof(char *)
                                       ? madeira_slots_ID3D12GraphicsCommandList7[i] : "OMSetFrontAndBackStencilRef";
        c[n].n = v; c[n].repeats = -1; n++;
    }
    for (k = 1; k < JR_OP_COUNT; k++) {
        if (!ops[k]) continue;
        c[n].prefix = "list"; c[n].name = g_jr_op_method[k]; c[n].n = ops[k]; c[n].repeats = rep[k]; n++;
        if (k <= JR_CROOT_TABLE || k == JR_TOPOLOGY || k == JR_IB || k == JR_VBS || k == JR_VIEWPORTS || k == JR_SCISSORS || k == JR_HEAPS) {
            sets += ops[k]; repeated += rep[k];
        }
    }
    for (k = 0; k < sizeof g_jr_counted / sizeof g_jr_counted[0]; k++)
        for (i = 0; i < g_jr_counted[k].count; i++) {
            LONG64 v = (ULONG)InterlockedExchange((LONG *)&g_jr_ctx[k].calls[i], 0);
            if (!v) continue;
            c[n].prefix = g_jr_counted[k].iface; c[n].name = g_jr_counted[k].names[i]; c[n].n = v; c[n].repeats = -1; n++;
        }
    draws = ops[JR_DRAW] + ops[JR_DRAW_INDEXED];
    {
        LONG64 fl = InterlockedExchange64(&g_jr_flushes, 0), rc = InterlockedExchange64(&g_jr_records, 0);
        LONG64 be = InterlockedExchange64(&g_jr_barrier_entries, 0), cw = InterlockedExchange64(&g_jr_const_words, 0);
        if (g_jr_on > 0)
            d3d12_log("[d3d12-census] %.1fs, %ld presents, per frame: draws %.0f, dispatches %.0f, journal %.0f records in %.0f flushes, "
                      "state sets %.0f of which %.0f (%.0f%%) repeat what is bound (pso %.0f/%.0f, root signature %.0f/%.0f, "
                      "root arguments %.0f/%.0f, topology %.0f/%.0f, index buffer %.0f/%.0f, vertex buffers %.0f/%.0f, "
                      "viewport %.0f/%.0f, scissor %.0f/%.0f, heaps %.0f/%.0f), barriers %.0f entries in %.0f calls, root constants %.0f words\n",
                      wall, (long)presents, draws / np, ops[JR_DISPATCH] / np, rc / np, fl / np,
                      sets / np, repeated / np, sets ? 100.0 * (double)repeated / (double)sets : 0.0,
                      rep[JR_PSO] / np, ops[JR_PSO] / np, (rep[JR_ROOTSIG] + rep[JR_CROOTSIG]) / np, (ops[JR_ROOTSIG] + ops[JR_CROOTSIG]) / np,
                      (rep[JR_ROOT_CBV] + rep[JR_ROOT_SRV] + rep[JR_ROOT_UAV] + rep[JR_ROOT_TABLE] + rep[JR_CROOT_CBV] + rep[JR_CROOT_SRV] + rep[JR_CROOT_UAV] + rep[JR_CROOT_TABLE]) / np,
                      (ops[JR_ROOT_CBV] + ops[JR_ROOT_SRV] + ops[JR_ROOT_UAV] + ops[JR_ROOT_TABLE] + ops[JR_CROOT_CBV] + ops[JR_CROOT_SRV] + ops[JR_CROOT_UAV] + ops[JR_CROOT_TABLE]) / np,
                      rep[JR_TOPOLOGY] / np, ops[JR_TOPOLOGY] / np, rep[JR_IB] / np, ops[JR_IB] / np, rep[JR_VBS] / np, ops[JR_VBS] / np,
                      rep[JR_VIEWPORTS] / np, ops[JR_VIEWPORTS] / np, rep[JR_SCISSORS] / np, ops[JR_SCISSORS] / np,
                      rep[JR_HEAPS] / np, ops[JR_HEAPS] / np, be / np, ops[JR_BARRIERS] / np, cw / np);
    }
    qsort(c, n, sizeof c[0], mad_jr_count_cmp);
    len = snprintf(line, sizeof line, "[d3d12-census] calls per frame:");
    for (i = 0, shown = 0; i < n && shown < 40; i++, shown++) {
        if (len > (int)sizeof line - 80) {
            d3d12_log("%s\n", line);
            len = snprintf(line, sizeof line, "[d3d12-census] (cont):");
        }
        len += snprintf(line + len, sizeof line - len, " %s.%s %.1f", c[i].prefix, c[i].name, c[i].n / np);
    }
    if (n) d3d12_log("%s\n", line);
}
