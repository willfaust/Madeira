/*  madeira-d3d12: M2 native D3D12 ABI slice.
 *
 *  The minimum set of objects the design's M2 gate names: a device that can
 *  create a queue, an allocator, a command list and a fence; a list that can be
 *  recorded, closed and reset; a queue that can execute it and signal; and a
 *  fence that reports completion and wakes a Win32 event waiter.
 *
 *  There is deliberately no Metal here yet. M2 is about the COM ABI, object
 *  lifetime and synchronisation being right, and mixing GPU work into that would
 *  make a failure ambiguous between the two. The buffer-copy/readback test comes
 *  next and gives the fence something real to be synchronising.
 *
 *  Every vtable is fully populated from generated stubs first, then implemented
 *  methods are assigned over them. So the supported surface is exactly the list
 *  of assignments below, and anything else returns E_NOTIMPL and names itself.
 */

#define INITGUID
#define COBJMACROS
#include <initguid.h>
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_5.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>

/* The existing winemetal bridge, already used by d3d11.dll. Reusing it means
 * the D3D12 path inherits the working local/remote split rather than growing a
 * second transport, which the design asks for explicitly. */
#include "winemetal.h"

#include "madeira_d3d12_stubs.h"
#include "madeira_ir_abi.h"

#define MADEIRA_D3D12_BUILD "madeira-d3d12 M2 " __DATE__ " " __TIME__

/* ---- diagnostics ---------------------------------------------------------
 * Routed through OutputDebugStringA so it lands in the same log as everything
 * else on this port. */
/* ml931: keep a shader's bytecode on disk (C:\madeira-cs, i.e. the prefix's
 * drive_c) so a kernel identified at dispatch time by its pipeline pointer can
 * be disassembled offline. Files, not log lines: a 60 KB blob does not belong
 * in the log. */
static void mad_dump_blob(const char *name, const void *data, SIZE_T len) {
    char path[300]; HANDLE h; DWORD wr = 0;
    if (!data || !len || len > (1u << 20)) return;
    CreateDirectoryA("C:\\madeira-cs", NULL);
    snprintf(path, sizeof path, "C:\\madeira-cs\\%s", name);
    h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile(h, data, (DWORD)len, &wr, NULL);
    CloseHandle(h);
}
static void d3d12_log(const char *fmt, ...) {
    /* ml909: every record handed to __wine_dbg_output MUST end in a newline
     * and be shorter than ntdll's 1020-byte line buffer. A record truncated
     * by vsnprintf lost its newline, ntdll kept accumulating the fragments
     * of successive calls into one "line", and when that overflowed it
     * raised STATUS_BUFFER_OVERFLOW (0x80000005) on the calling thread --
     * the engine's submission thread, in the middle of the draw census.
     * That exception, not the media player, is what ended every run at
     * present ~1800 (ants49/50/52). */
    char buf[1000];
    size_t len;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    len = strlen(buf);
    if (!len || buf[len - 1] != '\n') {
        if (len >= sizeof buf - 1) { buf[sizeof buf - 2] = '\n'; buf[sizeof buf - 1] = 0; }
        else { buf[len] = '\n'; buf[len + 1] = 0; }
    }
    OutputDebugStringA(buf);
    /* Wine's own debug output: an unbuffered write on the log's file
     * descriptor from unix ntdll, which reaches the log from EVERY process.
     * The engine launched from the desktop is a child of its launcher and has
     * no standard handles, so stderr below goes nowhere for it (ml854 showed
     * a whole run with no runtime lines at all). */
    {
        typedef int (__cdecl *dbg_output_fn)(const char *);
        static dbg_output_fn dbg_output;
        static int looked;
        if (!looked) {
            HMODULE nt = GetModuleHandleA("ntdll.dll");
            if (nt) dbg_output = (dbg_output_fn)GetProcAddress(nt, "__wine_dbg_output");
            looked = 1;
        }
        if (dbg_output) dbg_output(buf);
    }
    /* Also stderr. OutputDebugStringA reaches the log as a debug-string
     * exception, and the host dumper caps those: the ml836 run recorded four
     * of them and dropped every line after, so the shader decisions that run
     * proved could not be read back. The guest's stderr is not capped, which
     * is why the test's own output survived in the same log. */
    fputs(buf, stderr);
    fflush(stderr);
}

void madeira_d3d12_note_unimplemented(const char *iface, const char *method) {
    /* Rate limiting is per call site rather than global: one chatty method must
     * not hide the first occurrence of every other one. */
    static const char *seen[64];
    static unsigned seen_n;
    for (unsigned i = 0; i < seen_n; i++)
        if (seen[i] == method) return;
    if (seen_n < 64) seen[seen_n++] = method;
    d3d12_log("[madeira-d3d12] unimplemented: %s::%s\n", iface, method);
}

/* ---- object model --------------------------------------------------------
 * One refcount and one interface id per object. QueryInterface accepts the
 * object's own iid plus the IUnknown/ID3D12Object/ID3D12DeviceChild ancestors
 * it genuinely is, and refuses everything else rather than handing back a
 * pointer whose vtable does not match what the caller will call through it. */
/* ml879 draw dump: the first executed lists are described draw by draw, with
 * the encoder index rmetald labels on its side, so a GPU fault report can be
 * matched to the draw that caused it. */
static char g_last_entry[64];
static struct mad_device *g_last_device;   /* ml887: GetDevice fallback for children without a back pointer */
static unsigned g_enc_seq, g_list_seq, g_dump_draws;
/* ml1070: RENDER-PASS CENSUS. The Metal HUD shows 27-40 ms of GPU time per frame
 * in the heavy benchmark scenes and 48-76 ms in the first cutscene, at 960x540.
 * On a tile-based GPU the cost that scales like that is pass boundaries: every
 * render encoder we end and restart LOADS and STORES every attachment (five
 * G-buffer targets plus depth). Count why encoders end, and estimate the
 * attachment traffic each pass boundary implies. */
static volatile LONG g_pass_begun, g_pass_end_rts, g_pass_end_clear, g_pass_end_dispatch, g_pass_end_blit, g_pass_end_list,
                     g_pass_end_attachless, g_pass_clear_only, g_pass_reused;
static volatile LONG64 g_pass_attach_bytes;
static int g_census_on;   /* ml899: one frame at presents 1500,1700,...,2800 */
/* ml1098: MANUAL FRAME CAPTURE. The UI asks (MadeiraCtl op 0); the next frame
 * has every render pass that drew something followed by a blit of each of its
 * attachments into a shared buffer, and at the following Present the buffers
 * are written to Documents/capture/ as raw files named by frame, encoder
 * sequence (matches the draw-dump enc#), attachment, size and format. The
 * draw-dump is forced on for the captured frame, so the log carries every draw
 * of every pass and the files carry what each pass left behind: "did the horse
 * vanish before its draw, in depth, in the G-buffer, or only in lighting" can
 * then be answered from a Mac (build/tools/capture-to-png.py). */
static int g_capture_on; static unsigned g_capture_left; static UINT64 g_capture_frame;
struct mad_capbuf { obj_handle_t buf; void *cpu; UINT64 bytes; UINT w, h, bpr, pf, dxgi; unsigned enc, idx; char kind[8]; char name[40]; };
static struct mad_capbuf *g_capbufs; static unsigned g_ncapbufs, g_capbufs_cap; static UINT64 g_cap_bytes;
#define MAD_CAPTURE_BUDGET (384ull << 20)
static int g_barrier_render = -1;   /* ml1098: madeira.cfg barrier-render = 1 closes render passes at barriers too */
static int g_occlusion_visible = -1;   /* ml1103: madeira.cfg occlusion-visible = 1 answers every occlusion query "fully visible" (diagnostic, Astra) */
/* ml1106: TARGETED DRAW CAPTURE. madeira.cfg capture-ps = <pixel shader entry>:
 * during a CAP frame, the first draws with that pixel shader get their inputs
 * captured BEFORE they run (vertex/index buffers, indirect arguments, every
 * texture the pixel stage samples) and their resolved argument tables logged
 * range by range. Answers "bad source or bad composite" for one draw. */
static char g_capture_ps[512]; static int g_capture_ps_loaded, g_capture_ps_shots, g_dump_tables;   /* ml1152: a comma list */
/* ml1141: TARGETED DISPATCH CAPTURE, the compute twin of the above. madeira.cfg
 * capture-cs = <compute entry name> (capture-cs-indirect = 1 keeps only indirect
 * dispatches, capture-cs-max = N, default 12): during a CAP frame the first N
 * matching dispatches get every root argument logged -- each table entry named
 * SRV / UAV / sampler, with the texture's size, format, mip count and the view's
 * mip range, or the buffer's size -- and their SRV textures (the view's most
 * detailed mip) and root CBVs captured BEFORE they run. UE5's Nanite shades
 * every material in compute, so this is how to see what a material samples. */
static char g_capture_cs[64]; static int g_capture_cs_shots, g_capture_cs_max = 12, g_capture_cs_ind;
static LONG g_barrier_renc_closed, g_stencil_srv, g_barrier_seen;
struct mad_obj {
    void *vtbl;
    LONG refs;
    const IID *iid;
    const char *name;
};

/* Declared ahead of the objects that reference them. */
struct mad_device;
struct mad_resource;
struct mad_pso;
#define MAD_MAX_COPIES 64
struct mad_copy {
    struct mad_resource *dst; UINT64 dst_off;
    struct mad_resource *src; UINT64 src_off;
    UINT64 len;
};

struct mad_device {
    ID3D12Device10Vtbl *vtbl;   /* ml877: full Device10 slot table, Device1..8 answered */
    LONG refs;
    const IID *iid;
    const char *name;
    obj_handle_t mtl_device;
    obj_handle_t mtl_queue;
    obj_handle_t dsso;          /* depth: less-equal, writes enabled */
    LONG device_lost;
    /* GPU addresses are resolved back to the resource that owns them rather
     * than dereferenced. The design is explicit that a D3D GPU address, a
     * descriptor handle and a backend object id are separate namespaces. */
    struct mad_resource **live;
    unsigned nlive, live_cap;
    /* ml1111: GPU-address index over the live BUFFERS, rebuilt lazily. Every
     * IASetVertexBuffers / IASetIndexBuffer / root-descriptor set resolved a
     * virtual address by walking the whole live list under the lock; with
     * ~2000 draws a frame that walk was the hottest code on the render thread
     * (ml981 profile: the entries of the two IA setters held 8-11 % of all
     * guest samples in the city). */
    struct mad_addr_entry { UINT64 lo, hi; struct mad_resource *r; unsigned seq; } *aidx;
    unsigned naidx, aidx_cap; int aidx_dirty; UINT64 aidx_maxsize; unsigned aidx_seq;   /* ml1113: maintained incrementally */
    CRITICAL_SECTION live_lock;
    volatile LONG64 aidx_ver;   /* ml1132: odd while a writer changes aidx; lets mad_resolve_address read it lock-free */
    obj_handle_t *samplers;      /* held for the process's life; see CreateSampler */
    unsigned nsamplers, samplers_cap;
    /* Guards samplers, srv_res and uav_res. D3D12 device methods are
     * free-threaded: Ghost of Tsushima's streaming threads create samplers and
     * views at the same time, and two unlocked reallocs of one array corrupted
     * the heap (a crash in mad_grow under mad_note_sampler). */
    SRWLOCK list_lock;
    /* Textures that have had a shader resource view created. A descriptor heap
     * stores resource IDs, not resource pointers, so the encoder cannot recover
     * from a bound table which textures it names. Declaring residency for all
     * of them is deliberately over-broad: over-declaring only keeps a resource
     * available, while under-declaring lets a draw sample nothing with every
     * call still reporting success. */
    struct mad_resource **srv_res;
    unsigned nsrv, nsrv_cap;
    struct mad_resource **uav_res;   /* written through descriptors; resident read+write */
    unsigned nuav, nuav_cap;
    /* ml880: one residency set on the queue holds every buffer and texture
     * ever created; committed before the next submission whenever it grew.
     * The 256-per-draw useResource lists stay as a belt for older systems. */
    obj_handle_t resset; LONG resset_dirty;
    /* Unset root descriptors used to hand the shader address 0 (+ offset),
     * which was a GPU page fault that killed the whole queue. They now point
     * at 64 KB of zeros instead. */
    obj_handle_t null_buffer; UINT64 null_gpu;
    struct mad_queue *queues[16]; unsigned nqueues;   /* ml884: every live queue, for flush-all */
    /* ml910: GPU-ordered capture of what a draw actually receives. Blits run
     * in the same command buffer right before the draw, so they see the
     * compute output the draw consumes; the shared buffer is read back after
     * the fence wait and printed then. */
    obj_handle_t cap_buf; unsigned char *cap_cpu; UINT cap_used;
    struct { char label[160]; UINT off, len; UINT kind; UINT nt; } cap[96]; unsigned ncap, cap_total;   /* ml924: nt>0 = sequential texels */
    /* ml1049: every view id -> what the sm5 tables need to know about it. The
     * old lookup walked the TEXTURE registries, which a buffer never enters, so
     * every typed-buffer binding failed and its draw or dispatch was skipped. */
    CRITICAL_SECTION view_lock;
    struct mad_viewrec { UINT64 id; UINT32 a, b; } *vmap; unsigned vmap_cap, vmap_used, vmap_live;
    /* ml1061: GPU timeline. Every committed batch signals `gpu_event` with its
     * serial, so "has the GPU finished X" is a read of one value instead of a
     * blocking wait. Fences are delivered by a worker thread; argument-ring
     * chunks are recycled only once the GPU has passed the batch that used them. */
    obj_handle_t gpu_event;
    volatile LONG64 gpu_serial;            /* last serial handed to a command buffer */
    volatile LONG64 gpu_serial_committed;  /* last serial actually committed */
    volatile LONG64 gpu_serial_failed;     /* ml1062: highest serial known to have died on the GPU */
    CRITICAL_SECTION ring_lock;
    struct mad_ringchunk { obj_handle_t buf; void *cpu; UINT64 gpu; UINT64 serial; } *ring_pool, *ring_retired;
    unsigned nring_pool, ring_pool_cap, nring_retired, ring_retired_cap;
    /* ml1088: OCCLUSION QUERIES on Metal visibility results. Batches that carry
     * query slots wait here, in commit order, until their command buffer retires. */
    CRITICAL_SECTION vis_lock;
    struct mad_vis_batch **vis_pending; unsigned nvis_pending, vis_pending_cap;
    LONG has_query_heaps;
    CRITICAL_SECTION vis_pub_lock;   /* ml1092: results are published in commit order, one retirer at a time */
    /* ml1091: ENCODER FENCE CHAIN. Metal tracks hazards only for resources an
     * encoder declares directly (attachments, blit operands, setBuffer/
     * setTexture, useResource). Everything this runtime reaches through
     * argument tables -- every sampled texture, every UAV, every vertex buffer
     * of the DXBC backend -- is undeclared once ml1060 stopped emitting the
     * useResource lists, and a residency set makes memory ACCESSIBLE, not
     * FINISHED (Astra, ph-rdr53 review). So a compute skin or a texture upload
     * could still be in flight when the draw that consumes it started: geometry
     * and textures flashing for a frame. One fence, updated at the end of every
     * encoder and waited on at the start of the next, orders all of them. */
    obj_handle_t enc_fence;
    LONG f5_nonrender;   /* ml1118: a compute/blit encoder ended since the last vertex-stage render wait */
    CRITICAL_SECTION fence_lock;
    struct mad_fence_job { UINT64 serial; ID3D12Fence *fence; UINT64 value; obj_handle_t cbs[16]; unsigned ncbs; } *fence_jobs;
    unsigned nfence_jobs, fence_jobs_cap;
    HANDLE fence_wake, fence_thread;
    volatile LONG fence_quit;   /* ml1064: device teardown stops the worker */
    volatile LONG queue_poisoned; LONG queues_recreated;   /* ml1067: driver is ignoring our submissions */
    /* ml1072: SMALL-TEXTURE SUB-ALLOCATOR. 12-15k sampled textures averaging ~22 KB
     * each were individual driver allocations (page-granular, plus per-allocation
     * metadata) -- the census showed ~560 MB of GPU memory above the resource
     * payload. Textures whose Metal size is at most MAD_HP_MAX_TEX are placed in
     * runtime-owned 64 MB placement heaps instead. The game's own heaps are NOT
     * backed (1,320 texture heaps totalling 1,985 MB for ~280 MB of textures). */
    CRITICAL_SECTION heap_lock;
    struct mad_texheap { obj_handle_t heap; UINT64 size; struct mad_hblk { UINT64 off, size; } *fl; unsigned nfl, fl_cap; } *theaps;
    unsigned ntheaps, theaps_cap;
    struct mad_hret { unsigned heap; UINT64 off, size, serial; } *hret; unsigned nhret, hret_cap;
    struct mad_mhret { obj_handle_t heap; UINT64 serial; void *mem; } *mhret; unsigned nmhret, mhret_cap;   /* ml1148: Metal heaps waiting for the GPU */
    struct { UINT32 value; obj_handle_t buf; } fillpat[8]; unsigned nfillpat; SRWLOCK fillpat_lock;   /* ml1151: exact UAV clear patterns */
    LONG64 hp_live_bytes, hp_total_bytes; LONG hp_textures, hp_fallbacks;
};
static LONG g_tview_live, g_tview_made, g_xview_live;   /* ml1126 */
static LONG g_resolve_locked, g_resolve_miss;   /* ml1132: address lookups that took live_lock */
static LONG g_res_added, g_res_removed, g_tess_psos, g_tess_draws, g_tess_built, g_tess_drawn, g_tess_nonidx;
static LONG g_gs_built, g_gs_drawn;   /* ml1147 */
static LONG g_vis_begun, g_vis_resolved, g_vis_nonzero, g_vis_restarts;   /* ml1088 */
static LONG g_srv_clamped; static float g_srv_clamp_max;   /* ml1089 */
static LONG g_zero_inst;   /* ml1094 */
static LONG g_fence_waits, g_fence_updates, g_barriers;   /* ml1091 */
static LONG g_f6_begins, g_f6_synced, g_f6_att_sync, g_f6_kept_open, g_f6_joins, g_f6_rclose;   /* ml1134 */
/* ml1137: GPU census, counts only. Barrier entries by the states they move
 * between, and what a state-aware wait rule would have needed at each
 * barrier-caused sync of mode 6; attachment bytes loaded / cleared / stored in
 * 1 of 16 frames, with what happens NEXT to each stored attachment in its list. */
enum { BC_RAR, BC_RAW_ATT, BC_RAW_COPY, BC_RAW_UAV, BC_ALL, BC_NONE = 255 };
static LONG g_bc_ent[5], g_f7_bsync, g_f7_none, g_f7_subset, g_f7_all;
static LONG64 g_f7_fw6, g_f7_fwr;
static LONG64 g_ac_load, g_ac_clear, g_ac_store, g_ac_st_cleared, g_ac_st_read, g_ac_st_rebound, g_ac_st_write, g_ac_st_none;
static LONG g_ac_frames, g_discards;
static volatile LONG g_att_census;   /* ml1083: built pipelines, draws that RAN, non-indexed ones */
/* ml1057: what our GPU allocations ARE. The process dies at 8.19 GB with ~2.6 GB
 * of IOAccelerator memory against a 1.5 GB advertised budget, and nothing said
 * which kind of resource holds it. Estimated bytes, live and peak, by kind. */
enum { MAD_CAT_TEX_RT, MAD_CAT_TEX_DS, MAD_CAT_TEX_UAV, MAD_CAT_TEX_PLAIN, MAD_CAT_TEX_MSAA,
       MAD_CAT_BUF_PRIVATE, MAD_CAT_BUF_SHARED, MAD_CAT_N };
static const char *const g_cat_name[MAD_CAT_N] = { "tex-RT", "tex-DS", "tex-UAV", "tex-sampled", "tex-MSAA", "buf-private", "buf-shared" };
static volatile LONG64 g_cat_bytes[MAD_CAT_N], g_cat_peak[MAD_CAT_N];
static volatile LONG g_cat_count[MAD_CAT_N];
static volatile LONG64 g_upload_swap_bytes; static volatile LONG g_upload_swap_n;   /* ml1154 */
static int mad_upload_swap_on(void);
static volatile LONG64 g_lib_bytes; static volatile LONG g_lib_count;   /* ml1060: metallib bytes handed to newLibrary */
static void mad_acct(struct mad_resource *r, unsigned cat, UINT64 bytes, int sign);
static void mad_acct_report(void);
static void mad_resident(struct mad_device *d, obj_handle_t h) {
    if (!d || !h || !d->resset) return;
    MTLResidencySet_addAllocation(d->resset, h);
    InterlockedIncrement(&g_res_added);
    InterlockedExchange(&d->resset_dirty, 1);
}
/* ml1050: the set retains its members and nothing ever left it, so every
 * resource and view the application destroyed stayed allocated: GPU memory
 * climbed ~1.3 GB through a benchmark against a 1.5 GB advertised budget.
 * Removal is staged and lands with the next commit, which already precedes
 * the next command buffer. */
static void mad_unresident(struct mad_device *d, obj_handle_t h) {
    if (!d || !h || !d->resset) return;
    MTLResidencySet_removeAllocation(d->resset, h);
    InterlockedIncrement(&g_res_removed);
    InterlockedExchange(&d->resset_dirty, 1);
}

/* Growable arrays. The fixed tables of the cube era (16 samplers, 16 views,
 * 64 resources, 16 descriptors per heap) were sized for one demo; an engine
 * creates thousands of each during its first second, and the 16-descriptor
 * heap limit surfaced as an "out of video memory" dialog. */
static int mad_grow(void **arr, unsigned *cap, unsigned need, size_t elem) {
    unsigned ncap;
    void *n;
    if (need <= *cap) return 1;
    ncap = *cap ? *cap * 2 : 64;
    while (ncap < need) ncap *= 2;
    n = realloc(*arr, (size_t)ncap * elem);
    if (!n) return 0;
    *arr = n; *cap = ncap;
    return 1;
}

/* ml1049: view-id map. Open addressing; id 0 = empty, ~0 = tombstone.
 * a/b: typed buffer = element count / first element; texture view = slices / 0. */
#define MAD_VREC_TOMB (~(UINT64)0)
static unsigned mad_vmap_slot(UINT64 id, unsigned cap) { return (unsigned)((id * 0x9E3779B97F4A7C15ull) >> 40) & (cap - 1); }
static void mad_vmap_put_locked(struct mad_device *d, UINT64 id, UINT32 a, UINT32 b) {
    unsigned i;
    if (!id || id == MAD_VREC_TOMB) return;
    if (!d->vmap_cap || (d->vmap_used + 1) * 10 > d->vmap_cap * 6) {
        unsigned ncap = d->vmap_cap ? d->vmap_cap : 1024, k;
        struct mad_viewrec *n;
        while ((d->vmap_live + 1) * 10 > ncap * 3) ncap *= 2;
        n = calloc(ncap, sizeof *n);
        if (!n) return;
        for (k = 0; k < d->vmap_cap; k++) {
            if (!d->vmap[k].id || d->vmap[k].id == MAD_VREC_TOMB) continue;
            i = mad_vmap_slot(d->vmap[k].id, ncap);
            while (n[i].id) i = (i + 1) & (ncap - 1);
            n[i] = d->vmap[k];
        }
        free(d->vmap); d->vmap = n; d->vmap_cap = ncap; d->vmap_used = d->vmap_live;
    }
    i = mad_vmap_slot(id, d->vmap_cap);
    while (d->vmap[i].id && d->vmap[i].id != id) i = (i + 1) & (d->vmap_cap - 1);
    if (!d->vmap[i].id) { d->vmap_used++; d->vmap_live++; }
    d->vmap[i].id = id; d->vmap[i].a = a; d->vmap[i].b = b;
}
static void mad_vmap_del_locked(struct mad_device *d, UINT64 id) {
    unsigned i;
    if (!d->vmap_cap || !id || id == MAD_VREC_TOMB) return;
    i = mad_vmap_slot(id, d->vmap_cap);
    while (d->vmap[i].id) {
        if (d->vmap[i].id == id) { d->vmap[i].id = MAD_VREC_TOMB; d->vmap_live--; return; }
        i = (i + 1) & (d->vmap_cap - 1);
    }
}
static int mad_vmap_get(struct mad_device *d, UINT64 id, UINT32 *a, UINT32 *b) {
    int hit = 0; unsigned i;
    if (!id || id == MAD_VREC_TOMB) return 0;
    EnterCriticalSection(&d->view_lock);
    if (d->vmap_cap) {
        i = mad_vmap_slot(id, d->vmap_cap);
        while (d->vmap[i].id) {
            if (d->vmap[i].id == id) { *a = d->vmap[i].a; *b = d->vmap[i].b; hit = 1; break; }
            i = (i + 1) & (d->vmap_cap - 1);
        }
    }
    LeaveCriticalSection(&d->view_lock);
    return hit;
}
/* Grow a per-resource view array WITHOUT freeing the old block: a replay thread
 * may still be indexing it. Old blocks are freed with the resource. Caller holds
 * view_lock. Doubling from 16 means 24 old blocks is past any possible count. */
static int mad_view_grow(struct mad_resource *r, void **arr, unsigned *cap, unsigned need, size_t elem);

/* ml1049: WHY work was skipped, counted for the whole run. The per-message
 * budgets (32 lines) were spent in the menu, so a benchmark that skipped
 * hundreds of operations per second said nothing about which kind. */
static struct { const char *why; LONG n; } g_skip_why[32];
static struct { LONG line; LONG n; } g_skip_line[48];
static void mad_skip_why(const char *why) {
    unsigned i;
    for (i = 0; i < 32; i++) {
        if (g_skip_why[i].why == why) { InterlockedIncrement(&g_skip_why[i].n); return; }
        if (!g_skip_why[i].why) {
            if (!InterlockedCompareExchangePointer((void *volatile *)&g_skip_why[i].why, (void *)why, NULL) ||
                g_skip_why[i].why == why) { InterlockedIncrement(&g_skip_why[i].n); return; }
        }
    }
}
static void mad_skip_at(LONG line) {
    unsigned i;
    for (i = 0; i < 48; i++) {
        if (g_skip_line[i].line == line) { InterlockedIncrement(&g_skip_line[i].n); return; }
        if (!g_skip_line[i].line) {
            if (!InterlockedCompareExchange(&g_skip_line[i].line, line, 0) || g_skip_line[i].line == line) {
                InterlockedIncrement(&g_skip_line[i].n); return; }
        }
    }
}
static LONG g_cb_errors, g_cb_retired, g_null_cbv_bound, g_vis_fallback;
/* ml1109: sync census -- what the game does per frame and how long it waits for us */
static LONGLONG g_perf_ecl_ticks, g_perf_present_ticks;   /* ml1119 */
static int g_async_submit;   /* ml1120: defined with the worker below */
static LONGLONG g_perf_worker_ticks, g_perf_drain_ticks, g_perf_resetwait_ticks, g_perf_waitjob_ticks; static LONG g_perf_resetwaits, g_perf_jobs;   /* ml1120 */
/* ml1128: TRANSITION PROBE (measurement only). Cumulative QPC ticks / counts,
 * published once to the unix side (MadeiraCtl op 5), which samples them every
 * 250 ms next to per-thread P/E-core CPU counters. The layout is mirrored in
 * server_ios.c (ios_xp_pe); append fields only. */
static struct mad_xp {
    LONG64 magic, qpf;
    LONG64 pres_enq, pres_done, t_thr;                   /* caller Present enqueues; worker Presents done; caller run-ahead wait */
    LONG64 n_ecl, t_ecl, n_sig, t_sig, n_wait, t_wait, t_prs;   /* worker jobs by kind (elapsed) */
    LONG64 t_flush, n_lat, t_lat, t_draw, t_cmt;         /* inside Present: flush, frame-latency GPU wait, nextDrawable, blit+present+commit */
    LONG64 t_pool;                                       /* worker autorelease pool drain */
    LONG64 ecl_calls, t_ecl_caller;                      /* caller side */
} g_xp;
static void mad_xp_role(char role) {   /* tell the probe which thread this is (unix side records its thread id) */
    static DWORD seen[32]; static LONG nseen;
    DWORD me = GetCurrentThreadId(), key = me ^ ((DWORD)(unsigned char)role << 24); LONG i, n = nseen;
    struct madeira_ctl_args a;
    for (i = 0; i < n && i < 32; i++) if (seen[i] == key) return;
    if (n < 32) { seen[n] = key; InterlockedIncrement(&nseen); }
    if (!g_xp.magic) {
        LARGE_INTEGER f; QueryPerformanceFrequency(&f);
        g_xp.qpf = f.QuadPart; g_xp.magic = 0x3130305058444d4dLL;
        memset(&a, 0, sizeof a); a.op = 5; a.ptr = (UINT64)(ULONG_PTR)&g_xp; a.len = sizeof g_xp; MadeiraCtl(&a);
    }
    memset(&a, 0, sizeof a); a.op = 4; a.len = (UINT64)(unsigned char)role; a.ptr = me; MadeiraCtl(&a);
}
static LONG64 mad_qpc(void) { LARGE_INTEGER t; QueryPerformanceCounter(&t); return t.QuadPart; }
static LONG g_perf_ecl, g_perf_signals, g_perf_waits, g_perf_polls, g_perf_qwait_sleeps; static LONGLONG g_perf_wait_ticks, g_perf_sig_lat_ticks; static LONG g_perf_sig_lat_n;
#define MAD_SKIP(e_) (mad_skip_at(__LINE__), (e_)->skipped++)
static void mad_skip_report(void) {
    char buf[1400]; int n = 0; unsigned i;
    for (i = 0; i < 48 && g_skip_line[i].line; i++)
        n += snprintf(buf + n, sizeof buf - n, " L%ld=%ld", g_skip_line[i].line, g_skip_line[i].n);
    d3d12_log("[madeira-d3d12] ml1049 skips by site (cumulative):%s\n", n ? buf : " none");
    for (i = 0; i < 32 && g_skip_why[i].why; i++)
        d3d12_log("[madeira-d3d12] ml1049 bind failure x%ld: %s\n", g_skip_why[i].n, g_skip_why[i].why);
    d3d12_log("[madeira-d3d12] ml1049 command buffers: %ld retired, %ld ENDED IN ERROR; null CBVs bound to zeros %ld; "
              "visibility fallbacks %ld\n", g_cb_retired, g_cb_errors, g_null_cbv_bound, g_vis_fallback);
    d3d12_log("[madeira-d3d12] ml1088 occlusion queries: %ld begun, %ld results delivered, %ld queries counted samples > 0, %ld pass restarts; "
              "ml1089 SRVs with a min-LOD clamp folded into the view: %ld (largest clamp %.1f)\n",
              g_vis_begun, g_vis_resolved, g_vis_nonzero, g_vis_restarts, g_srv_clamped, (double)g_srv_clamp_max);
    d3d12_log("[madeira-d3d12] ml1091 encoder fence chain: %ld waits, %ld updates; %ld ResourceBarrier calls recorded (%ld closed a render pass); ml1094 zero-instance draws elided %ld; ml1101 stencil SRVs %ld\n",
              g_fence_waits, g_fence_updates, g_barriers, g_barrier_renc_closed, g_zero_inst, g_stencil_srv);
    mad_acct_report();
    d3d12_log("[madeira-d3d12] ml1050 residency set: %ld added, %ld removed (%ld members); tessellation: %ld pipelines (%ld built as mesh pipelines), "
              "%ld draws dropped, %ld drawn (%ld non-indexed); ml1147 DXBC geometry: %ld mesh pipelines, %ld draws\n", g_res_added, g_res_removed, g_res_added - g_res_removed, g_tess_psos, g_tess_built,
              g_tess_draws, g_tess_drawn, g_tess_nonidx, g_gs_built, g_gs_drawn);   /* ml1083, ml1147 */
    d3d12_log("[madeira-d3d12] ml1126 views: %ld typed-buffer views live (%ld made; kept OUT of the residency set, their buffer is in it), %ld texture views live\n",
              g_tview_live, g_tview_made, g_xview_live);
    d3d12_log("[madeira-d3d12] ml1132 address lookups on the locked path: %ld (true misses %ld); every other lookup was lock-free\n",
              g_resolve_locked, g_resolve_miss);
}

static void mad_log_nserror(const char *what, obj_handle_t err);
static void mad_queue_revive(struct mad_device *d);
struct mad_list; struct mad_queue;
static void mad_list_rings_rewind(struct mad_list *l);
static struct mad_device *g_hp_dev;   /* ml1072: the device whose heaps the report describes */
static void mad_acct_report(void) {
    char line[700]; int n = 0; unsigned c; LONG64 tot = 0;
    for (c = 0; c < MAD_CAT_N; c++) {
        tot += g_cat_bytes[c];
        n += snprintf(line + n, sizeof line - n, " %s=%lldMB/%ld (peak %lld)", g_cat_name[c],
                      (long long)(g_cat_bytes[c] >> 20), g_cat_count[c], (long long)(g_cat_peak[c] >> 20));
    }
    d3d12_log("[madeira-d3d12] ml1057 live GPU backing (estimated) total=%lldMB:%s\n", (long long)(tot >> 20), line);
    d3d12_log("[madeira-d3d12] ml1154 CPU-visible buffers on file-backed storage: %ld, %lld MB\n", g_upload_swap_n, (long long)(g_upload_swap_bytes >> 20));
    if (g_hp_dev) d3d12_log("[madeira-d3d12] ml1072 texture heaps: %u (%lld MB reserved, %lld MB live in them), %ld textures placed, %ld fallbacks, %u blocks awaiting GPU\n",
                            g_hp_dev->ntheaps, (long long)(g_hp_dev->hp_total_bytes >> 20), (long long)(g_hp_dev->hp_live_bytes >> 20),
                            g_hp_dev->hp_textures, g_hp_dev->hp_fallbacks, g_hp_dev->nhret);
    d3d12_log("[madeira-d3d12] ml1060 shader libraries created: %ld, %lld MB of metallib (one per pipeline STAGE, never shared "
              "between pipelines)\n", g_lib_count, (long long)(g_lib_bytes >> 20));
}
static void mad_note_sampler(struct mad_device *d, obj_handle_t smp) {
    int kept = 0;
    if (!d || !smp) return;
    AcquireSRWLockExclusive(&d->list_lock);
    if (mad_grow((void **)&d->samplers, &d->samplers_cap, d->nsamplers + 1, sizeof *d->samplers)) {
        d->samplers[d->nsamplers++] = smp; kept = 1;
    }
    ReleaseSRWLockExclusive(&d->list_lock);
    if (!kept) NSObject_release(smp);
}

/* ---- resources ----------------------------------------------------------
 * Buffers only for now. The CPU-visible heaps get storage allocated here and
 * handed to the backend as the buffer's memory, which is the same arrangement
 * DXMT's ring allocator uses and the one the remote shadow machinery already
 * understands. DEFAULT is GPU-private and deliberately not mappable. */
struct mad_memheap;
struct mad_resource {
    ID3D12Resource2Vtbl *vtbl;   /* ml886: Resource2-sized slot table */
    LONG refs;
    const IID *iid;
    const char *name;
    struct mad_memheap *placed_heap;   /* ml1145: set when the storage IS the heap's, at the placement offset */
    void *own_mem;                     /* ml1154: our VirtualAlloc'd storage behind a CPU-visible buffer */
    unsigned track_seq;                /* ml1157: creation order in the address index (newest alias wins) */
    obj_handle_t buffer;
    void *cpu;                 /* NULL for GPU-private */
    UINT64 size;
    D3D12_HEAP_TYPE heap;
    UINT64 gpu_address;        /* reported by the backend at creation */
    LONG mapped;
    obj_handle_t texture;      /* set instead of `buffer` for TEXTURE2D */
    UINT64 gpu_resource_id;    /* what a descriptor entry stores for a texture */
    UINT32 width, height;
    int is_depth;
    int has_stencil;
    UINT samples;
    struct mad_device *owner;
    int borrowed;              /* texture belongs to a drawable; do not release */
    obj_handle_t resolve_tmp;  /* exec_resolve: render-target stand-in when this is a resolve destination without that usage */
    UINT resolve_tmp_w, resolve_tmp_h, resolve_tmp_pf;   /* the stand-in's size and pixel format, to replace it when they change */
    D3D12_RESOURCE_DESC desc;  /* as created; answered by GetDesc */
    /* ml905: typed-buffer views (Buffer<T> / RWBuffer<T>). The converter reads
     * a typed buffer as a texture buffer, so each distinct (format, offset,
     * count, access) needs a texture view over the buffer's memory. Cached per
     * resource; released with it. */
    /* ml1049: growable, never evicted. The 16-entry ring released a Metal view
     * that descriptors still named as soon as a 17th distinct view appeared. */
    struct mad_tview { UINT fmt; UINT64 off, num; UINT8 uav; obj_handle_t tex; UINT64 id; } *tview;
    unsigned ntview, tview_cap;
    void *view_old[24]; unsigned nview_old;   /* outgrown arrays, freed with the resource */
    unsigned srv_slot, uav_slot;              /* index + 1 in the device's srv_res / uav_res, 0 = absent (list_lock) */
    UINT64 acct_bytes; unsigned acct_cat;        /* ml1057: live-backing census */
    int hp_used; unsigned hp_heap; UINT64 hp_off, hp_size;   /* ml1072: placed in a runtime texture heap */
    /* ml913: dimension-correct texture views. Metal binds a texture only to a
     * shader slot of the SAME type: a Texture2DArray SRV over a texture we
     * created as 2D (one layer) read back nothing (host shader validation:
     * "Invalid texture type MTLTextureType2D bound to shader, expected
     * MTLTextureType2DArray", 6520 reports in one run). Views are cached per
     * (type, levels, slices). */
    enum WMTTextureType tex_type; enum WMTPixelFormat tex_pf; UINT tex_mips, tex_layers; UINT tex_depth;   /* ml924: 3D depth */
    struct mad_xview { UINT type, lvl0, nlvl, sl0, nsl, pf, swz; obj_handle_t tex; UINT64 id; } *xview;
    unsigned nxview, xview_cap;
};
/* srv_res / uav_res membership, O(1) through the resource's slot (the linear
 * scan it replaces ran over ~15,000 textures on every view creation). */
static void mad_view_list_add(struct mad_device *d, int uav, struct mad_resource *r) {
    struct mad_resource ***arr = uav ? &d->uav_res : &d->srv_res;
    unsigned *n = uav ? &d->nuav : &d->nsrv, *cap = uav ? &d->nuav_cap : &d->nsrv_cap;
    unsigned *slot = uav ? &r->uav_slot : &r->srv_slot;
    if (*slot) return;   /* unlocked peek: the common case, already listed */
    AcquireSRWLockExclusive(&d->list_lock);
    if (!*slot && mad_grow((void **)arr, cap, *n + 1, sizeof **arr)) {
        (*arr)[*n] = r; *slot = ++*n;
    }
    ReleaseSRWLockExclusive(&d->list_lock);
}
/* list_lock held exclusively */
static void mad_view_list_del(struct mad_device *d, int uav, struct mad_resource *r) {
    struct mad_resource **arr = uav ? d->uav_res : d->srv_res;
    unsigned *n = uav ? &d->nuav : &d->nsrv;
    unsigned *slot = uav ? &r->uav_slot : &r->srv_slot;
    unsigned i = *slot - 1;
    struct mad_resource *last = arr[--*n];
    arr[i] = last;
    if (uav) last->uav_slot = i + 1; else last->srv_slot = i + 1;
    *slot = 0;
}

DEFINE_GUID(IID_IMTLDXGIDevice, 0x6bfa1657, 0x9cb1, 0x471a, 0xa4, 0xfb, 0x7c, 0xac, 0xf8, 0xa8, 0x12, 0x07);

#define MAD_ROOT_PARAM_MAX 32
#define MAD_ROOT_RANGE_MAX 32        /* ml1009: the OLD fixed cap; now only a log reference */
#define MAD_ROOT_RANGE_SANE 8192     /* ml1009: refuse-a-corrupt-blob bound, not a capability limit */
/* The parsed root signature, not the blob. The converter needs the layout at
 * pipeline creation, and re-parsing the blob there would mean keeping the
 * application's memory alive for the object's whole life. */
struct mad_rootsig {
    ID3D12RootSignatureVtbl *vtbl; LONG refs; const IID *iid; const char *name;
    struct madeira_ir_root_param params[MAD_ROOT_PARAM_MAX];
    /* ml1009: sized to the blob, allocated in the SAME block as this object so
     * the one free() in mad_release still releases everything.
     *
     * This was a fixed [32] array, and a root signature needing more was
     * refused with E_NOTIMPL. That cost 5,435 refusals in one run -- RDR2's
     * real root signatures routinely exceed 32 descriptor ranges, and every
     * refusal takes a pipeline with it, which is why nothing drew. D3D12 puts
     * no small bound on the range count (the 64-DWORD budget bounds root
     * ARGUMENTS, and a descriptor table costs one DWORD however many ranges it
     * names), so a bigger fixed guess would only move the wall. */
    struct madeira_ir_root_range *ranges;
    UINT nparams, nranges;
    struct madeira_ir_static_sampler samplers[32];
    UINT nsamplers;
    /* ml923: the converter reserves one implicit descriptor-table slot at the
     * end of the top-level argument buffer for the static samplers; this is
     * the table it points at (nsamplers sampler descriptors, built once). */
    obj_handle_t stab; UINT64 stab_gpu;
};
struct mad_pso {
    ID3D12PipelineStateVtbl *vtbl; LONG refs; const IID *iid; const char *name;
    obj_handle_t rps;          /* Metal render pipeline state */
    obj_handle_t vs_lib, ps_lib, vs_fn, ps_fn;
    int uses_depth, uses_stencil;
    UINT8 dbg_denable, dbg_dfunc, dbg_dwrite, dbg_wmask[8], dbg_senable, dbg_sfunc, dbg_srmask, dbg_swmask;   /* ml903/ml904: census only */
    obj_handle_t dsso;                              /* per-pipeline depth-stencil state */
    struct wmtcmd_render_setrasterizerstate raster;  /* applied at every draw */
    UINT vb_stride[16]; UINT vb_mask;               /* the strides the vertex descriptor assumed */
    /* ml878: a D3D12 pipeline carries no vertex strides (they arrive with the
     * buffer view at draw time) but a Metal vertex descriptor must. The base
     * pipeline assumes the tightest stride; when a draw binds a different one
     * the pipeline is rebuilt with the real strides and cached here. */
    struct WMTRenderPipelineInfo rp; struct WMTVertexDescriptorInfo vd; int has_vd;
    struct { UINT strides[16]; obj_handle_t rps; } var[8]; unsigned nvar;
    CRITICAL_SECTION var_lock;
    obj_handle_t device_handle;
    char vs_name[64], ps_name[64];                  /* ml879: for the draw dump */
    char blend[400];                                /* ml1106/ml1107: every RT's blend state for the draw dump */
    UINT root_off[MAD_ROOT_PARAM_MAX]; int has_root_off; /* ml882: offsets from the converter's reflection */
    UINT static_off; int has_static_off;                  /* ml923: the implicit static-sampler table slot */
    int gs_emu;                                     /* ml927: a geometry-shader pipeline through the converter's mesh emulation */
    obj_handle_t si_lib, gs_lib;                    /* stage-in library, geometry (mesh) library */
    UINT gs_vertex_size, gs_max_prims;              /* IRRuntimeGeometryPipelineConfig */
    char gs_name[64];                               /* the converter's name for the mesh (geometry) function */
    int is_compute;
    int has_tess;   /* ml1050: carries HS/DS, which this runtime cannot run yet */
    obj_handle_t cps;                               /* Metal compute pipeline state */
    UINT tg[3];                                     /* threadgroup size the kernel was compiled with */
    /* ml1008: which compiler produced this pipeline's shaders, and the argument
     * table shape when it was the DXBC one. Recorded per pipeline and never
     * inferred: the two backends bind through completely different layouts, so
     * reading one's tables with the other's rules binds garbage. */
    UINT backend;                                   /* madeira_ir_backend */
    UINT cb_bind, arg_bind;                         /* Metal buffer indices, ~0u = no such table */
    UINT arg_qwords;                                /* argument table size in 64-bit words */
    UINT nair;
    /* ml1010: sized to the shader, not to MADEIRA_IR_AIR_RANGE_MAX. Embedding
     * the whole 256-entry array would cost 8 KB on EVERY pipeline, and this run
     * created thousands -- the same fixed-array waste ml1009 removed from root
     * signatures. pso_Release is already a custom destructor, so a separate
     * allocation is freed there. */
    struct madeira_ir_air_range *air;
    /* ml1011: the FRAGMENT stage's own tables. Metal gives every stage its own
     * buffer binding table, so vertex and fragment each get a constant-buffer
     * and an argument table at the same indices but through different setters.
     * The compute path reuses the fields above. */
    UINT air_slot_mask;                             /* ml1011: the mask its vertex fetch was built for */
    UINT ps_cb_bind, ps_arg_bind, ps_arg_qwords, ps_nair;
    struct madeira_ir_air_range *ps_air;
    struct mad_tess *tess;                          /* ml1083: hull/domain as an object/mesh pipeline, NULL if not built */
    struct mad_tess *tess_strip;                    /* ml1147b: a DXBC geometry pipeline's STRIP-topology variant */
};

/* ml1083: TESSELLATION.
 *
 * A pipeline with hull and domain shaders runs as a Metal mesh pipeline, the
 * way DXMT's D3D11 layer runs it: the object function is the vertex and hull
 * shaders fused (one object threadgroup = threads_per_patch x patches_per_group
 * control-point threads), the mesh function is the domain shader, and the
 * tessellator itself is emulated inside them. Every table the three D3D stages
 * bind is a separate Metal buffer: vertex 27/28 and hull 29/30 on the object
 * stage, domain 29/30 on the mesh stage. The object function also takes the
 * vertex-buffer table (16), the draw arguments (21) and, when indexed, the index
 * buffer (20). It is SPECIALISED on the index format, so one is compiled per
 * format the application draws with (the D3D11 layer does exactly this). */
struct mad_tess_stage { UINT cb_bind, arg_bind, arg_qwords, nair; struct madeira_ir_air_range *air; };
struct mad_tess {
    struct { obj_handle_t lib, fn, rps; struct mad_tess_stage vs, hs; UINT slot_mask; } obj[3];   /* [index format] */
    obj_handle_t ds_lib, ds_fn; struct mad_tess_stage ds;
    UINT threads_per_patch, max_potential, out_prim;
    char obj_name[64], ds_name[64];
    int is_gs;   /* ml1147: a DXBC geometry pipeline: object = VS for the GS (29/30), mesh = GS (29/30); no hull */
};

/* ml1008: what the DXBC backend reports back about one stage. */
struct mad_air_out {
    UINT backend, cb_bind, arg_bind, arg_qwords, nranges, slot_mask;
    struct madeira_ir_air_range ranges[MADEIRA_IR_AIR_RANGE_MAX];
};

/* One shader-visible descriptor, in the converter's layout.
 *
 * Written out here rather than included: this file must not depend on the
 * converter's headers, and the three fields are the whole contract. Taken from
 * IRDescriptorTableEntry and its Set* helpers in the converter's runtime
 * header, which is also where the encodings below come from. */
struct mad_rtvp { UINT16 level, slice, layers, plane; };
struct mad_rtv { struct mad_resource *res; struct mad_rtvp p; };
struct mad_descriptor {
    UINT64 gpu_va;          /* sampler resource id, or a buffer address */
    UINT64 texture_view_id; /* texture resource id */
    UINT64 metadata;        /* min LOD clamp, or an encoded LOD bias */
};

static enum WMTCompareFunction mad_compare(D3D12_COMPARISON_FUNC f);
static void mad_sampler_info(struct WMTSamplerInfo *si, UINT filter, UINT au, UINT av, UINT aw, UINT aniso, UINT cmp, UINT border, float minlod, float maxlod);

/* RTV and DSV heaps hold resource pointers and never reach the GPU; the other
 * two hold real descriptors in a Metal buffer the shader reads. Both kinds hand
 * out CPU handles that are simply the address of the slot, so the application's
 * own `start + index * increment` arithmetic lands in the right place without
 * the runtime having to recover which heap a handle came from. */
struct mad_heap {
    ID3D12DescriptorHeapVtbl *vtbl; LONG refs; const IID *iid; const char *name;
    D3D12_DESCRIPTOR_HEAP_TYPE type;
    struct mad_rtv *slots;                      /* RTV/DSV: resource + sub-view per descriptor (ml925) */
    int shader_visible;
    obj_handle_t buffer;                        /* CBV_SRV_UAV/SAMPLER */
    struct mad_descriptor *cpu;
    UINT64 gpu_address;
    UINT count;
    struct mad_device *owner;
    D3D12_DESCRIPTOR_HEAP_DESC desc;           /* as created; answered by GetDesc */
};

/* An RTV or DSV handle addresses one slot in a heap's resource-pointer array. */
/* ml925: a render-target / depth-stencil view. The resource pointer comes
 * first so every reader of the old pointer-only slot still works. level =
 * mip, slice = first array slice (arrays, cubes), plane = first W slice (3D),
 * layers = how many slices the view spans: >1 means layered rendering and the
 * pass gets a renderTargetArrayLength, without which every layer the vertex
 * shader selects lands in (or is clipped from) slice 0. That is how UE's
 * 32-slice colour-grading LUT ended up with only slice 0 written. */
static unsigned mad_table_count(const struct mad_rootsig *rs, unsigned i, unsigned cap);   /* ml930 */
static struct mad_resource *mad_slot_resource(SIZE_T handle) {
    return handle ? *(struct mad_resource **)handle : NULL;
}
static void mad_view_all(struct mad_resource *r, struct mad_rtvp *p, UINT first, UINT count, int is3d);
static struct mad_rtvp mad_slot_view(SIZE_T handle) {
    struct mad_rtvp z = { 0, 0, 1, 0 };
    return handle ? ((struct mad_rtv *)handle)->p : z;
}

/* The increment the application uses for handle arithmetic. It has to be the
 * real stride or every descriptor after the first lands in the wrong place. */
static UINT mad_descriptor_stride(D3D12_DESCRIPTOR_HEAP_TYPE t) {
    return (t == D3D12_DESCRIPTOR_HEAP_TYPE_RTV || t == D3D12_DESCRIPTOR_HEAP_TYPE_DSV)
         ? (UINT)sizeof(struct mad_rtv)
         : (UINT)sizeof(struct mad_descriptor);
}

#ifndef DXGI_ERROR_DEVICE_REMOVED
#define DXGI_ERROR_DEVICE_REMOVED ((HRESULT)0x887A0005)
#endif

/* A dead transport used to surface as E_OUTOFMEMORY from every creation call,
 * because a failed backend call returns a null handle and "null handle" was read
 * as "allocation failed". That sent us looking for a memory problem when the
 * daemon had aborted. Probe the device and say which it is. */
static void mad_track(struct mad_device *d, struct mad_resource *r);
static void mad_untrack(struct mad_device *d, struct mad_resource *r);
static void mad_format_info(DXGI_FORMAT f, UINT *bytes, UINT *block);
static UINT64 mad_res_row_bytes(const struct mad_resource *r);
static int mad_map_texture_format(DXGI_FORMAT f, D3D12_RESOURCE_FLAGS flags, enum WMTPixelFormat *out, int *is_depth);
static int mad_texinfo_from_desc(const D3D12_RESOURCE_DESC *desc, struct WMTTextureInfo *ti, enum WMTPixelFormat *pf, int *is_depth);   /* ml1145 */
struct mad_device;
static void mad_mheap_reclaim(struct mad_device *d, int all);   /* ml1148 */
struct mad_rootsig;
static UINT mad_root_layout(const struct mad_rootsig *rs, UINT offsets[32]);

static HRESULT mad_creation_failure(struct mad_device *d, const char *what) {
    if (d && !d->device_lost && MTLDevice_recommendedMaxWorkingSetSize(d->mtl_device) == 0) {
        InterlockedExchange(&d->device_lost, 1);
        d3d12_log("[madeira-d3d12] %s failed AND the device no longer answers -- "
                  "treating this as device removal, not an allocation failure\n", what);
    }
    if (d && d->device_lost) return DXGI_ERROR_DEVICE_REMOVED;
    d3d12_log("[madeira-d3d12] %s failed while the device is still responding\n", what);
    return E_OUTOFMEMORY;
}

static HRESULT mad_qi(struct mad_obj *o, REFIID riid, void **out, int is_device_child) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, o->iid) ||
        IsEqualGUID(riid, &IID_ID3D12Object) ||
        (is_device_child && IsEqualGUID(riid, &IID_ID3D12DeviceChild))) {
        InterlockedIncrement(&o->refs);
        *out = o;
        return S_OK;
    }
    /* ml888: a refused interface on ANY object is named. The ID3D12Resource1
     * refusal that nulled the engine's RHI resource was invisible because only
     * the device logged its refusals. */
    {
        static unsigned said;
        if (riid && said++ < 24)
            d3d12_log("[madeira-d3d12] %s QueryInterface refused: {%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}\n",
                      o->name ? o->name : "?", (unsigned long)riid->Data1, riid->Data2, riid->Data3, riid->Data4[0], riid->Data4[1],
                      riid->Data4[2], riid->Data4[3], riid->Data4[4], riid->Data4[5], riid->Data4[6], riid->Data4[7]);
    }
    return E_NOINTERFACE;
}

static ULONG mad_addref(struct mad_obj *o) { return (ULONG)InterlockedIncrement(&o->refs); }

/* ml1143: PRIVATE DATA IS STORED. SetPrivateData used to answer S_OK and keep
 * nothing, and GetPrivateData always said NOT_FOUND. D3DX12's residency manager
 * (UE's D3D12 RHI submits through it) keeps its per-queue fence in the queue's
 * private data, so it saw a NEW queue on every ExecuteCommandLists: it created
 * a fence each time, signalled it once, and gave every later sync point one
 * entry per fence ever made. ph-empire08: the RHI submission thread made ~5 M
 * GetCompletedValue calls/s, ~93% of a P core, every sampled one on a fence
 * parked at 1, growing without bound as the session went on.
 * Keyed by (object, GUID); SetPrivateDataInterface holds a reference; every
 * destructor purges its object so a reused address inherits nothing. */
struct mad_pd { const void *obj; GUID guid; UINT size; void *data; IUnknown *iface; struct mad_pd *next; };
static struct mad_pd *g_pd[256]; static SRWLOCK g_pd_lock = SRWLOCK_INIT; static LONG g_pd_count;
static unsigned mad_pd_hash(const void *o) { UINT64 x = (UINT64)(ULONG_PTR)o; x ^= x >> 17; x *= 0x9E3779B97F4A7C15ull; return (unsigned)(x >> 56); }
static void mad_pd_free_list(struct mad_pd *e) {
    while (e) { struct mad_pd *n = e->next; if (e->iface) IUnknown_Release(e->iface); free(e->data); free(e); e = n; }
}
static struct mad_pd *mad_pd_unlink_locked(const void *obj, REFGUID g) {   /* g NULL = every entry of obj */
    struct mad_pd **pp = &g_pd[mad_pd_hash(obj)], *out = NULL;
    while (*pp) {
        struct mad_pd *e = *pp;
        if (e->obj == obj && (!g || !memcmp(&e->guid, g, sizeof(GUID)))) { *pp = e->next; e->next = out; out = e; InterlockedDecrement(&g_pd_count); }
        else pp = &e->next;
    }
    return out;
}
static HRESULT mad_pd_get(const void *obj, REFGUID g, UINT *n, void *d) {
    struct mad_pd *e; HRESULT hr = DXGI_ERROR_NOT_FOUND;
    if (!n || !g) return E_INVALIDARG;
    AcquireSRWLockShared(&g_pd_lock);
    for (e = g_pd[mad_pd_hash(obj)]; e; e = e->next) if (e->obj == obj && !memcmp(&e->guid, g, sizeof(GUID))) break;
    if (!e) *n = 0;
    else {
        UINT need = e->iface ? (UINT)sizeof(IUnknown *) : e->size;
        if (!d) hr = S_OK;
        else if (*n < need) hr = DXGI_ERROR_MORE_DATA;
        else {
            if (e->iface) { IUnknown_AddRef(e->iface); *(IUnknown **)d = e->iface; }
            else memcpy(d, e->data, e->size);
            hr = S_OK;
        }
        *n = need;
    }
    ReleaseSRWLockShared(&g_pd_lock);
    return hr;
}
static HRESULT mad_pd_store(const void *obj, REFGUID g, UINT n, const void *d, IUnknown *iface) {
    struct mad_pd *old, *e = NULL;
    if (!g) return E_INVALIDARG;
    if (iface || (d && n)) {
        e = calloc(1, sizeof *e);
        if (!e) return E_OUTOFMEMORY;
        e->obj = obj; e->guid = *g;
        if (iface) { IUnknown_AddRef(iface); e->iface = iface; }
        else { e->data = malloc(n); if (!e->data) { free(e); return E_OUTOFMEMORY; } memcpy(e->data, d, n); e->size = n; }
    }
    AcquireSRWLockExclusive(&g_pd_lock);
    old = mad_pd_unlink_locked(obj, g);
    if (e) { unsigned h = mad_pd_hash(obj); e->next = g_pd[h]; g_pd[h] = e; InterlockedIncrement(&g_pd_count); }
    ReleaseSRWLockExclusive(&g_pd_lock);
    mad_pd_free_list(old);   /* outside the lock: releasing an interface may re-enter */
    return S_OK;
}
static HRESULT mad_pd_set(const void *obj, REFGUID g, UINT n, const void *d) { return mad_pd_store(obj, g, n, d, NULL); }
static HRESULT mad_pd_set_iface(const void *obj, REFGUID g, const IUnknown *i) { return mad_pd_store(obj, g, 0, NULL, (IUnknown *)i); }
static void mad_pd_purge(const void *obj) {
    struct mad_pd *old;
    if (!g_pd_count) return;
    AcquireSRWLockExclusive(&g_pd_lock);
    old = mad_pd_unlink_locked(obj, NULL);
    ReleaseSRWLockExclusive(&g_pd_lock);
    mad_pd_free_list(old);
}

static ULONG mad_release(struct mad_obj *o) {
    LONG r = InterlockedDecrement(&o->refs);
    if (r == 0) { mad_pd_purge(o);   /* ml1143 */
        d3d12_log("[madeira-d3d12] destroyed %s\n", o->name);
        free(o);
    }
    return (ULONG)r;
}

/* ---- fence ---------------------------------------------------------------
 * A completed value plus a list of waiters. The design requires immediate
 * completion, multiple waiters and late registration all to work: registering
 * for a value already reached must signal at once rather than wait forever. */
#define MAD_FENCE_WAITERS 16
struct mad_fence {
    ID3D12FenceVtbl *vtbl;
    LONG refs;
    const IID *iid;
    const char *name;
    CRITICAL_SECTION lock;
    /* A null event means "block this thread until the value is reached", so the
     * fence needs a way to wait that RELEASES the lock -- otherwise the thread
     * that would advance the fence cannot get in, and the wait is a deadlock
     * rather than a wait. A condition variable over the same critical section
     * is exactly that. */
    CONDITION_VARIABLE cv;
    UINT64 value;
    volatile LONG64 submitted;   /* ml1061: highest value a queue has been ASKED to signal */
    volatile LONG64 committed;   /* ml1120: highest value whose Signal batch has been COMMITTED to Metal (or signalled on the CPU) */
    struct { UINT64 value; HANDLE event; LONGLONG t_reg; } waiters[MAD_FENCE_WAITERS];   /* ml1109: t_reg = registration time */
    unsigned nwaiters;
};

static void fence_set_locked(struct mad_fence *f, UINT64 v) {
    f->value = v;
    WakeAllConditionVariable(&f->cv);
    unsigned w = 0;
    for (unsigned i = 0; i < f->nwaiters; i++) {
        if (f->waiters[i].value <= v) {
            LARGE_INTEGER t; QueryPerformanceCounter(&t);   /* ml1109: how long the game sat on this fence */
            InterlockedExchangeAdd64(&g_perf_wait_ticks, t.QuadPart - f->waiters[i].t_reg);
            SetEvent(f->waiters[i].event);
        }
        else f->waiters[w++] = f->waiters[i];
    }
    f->nwaiters = w;
}

static HRESULT STDMETHODCALLTYPE fence_QI(ID3D12Fence *This, REFIID riid, void **out) {
    return mad_qi((struct mad_obj *)This, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE fence_AddRef(ID3D12Fence *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE fence_Release(ID3D12Fence *This) {
    struct mad_fence *f = (struct mad_fence *)This;
    LONG r = InterlockedDecrement(&f->refs);
    if (r == 0) { mad_pd_purge(This);   /* ml1143 */ DeleteCriticalSection(&f->lock); d3d12_log("[madeira-d3d12] destroyed %s\n", f->name); free(f); }
    return (ULONG)r;
}
/* ml1142: WHO SPINS ON GetCompletedValue. ph-empire07: 4.4 M calls/s from the
 * ExecuteCommandLists thread (UE's RHI submission thread), ~93% of a P core,
 * with SetEventOnCompletion called only ~4 times a frame. One call in 2^18 scans
 * its own stack for return addresses inside the game executable (the x64 frames
 * sit on the same stack in ARM64EC) and tallies the nearest two, with the
 * thread's name, so the loop can be read in the executable. Diagnostic only. */
static LONG g_gcv_calls;
static struct { ULONG_PTR r0, r1; DWORD tid; LONG n; } g_gcv_site[16];
static void mad_gcv_sample(struct mad_fence *f, UINT64 v) {
    static ULONG_PTR exe_lo, exe_hi; static LONG samples;
    ULONG_PTR hit[2] = { 0, 0 }, *p, *end; unsigned nh = 0, i; NT_TIB *tib = (NT_TIB *)NtCurrentTeb();
    volatile ULONG_PTR here = 0;
    if (!exe_lo) {
        HMODULE m = GetModuleHandleW(NULL); IMAGE_DOS_HEADER *dh = (IMAGE_DOS_HEADER *)m;
        IMAGE_NT_HEADERS64 *nt = (IMAGE_NT_HEADERS64 *)((BYTE *)m + dh->e_lfanew);
        exe_lo = (ULONG_PTR)m; exe_hi = exe_lo + nt->OptionalHeader.SizeOfImage;
    }
    p = (ULONG_PTR *)&here; end = p + 4096;
    if (tib && (ULONG_PTR)tib->StackBase > (ULONG_PTR)p && (ULONG_PTR *)tib->StackBase < end) end = (ULONG_PTR *)tib->StackBase;
    for (; p < end && nh < 2; p++) if (*p >= exe_lo + 0x1000 && *p < exe_hi) hit[nh++] = *p - exe_lo;
    for (i = 0; i < 16; i++) {
        if (g_gcv_site[i].n && g_gcv_site[i].r0 == hit[0] && g_gcv_site[i].r1 == hit[1] && g_gcv_site[i].tid == GetCurrentThreadId()) { g_gcv_site[i].n++; break; }
        if (!g_gcv_site[i].n) { g_gcv_site[i].r0 = hit[0]; g_gcv_site[i].r1 = hit[1]; g_gcv_site[i].tid = GetCurrentThreadId(); g_gcv_site[i].n = 1; break; }
    }
    if ((++samples % 64) == 1) {
        WCHAR *wn = NULL; char nm[64] = "?";
        if (SUCCEEDED(GetThreadDescription(GetCurrentThread(), &wn)) && wn) { WideCharToMultiByte(CP_UTF8, 0, wn, -1, nm, sizeof nm, NULL, NULL); LocalFree(wn); }
        d3d12_log("[gcv] ml1142 %ld calls; this thread %04lx '%s' polls %s at %llu (signalled %llu); exe callers (rva) by thread:\n",
                  (long)g_gcv_calls, GetCurrentThreadId(), nm, f->name ? f->name : "fence", (unsigned long long)v, (unsigned long long)f->value);
        for (i = 0; i < 16 && g_gcv_site[i].n; i++)
            d3d12_log("[gcv]   %04lx  +0x%llx <- +0x%llx  x%ld\n", g_gcv_site[i].tid, (unsigned long long)g_gcv_site[i].r0, (unsigned long long)g_gcv_site[i].r1, (long)g_gcv_site[i].n);
    }
}
static UINT64 STDMETHODCALLTYPE fence_GetCompletedValue(ID3D12Fence *This) {
    struct mad_fence *f = (struct mad_fence *)This;
    InterlockedIncrement(&g_perf_polls);   /* ml1109 */
    if ((InterlockedIncrement(&g_gcv_calls) & 0x3ffff) == 0) mad_gcv_sample(f, f->value);   /* ml1142 */
    EnterCriticalSection(&f->lock);
    UINT64 v = f->value;
    LeaveCriticalSection(&f->lock);
    return v;
}
static HRESULT STDMETHODCALLTYPE fence_SetEventOnCompletion(ID3D12Fence *This, UINT64 value, HANDLE event) {
    struct mad_fence *f = (struct mad_fence *)This;
    HRESULT hr = S_OK;
    EnterCriticalSection(&f->lock);
    if (value <= f->value) {
        /* Already reached. Signalling now is the documented behaviour; queueing
         * it would hang a caller that waits on a value in the past. */
        if (event) SetEvent(event);
    } else if (!event) {
        /* Documented behaviour for a null event is to block until the value is
         * reached, not to reject the call. SleepConditionVariableCS drops the
         * lock while waiting and reacquires it on wake, so a signalling thread
         * can make progress. Re-checked in a loop because a condition variable
         * may wake spuriously and because an intervening signal may not have
         * reached our value yet. */
        while (f->value < value)
            SleepConditionVariableCS(&f->cv, &f->lock, INFINITE);
    } else if (f->nwaiters < MAD_FENCE_WAITERS) {
        { LARGE_INTEGER t; QueryPerformanceCounter(&t); f->waiters[f->nwaiters].t_reg = t.QuadPart; }   /* ml1109 */
        InterlockedIncrement(&g_perf_waits);
        f->waiters[f->nwaiters].value = value;
        f->waiters[f->nwaiters].event = event;
        f->nwaiters++;
    } else {
        hr = E_OUTOFMEMORY;
    }
    LeaveCriticalSection(&f->lock);
    return hr;
}
static void mad_fence_committed(struct mad_fence *f, UINT64 value);
static HRESULT STDMETHODCALLTYPE fence_Signal(ID3D12Fence *This, UINT64 value) {
    struct mad_fence *f = (struct mad_fence *)This;
    EnterCriticalSection(&f->lock);
    fence_set_locked(f, value);
    LeaveCriticalSection(&f->lock);
    mad_fence_committed(f, value);   /* ml1120: a CPU signal releases queue Waits too */
    return S_OK;
}

/* ---- command allocator --------------------------------------------------- */
static int mad_list_type_ok(D3D12_COMMAND_LIST_TYPE t) {
    return t == D3D12_COMMAND_LIST_TYPE_DIRECT || t == D3D12_COMMAND_LIST_TYPE_COMPUTE ||
           t == D3D12_COMMAND_LIST_TYPE_COPY;
}

struct mad_alloc {
    ID3D12CommandAllocatorVtbl *vtbl;
    LONG refs;
    const IID *iid;
    const char *name;
    D3D12_COMMAND_LIST_TYPE type;
    LONG recording;    /* a list is currently recording into this allocator */
    LONG generation;   /* bumped by Reset; lists recorded against an older one
                        * are no longer executable, which is the rule that makes
                        * "reset then execute the same list" illegal */
};

static HRESULT STDMETHODCALLTYPE alloc_QI(ID3D12CommandAllocator *This, REFIID riid, void **out) {
    return mad_qi((struct mad_obj *)This, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE alloc_AddRef(ID3D12CommandAllocator *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE alloc_Release(ID3D12CommandAllocator *This) { return mad_release((struct mad_obj *)This); }
static HRESULT STDMETHODCALLTYPE alloc_Reset(ID3D12CommandAllocator *This) {
    struct mad_alloc *a = (struct mad_alloc *)This;
    /* Resetting storage a list is still recording into would pull the memory out
     * from under it. Refusing is what the API requires and what catches the bug
     * at the call site instead of later. */
    if (a->recording) return E_FAIL;
    /* Storage is reused from here, so everything previously recorded from this
     * allocator becomes stale. */
    InterlockedIncrement(&a->generation);
    return S_OK;
}

/* ---- graphics command list ----------------------------------------------- */
/* ---- command list: a recorded command stream ---------------------------
 * ml858. Until now a list held one render pass, one copy batch and one
 * readback, and refused anything beyond that at Close ("list overflowed").
 * An engine's first list has hundreds of copies, several passes and clears
 * that arrive in any order, so recording is now a growable stream of
 * commands replayed in order at execute time, where Metal encoders are
 * opened and closed as the stream demands. Recording never fails for lack
 * of room; what execution cannot do yet is named once in the log and
 * skipped, so a frame is never silently truncated at Close. */
enum mad_ck {
    MC_PSO, MC_ROOT, MC_HEAPS, MC_VP, MC_SCISSOR, MC_TOPO, MC_IB, MC_VB, MC_RTS,
    MC_CLEAR_RT, MC_CLEAR_DS, MC_DRAW, MC_DRAW_INDEXED,
    MC_DRAW_INDIRECT, MC_DRAW_INDEXED_INDIRECT, MC_DISPATCH_INDIRECT,   /* ml889: ExecuteIndirect */
    MC_FILL_BB, MC_BLEND_FACTOR,   /* ml892: UAV buffer clears, blend factor */
    MC_COPY_BB, MC_COPY_B2T, MC_COPY_T2B, MC_COPY_T2T, MC_DISPATCH,
    MC_RESOLVE,   /* ResolveSubresource: uses u.tt */
    MC_ROOTSIG, MC_ROOT_CONST, MC_STENCIL_REF,
    MC_CROOTSIG, MC_CROOT, MC_CROOT_CONST,
    MC_QUERY_BEGIN, MC_QUERY_END, MC_QUERY_RESOLVE,   /* ml1088: occlusion queries */
    MC_BARRIER,   /* ml1091: a ResourceBarrier; ends an open compute or blit encoder so the fence chain orders what follows */
};
struct mad_cmd {
    enum mad_ck kind;
    union {
        struct mad_pso *pso;
        struct { UINT index; UINT64 value; } root;
        struct mad_rootsig *rootsig;
        struct { UINT index, dst, n, data; } rconst;   /* data: offset into the list's constant words */
        UINT stencil_ref;
        struct { struct mad_heap *srv, *smp; } heaps;
        D3D12_VIEWPORT vp;
        D3D12_RECT scissor;
        D3D12_PRIMITIVE_TOPOLOGY topo;
        struct { struct mad_resource *res; UINT64 off; enum WMTIndexType type; } ib;
        struct { UINT slot; struct mad_resource *res; UINT64 off; UINT stride; } vb;
        struct { struct mad_resource *rt[8]; UINT n; struct mad_resource *depth; struct mad_rtvp v[8], dv; } rts;   /* ml925: + sub-views */
        struct { struct mad_resource *res[8]; UINT n; UINT all; UINT8 cls[8]; UINT8 cls_noref; } barrier;   /* ml1116: transitioned resources; all = UAV/aliasing/overflow; ml1137: state classes (BC_*) */
        struct { struct mad_resource *res; float rgba[4]; float depth; UINT8 stencil; UINT8 flags; struct mad_rtvp v; } clear;   /* ml904: flags = D3D12_CLEAR_FLAGS; ml925: v = the view cleared */
        struct { UINT vcount, icount, vstart, istart; } draw;
        struct { UINT icount, inst, start; INT base; UINT istart; } drawi;
        struct { struct mad_resource *dst, *src; UINT64 doff, soff, len; } bb;
        /* buffer<->texture: the buffer side is described by a footprint */
        struct { struct mad_resource *tex, *buf; UINT64 off; UINT row, rows; UINT w, h, d; UINT level, slice; UINT x, y, z; } bt;
        struct { struct mad_resource *dst, *src; UINT dlevel, dslice, slevel, sslice; UINT w, h, d; UINT dx, dy, dz, sx, sy, sz; } tt;
        struct { UINT x, y, z; } dispatch;
        struct { struct mad_resource *args; UINT64 off; UINT count; UINT stride; struct mad_resource *cnt; UINT64 cnt_off; } ind;
        struct { struct mad_resource *res; UINT64 off, len; UINT8 byte; obj_handle_t pattern; } fill;   /* ml1151: pattern = exact 32-bit source */
        struct { float rgba[4]; } blend;
        struct { struct mad_queryheap *heap; UINT type, index, count; struct mad_resource *dst; UINT64 off; } query;   /* ml1088 */
    } u;
};

#define MAD_ARG_RING_BYTES  (64u * 1024u)
#define MAD_ARG_SLOT_BYTES  1088u  /* up to 64 dwords of root constants plus 32 root arguments, then ml912 draw params, then the ml927 vertex-buffer table */
#define MAD_ARG_DRAWPARAMS_OFF 512u /* IRRuntimeDrawParams (20 bytes) at kIRArgumentBufferDrawArgumentsBindPoint */
#define MAD_ARG_DRAWINFO_OFF   544u /* IRRuntimeDrawInfo (24 bytes; first uint16 = index type) at kIRArgumentBufferUniformsBindPoint */
#define MAD_ARG_VBTABLE_OFF    576u /* ml927: IRRuntimeVertexBuffers (31 x {addr, length, stride} = 496 bytes) at kIRVertexBufferBindPoint, object stage */

struct mad_list {
    ID3D12GraphicsCommandList7Vtbl *vtbl;   /* ml1144: full List7 slot table, List1..7 answered */
    LONG refs;
    const IID *iid;
    const char *name;
    D3D12_COMMAND_LIST_TYPE type;
    struct mad_alloc *alloc;
    int closed;
    LONG recorded_generation;  /* the allocator generation this list recorded against */
    struct mad_device *device;
    struct mad_cmd *cmds;
    unsigned ncmds, ccap;
    /* Resources reached by address through root descriptors; declared
     * resident at every draw because Metal cannot see them. */
    struct mad_resource **used;
    unsigned nused, ucap;
    /* Argument buffers: one slot of root values per draw, carved from shared
     * chunks. A draw's root arguments must survive until the GPU reads them,
     * so a single buffer rewritten per draw would race the previous draw. */
    volatile LONG inflight;   /* ml1120: submission-worker jobs still holding this list; Reset waits for 0 */
    obj_handle_t *rings; void **ring_cpu; UINT64 *ring_gpu; unsigned nrings; unsigned ring_used;
    struct mad_queue *ring_q; UINT64 ring_batch;   /* ml1061: the batch that last read these chunks */
    /* ml1008: ring_gpu is each chunk's GPU address. The DXBC backend's constant
     * buffers are POINTERS in a table, so root constants consumed as a CBV need a
     * GPU-visible copy with a per-dispatch lifetime -- which is what this ring is. */
    UINT32 *cdata; unsigned ncdata, cdcap;   /* root constant words, referenced by MC_ROOT_CONST */
};

static struct mad_cmd *mad_list_push(struct mad_list *l, enum mad_ck kind) {
    struct mad_cmd *c;
    if (l->closed) return NULL;
    if (!mad_grow((void **)&l->cmds, &l->ccap, l->ncmds + 1, sizeof *l->cmds)) return NULL;
    c = &l->cmds[l->ncmds++];
    memset(c, 0, sizeof *c);
    c->kind = kind;
    return c;
}
static void mad_list_note_used(struct mad_list *l, struct mad_resource *r) {
    unsigned i, from = l->nused > 64 ? l->nused - 64 : 0;
    if (!r) return;
    for (i = from; i < l->nused; i++) if (l->used[i] == r) return;
    if (mad_grow((void **)&l->used, &l->ucap, l->nused + 1, sizeof *l->used)) l->used[l->nused++] = r;
}

static HRESULT STDMETHODCALLTYPE list_QI(ID3D12GraphicsCommandList *This, REFIID riid, void **out) {
    struct mad_obj *o = (struct mad_obj *)This;
    /* ml1144: every D3D12 runtime answers GraphicsCommandList1..7 whatever the
     * hardware supports; the optional methods are gated by CheckFeatureSupport,
     * which reports them all off. UE 5.0 queries List4 for ray tracing whenever
     * the device answers Device5, and a refusal is a LowLevelFatalError. */
    if (out && (IsEqualGUID(riid, &IID_ID3D12CommandList) ||
                IsEqualGUID(riid, &IID_ID3D12GraphicsCommandList1) || IsEqualGUID(riid, &IID_ID3D12GraphicsCommandList2) ||
                IsEqualGUID(riid, &IID_ID3D12GraphicsCommandList3) || IsEqualGUID(riid, &IID_ID3D12GraphicsCommandList4) ||
                IsEqualGUID(riid, &IID_ID3D12GraphicsCommandList5) || IsEqualGUID(riid, &IID_ID3D12GraphicsCommandList6) ||
                IsEqualGUID(riid, &IID_ID3D12GraphicsCommandList7))) {
        InterlockedIncrement(&o->refs);
        *out = o;
        return S_OK;
    }
    return mad_qi(o, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE list_AddRef(ID3D12GraphicsCommandList *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE list_Release(ID3D12GraphicsCommandList *This) {
    struct mad_list *l = (struct mad_list *)This;
    LONG r = InterlockedDecrement(&l->refs);
    if (r == 0) { mad_pd_purge(This);   /* ml1143 */
        if (l->alloc && !l->closed) InterlockedDecrement(&l->alloc->recording);
        if (l->alloc) ID3D12CommandAllocator_Release((ID3D12CommandAllocator *)l->alloc);
        for (unsigned k = 0; k < l->nrings; k++) NSObject_release(l->rings[k]);
        free(l->rings); free(l->ring_cpu); free(l->ring_gpu); free(l->cmds); free(l->used); free(l->cdata);
        free(l);
    }
    return (ULONG)r;
}
static void mad_list_wait_idle(struct mad_list *l);
static HRESULT STDMETHODCALLTYPE list_Close(ID3D12GraphicsCommandList *This) {
    struct mad_list *l = (struct mad_list *)This;
    if (l->closed) return E_FAIL;          /* double Close is a caller bug */
    l->closed = 1;
    l->recorded_generation = l->alloc ? l->alloc->generation : 0;
    if (l->alloc) InterlockedDecrement(&l->alloc->recording);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE list_Reset(ID3D12GraphicsCommandList *This,
                                            ID3D12CommandAllocator *allocator,
                                            ID3D12PipelineState *pso) {
    struct mad_list *l = (struct mad_list *)This;
    (void)pso;
    if (!l->closed) return E_FAIL;         /* reset while recording */
    if (!allocator) return E_INVALIDARG;
    if (l->inflight) mad_list_wait_idle(l);   /* ml1120: the submission worker still replays it */
    if (l->alloc != (struct mad_alloc *)allocator) {
        if (l->alloc) ID3D12CommandAllocator_Release((ID3D12CommandAllocator *)l->alloc);
        l->alloc = (struct mad_alloc *)allocator;
        ID3D12CommandAllocator_AddRef(allocator);
    }
    InterlockedIncrement(&l->alloc->recording);
    l->recorded_generation = l->alloc->generation;
    l->closed = 0;
    l->ncmds = 0;
    l->nused = 0;
    l->ncdata = 0;
    mad_list_rings_rewind(l);   /* ml1061: only reuses chunks the GPU has finished with */
    return S_OK;
}
static D3D12_COMMAND_LIST_TYPE STDMETHODCALLTYPE list_GetType(ID3D12GraphicsCommandList *This) {
    (void)This;
    return ((struct mad_list *)This)->type;
}

/* ---- command queue ------------------------------------------------------- */
struct mad_queue {
    ID3D12CommandQueueVtbl *vtbl;
    LONG refs;
    const IID *iid;
    const char *name;
    D3D12_COMMAND_LIST_TYPE type;
    UINT64 executed;
    UINT64 rejected;
    struct mad_device *device;
    /* Command buffers submitted but not yet known complete. A fence signal must
     * wait for these, otherwise it reports GPU work finished that has only been
     * submitted -- which is the difference between a fence and a counter. */
    obj_handle_t pending[16];
    unsigned npending;
    UINT64 untracked;   /* submissions the fence could not be made to cover */
    /* ml884: one Metal command buffer per BATCH of submissions, not per
     * ExecuteCommandLists. The engine submits ~31 lists per frame; each used
     * to be its own command buffer with its own round trips and its own
     * shadow-buffer flush (measured: 6.6 ms per submission = 5 FPS). The open
     * buffer is committed at Signal, Wait, Present or after open_cap lists. */
    obj_handle_t open_cb;
    UINT64 last_serial;            /* ml1061: serial of the newest committed batch */
    UINT64 batch_serial[64];       /* serial of batch n at [n & 63] */
    unsigned open_lists;
    UINT64 batches;
    /* ml1021: SUBMISSION LOCK.
     *
     * open_cb / open_lists / pending[] / npending were mutated with no
     * synchronisation at all, while Present and Fence::Wait both call
     * mad_device_flush_all, which commits EVERY queue's open buffer. So this
     * interleaving was legal even with one submitting thread per queue:
     *
     *   worker opens command buffer C and starts encoding a list into it
     *   present thread calls flush_all and COMMITS C
     *   worker keeps encoding into a committed buffer
     *
     * That is the source-level cause of the whole class of host complaints we
     * have been patching around: duplicate commits (ml1015), an encoder still
     * open at commit (ml1010), and batches aimed at an encoder recovery had to
     * force-end (ml1016). Those host guards keep the daemon alive; they do not
     * make the submission correct, and they DROP work.
     *
     * A Win32 CRITICAL_SECTION is recursive, so mad_queue_flush being reached
     * from inside a locked ExecuteCommandLists is safe. */
    CRITICAL_SECTION submit_lock;
    struct mad_vis_batch *vis;     /* ml1088: the open batch's query slots, NULL until a query heap exists */
    /* ml1120: ASYNCHRONOUS SUBMISSION. With madeira.cfg async-submit = 1 every
     * queue owns a worker thread and a FIFO; ExecuteCommandLists, Signal and Wait
     * enqueue and return, and the worker replays them in exactly the order the
     * application issued them. Measured before (ph-rdr71): the game's render
     * thread spent 10-24 ms of every 30-53 ms frame inside ExecuteCommandLists,
     * encoding ~2900 draws and dispatches at ~4.5 us each. */
    HANDLE sub_thread;
    CRITICAL_SECTION sub_lock;
    CONDITION_VARIABLE sub_work, sub_idle;
    struct mad_subjob *sub_head, *sub_tail;
    int sub_busy, sub_quit;
    CONDITION_VARIABLE sub_presented; LONG sub_presents;   /* ml1121: queued presents not yet done */
    /* ml1134: fence-chain = 6. Every encoder updates its own fence from this
     * pool; f6_pend lists the encoders that no later encoder has waited for
     * yet, with the attachments each one wrote. Touched only under
     * submit_lock (the replay and mad_queue_flush both hold it). */
    obj_handle_t f6_pool[64]; unsigned f6_next;
    struct mad_f6_pend { unsigned char idx, kind, natt; struct mad_resource *att[9]; } f6_pend[40]; unsigned f6_npend;
};

static HRESULT mad_queue_dxgi_tearoff(struct mad_queue *q, void **out);
static HRESULT STDMETHODCALLTYPE queue_QI(ID3D12CommandQueue *This, REFIID riid, void **out) {
    HRESULT hr = mad_qi((struct mad_obj *)This, riid, out, 1);
    if (hr == E_NOINTERFACE && IsEqualGUID(riid, &IID_IMTLDXGIDevice))
        return mad_queue_dxgi_tearoff((struct mad_queue *)This, out);
    return hr;
}
static ULONG STDMETHODCALLTYPE queue_AddRef(ID3D12CommandQueue *This) { return mad_addref((struct mad_obj *)This); }
static void mad_queue_flush(struct mad_queue *q);
static void mad_queue_drain(struct mad_queue *q);
static ULONG STDMETHODCALLTYPE queue_Release(ID3D12CommandQueue *This) {
    struct mad_queue *q = (struct mad_queue *)This;
    LONG r = InterlockedDecrement(&q->refs);
    if (r == 0) { mad_pd_purge(This);   /* ml1143 */
        struct mad_device *d = q->device;
        unsigned i;
        if (q->sub_thread) {   /* ml1120: finish the FIFO, then stop the worker */
            mad_queue_drain(q);
            EnterCriticalSection(&q->sub_lock); q->sub_quit = 1; WakeAllConditionVariable(&q->sub_work); LeaveCriticalSection(&q->sub_lock);
            WaitForSingleObject(q->sub_thread, 10000);
            CloseHandle(q->sub_thread); q->sub_thread = NULL;
            DeleteCriticalSection(&q->sub_lock);
        }
        mad_queue_flush(q);                          /* ml884: never free a queue holding an open batch */
        for (i = 0; i < q->npending; i++) NSObject_release(q->pending[i]);
        q->npending = 0;
        if (d) {
            EnterCriticalSection(&d->live_lock);
            for (i = 0; i < d->nqueues; i++) if (d->queues[i] == q) { d->queues[i] = d->queues[--d->nqueues]; break; }
            LeaveCriticalSection(&d->live_lock);
        }
        d3d12_log("[madeira-d3d12] destroyed %s\n", q->name);
        DeleteCriticalSection(&q->submit_lock);   /* ml1021 */
        free(q);
    }
    return (ULONG)r;
}
/* ---- execution: replaying a list into Metal encoders -------------------- */
struct mad_exec {
    int fence_needed;
    struct mad_resource *wr[64]; unsigned nwr; int wr_all;   /* ml1116: written since the last fence wait (mode 3) */   /* ml1111: fence-chain = 2: a barrier (or list start) was seen since the last wait */
    struct mad_queue *q;
    struct mad_list *l;
    obj_handle_t cb, renc, benc;
    struct mad_resource *rt[8]; UINT nrt; struct mad_resource *depth;          /* bound */
    struct mad_rtvp rtp[8], dp; struct mad_rtvp enc_rtp[8], enc_dp;            /* ml925: bound / encoded sub-views */
    struct mad_resource *enc_rt[8]; UINT enc_nrt; struct mad_resource *enc_depth; /* what the open encoder has */
    UINT enc_w, enc_h;              /* ml934b: and the area it was created with */
    struct { struct mad_resource *res; float rgba[4]; float depth; UINT8 stencil; UINT8 flags; int is_depth; struct mad_rtvp v; } pend[16];
    unsigned npend;
    struct mad_pso *pso;
    struct mad_rootsig *rs;
    unsigned cap_after;   /* ml918: capture rt[0] texels after the current draw */
    struct mad_resource *cap_after_cs;   /* ml920: texture to capture after the current dispatch */
    struct { struct mad_resource *r; UINT64 off; char label[96]; } cap_after_buf[6]; unsigned ncap_after_buf;   /* ml922 */
    struct { struct mad_resource *r; UINT slice; char label[96]; } cap_after_tex[6]; unsigned ncap_after_tex;   /* ml924 */
    UINT64 root[MAD_ROOT_PARAM_MAX]; UINT nroot;
    UINT32 consts[MAD_ROOT_PARAM_MAX][64];
    UINT stencil_ref;
    float blend[4]; int has_blend;                  /* ml892 */
    struct mad_pso *cpso;
    struct mad_rootsig *crs;
    UINT64 croot[MAD_ROOT_PARAM_MAX];
    UINT32 cconsts[MAD_ROOT_PARAM_MAX][64];
    obj_handle_t cenc;
    struct mad_heap *srv, *smp;
    D3D12_VIEWPORT vp; int has_vp;
    D3D12_RECT sc; int has_sc;
    D3D12_PRIMITIVE_TOPOLOGY topo;
    struct mad_resource *ib; UINT64 ib_off; enum WMTIndexType ib_type;
    unsigned renc_seq;                          /* ml879: rmetald label index of the open render encoder */
    struct { struct mad_resource *res; UINT64 off; UINT stride; } vb[16];
    unsigned draws, skipped;
    UINT64 vis_prev;            /* ml1088: the visibility slot the open encoder was last told to count into, ~0 = disabled */
    obj_handle_t enc_vis_buf;   /* ml1088: the slot chunk attached to the open encoder (a pass attribute) */
    unsigned pass_draws;        /* ml1098: draws encoded into the open render pass */
    /* ml1134: fence-chain = 6 */
    int f6_sync_needed;         /* a ResourceBarrier (or the list start) since the last sync point */
    int f6_list_start;          /* the next sync also waits for the device fence (other queue, earlier batch) */
    int f6_enc_synced;          /* the open encoder waited for every pending encoder at its start */
    unsigned f6_cur;            /* pool index of the open encoder's fence */
    struct mad_resource *f6_att[9]; unsigned f6_natt;   /* attachments of the encoder being begun */
    int mode;                   /* ml1136: fence-chain mode for this whole list (switchable live between lists) */
    unsigned cur;               /* ml1137: index of the command being replayed */
    UINT64 f7_mask; int f7_all, f7_open, f7_reason;   /* ml1137: what a state-aware barrier rule would wait for (census only) */
    int f7_next_rts;            /* ml1137: exec_end called by exec_begin_render: rt/depth are the NEXT pass's targets */
    /* resources already declared (useResource) on the current encoder, see mad_use_seen */
    obj_handle_t ud_enc; unsigned ud_n, ud_committed;
    struct { obj_handle_t h; UINT32 usage, stages; } ud[96];
};
static void mad_capture_pass(struct mad_exec *e, struct mad_resource **rt, unsigned nrt, const struct mad_rtvp *rtp,
                             struct mad_resource *depth, const struct mad_rtvp *dp, unsigned seq);
static void mad_mip_dims(const struct mad_resource *r, UINT level, UINT *w, UINT *h, UINT *d);

/* ml1088: OCCLUSION QUERIES.
 *
 * Metal counts passing samples into a "visibility result buffer" that is an
 * attribute of the RENDER PASS, at an offset set per draw; draws in one pass
 * that name the same offset accumulate. Nothing is promised across passes, so
 * this follows DXMT's D3D11 implementation exactly: a fresh 8-byte slot starts
 * whenever the set of active queries changes or an encoder ends, every draw
 * counts into the current slot, and a query's value is the CPU-side sum of the
 * slots between its Begin and its End, taken once the command buffer has
 * completed -- before the fence the game waits on advances (mad_cb_retire runs
 * ahead of the fence signal on the same worker). The slots live in 64 KB chunks
 * from the argument-ring pool, owned by the BATCH (command buffer), not by a
 * list, so nothing rewinds them before they are read.
 *
 * ResolveQueryData therefore delivers real values into the readback buffer on
 * the CPU. The constant "1 sample, visible" that stood in before this is what
 * kept every lens flare and light sprite at full strength through walls and in
 * daylight: their brightness is the occlusion fraction the game reads back. */
#define MAD_VIS_SLOTS (MAD_ARG_RING_BYTES / 8u)
struct mad_vis_query { struct mad_queryheap *heap; UINT index; UINT64 b, e; UINT64 end_seq; int applied; };
struct mad_vis_resolve { struct mad_queryheap *heap; UINT type, start, count; struct mad_resource *dst; UINT64 off; UINT64 seq; };
struct mad_vis_batch {
    obj_handle_t cb;
    struct mad_ringchunk *chunks; unsigned nchunks, ccap;
    UINT64 next; int dirty; unsigned active;
    UINT64 evseq;   /* ml1092: End and Resolve events keep their program order */
    struct mad_vis_query *q; unsigned nq, qcap;
    struct mad_vis_resolve *r; unsigned nr, rcap;
};
static struct mad_vis_batch *mad_vis_get(struct mad_exec *e);
static obj_handle_t mad_vis_chunk(struct mad_exec *e, struct mad_vis_batch *v, UINT64 slot, void **cpu_out);
static void exec_query_begin(struct mad_exec *e, const struct mad_cmd *c);
static void exec_query_end(struct mad_exec *e, const struct mad_cmd *c);
static void exec_query_resolve(struct mad_exec *e, const struct mad_cmd *c);
static void mad_vis_flush(struct mad_queue *q, obj_handle_t cb);

static long long mad_cfg_int_pe(const char *key, long long dflt);
/* ml1091 */
static int g_fence_chain = -1;   /* ml1110: madeira.cfg fence-chain = 0 disables the per-encoder fence (perf experiment; expect flicker) */
static obj_handle_t mad_enc_fence(struct mad_device *d) {
    if (g_fence_chain < 0) { g_fence_chain = (int)mad_cfg_int_pe("fence-chain", 1); if (g_fence_chain < 0 || g_fence_chain > 6 || g_fence_chain == 4) g_fence_chain = 1;   /* ml1114: 2 was clamped to 1 in ml1110-ml1113 */
                             d3d12_log("[madeira-d3d12] ml1110 fence-chain = %d (%s)\n", g_fence_chain, g_fence_chain == 6 ? "ml1134: barrier-driven: an encoder waits for every pending encoder only after a ResourceBarrier, at a list start, or when it reuses a pending encoder's attachment; compute stays open across barriers" : g_fence_chain == 5 ? "ml1118: full chain; a render pass waits at its FRAGMENT stage unless a compute/blit encoder ran since the last vertex-stage wait" : g_fence_chain == 3 ? "ml1116: an encoder waits only after a barrier on a resource written since the last wait" : g_fence_chain == 2 ? "ml1111: an encoder waits only after a ResourceBarrier or at a list start" : g_fence_chain ? "every encoder waits for the previous one" : "NO inter-encoder fences: perf experiment"); }
    if (!g_fence_chain) return 0;
    if (!d->enc_fence) d->enc_fence = MTLDevice_newFence(d->mtl_device);
    return d->enc_fence;
}
/* ml1136: the device fence whatever the current mode (a list keeps the mode it
 * started with, so the global may already say something else), and the mode a
 * new list starts with. */
static obj_handle_t mad_enc_fence_obj(struct mad_device *d) {
    if (!d->enc_fence) d->enc_fence = MTLDevice_newFence(d->mtl_device);
    return d->enc_fence;
}
static int mad_fence_mode(struct mad_device *d) { (void)mad_enc_fence(d); return g_fence_chain; }
static LONG g_f6_used;   /* ml1136: some list ran in mode 6 (Present then waits for the join) */
static void exec_note_write(struct mad_exec *e, struct mad_resource *r) {   /* ml1116 */
    unsigned i;
    if (!r || e->wr_all) return;
    for (i = 0; i < e->nwr; i++) if (e->wr[i] == r) return;
    if (e->nwr < 64) e->wr[e->nwr++] = r; else e->wr_all = 1;
}
/* ml1134: fence-chain = 6, BARRIER-DRIVEN ENCODER SYNC.
 *
 * Mode 1 makes every encoder wait for the whole previous one: ~260 full GPU
 * drains a frame in RDR2 (ph-rdr89), ~200 of them compute encoders that a
 * ResourceBarrier closed. With the fences off, GPU time per frame halved
 * (ph-rdr63/70) but rendering broke; after the power clamp the GPU is ~90 %
 * busy and the frame is GPU-bound, so that stall time is now the frame.
 *
 * D3D12's own rule is narrower than mode 1: work may overlap unless a barrier
 * separates it, except that writes to the same render target or depth buffer
 * stay ordered without one. Mode 6 follows that rule:
 *  - every encoder updates its OWN fence (a per-queue pool of 64) and joins
 *    the queue's pending set when it ends;
 *  - an encoder begun after a barrier or at a list start waits for EVERY
 *    pending encoder and empties the set: it is a sync point, and anything
 *    older is covered transitively through the sync point before it;
 *  - an encoder begun with no barrier since the last one waits for nothing,
 *    unless it is a pass whose attachments a pending encoder wrote, a blit
 *    after a pending blit, or the set is full;
 *  - at a barrier, an open encoder that did NOT sync at its start is closed,
 *    so what follows the barrier starts a new encoder, which syncs. A compute
 *    encoder that DID sync stays open: its serial dispatch orders the
 *    dispatches after the barrier behind the ones before it, and the encoder
 *    boundary mode 1 put at every barrier is gone (madeira.cfg
 *    f6-compute-open = 0 closes it anyway, for isolating a defect);
 *  - the device fence carries cross-queue and cross-batch order: it is waited
 *    for at the first sync of every list, and updated only by a join encoder
 *    at commit that waits for everything pending, so "the device fence
 *    passed" still means "every earlier batch finished", as in mode 1. The
 *    Present blit waits for it too. */
enum { F6_RENDER, F6_BLIT, F6_COMPUTE };
static int g_f6_compute_open = -1;
union f6_op { struct wmtcmd_render_fence_op r; struct wmtcmd_blit_fence_op b; struct wmtcmd_compute_fence_op c; };
static obj_handle_t f6_fence(struct mad_queue *q, unsigned idx) {
    if (!q->f6_pool[idx]) q->f6_pool[idx] = MTLDevice_newFence(q->device->mtl_device);
    return q->f6_pool[idx];
}
/* One encodeCommands call for all of an encoder's fence operations (a chain). */
static void f6_encode(obj_handle_t enc, int kind, const obj_handle_t *f, unsigned nwait, obj_handle_t update) {
    union f6_op ops[48];
    unsigned i, n = 0;
    memset(ops, 0, sizeof ops);
    for (i = 0; i < nwait && n < 47; i++, n++) {
        if (kind == F6_RENDER) { ops[n].r.type = WMTRenderCommandWaitForFence; ops[n].r.fence = f[i]; ops[n].r.stages = (enum WMTRenderStages)(WMTRenderStageVertex | WMTRenderStageObject); }
        else if (kind == F6_BLIT) { ops[n].b.type = WMTBlitCommandWaitForFence; ops[n].b.fence = f[i]; }
        else { ops[n].c.type = WMTComputeCommandWaitForFence; ops[n].c.fence = f[i]; }
    }
    if (update) {
        if (kind == F6_RENDER) { ops[n].r.type = WMTRenderCommandUpdateFence; ops[n].r.fence = update; ops[n].r.stages = WMTRenderStageFragment; }
        else if (kind == F6_BLIT) { ops[n].b.type = WMTBlitCommandUpdateFence; ops[n].b.fence = update; }
        else { ops[n].c.type = WMTComputeCommandUpdateFence; ops[n].c.fence = update; }
        n++;
    }
    if (!n) return;
    for (i = 0; i + 1 < n; i++) ops[i].r.next.ptr = &ops[i + 1];   /* next sits at the same offset in all three */
    if (kind == F6_RENDER) MTLRenderCommandEncoder_encodeCommands(enc, (const struct wmtcmd_base *)&ops[0]);
    else if (kind == F6_BLIT) MTLBlitCommandEncoder_encodeCommands(enc, (const struct wmtcmd_base *)&ops[0]);
    else MTLComputeCommandEncoder_encodeCommands(enc, (const struct wmtcmd_base *)&ops[0]);
}
static void f6_begin(struct mad_exec *e, int kind, obj_handle_t enc) {
    struct mad_queue *q = e->q;
    obj_handle_t waits[48];
    unsigned nw = 0, i, j, k;
    int other = q->f6_npend >= 40, need;
    for (i = 0; i < q->f6_npend && !other; i++) {
        if (kind == F6_BLIT && q->f6_pend[i].kind == F6_BLIT) other = 1;
        for (j = 0; j < q->f6_pend[i].natt && !other; j++)
            for (k = 0; k < e->f6_natt; k++)
                if (e->f6_att[k] && e->f6_att[k] == q->f6_pend[i].att[j]) { other = 1; if (!e->f6_sync_needed) InterlockedIncrement(&g_f6_att_sync); break; }
    }
    need = e->f6_sync_needed || other;
    InterlockedIncrement(&g_f6_begins);
    g_f6_used = 1;
    if (need && e->f6_sync_needed && !other && (e->f7_reason & 1) && !(e->f7_reason & 2)) {   /* ml1137: a sync caused only by barriers */
        unsigned np = q->f6_npend, rw;
        UINT64 m = e->f7_mask & (np >= 64 ? ~0ull : ((1ull << np) - 1));
        rw = e->f7_all ? np : (unsigned)__builtin_popcountll(m);
        InterlockedIncrement(&g_f7_bsync);
        InterlockedIncrement(e->f7_all ? &g_f7_all : rw ? &g_f7_subset : &g_f7_none);
        InterlockedExchangeAdd64(&g_f7_fw6, np); InterlockedExchangeAdd64(&g_f7_fwr, rw);
    }
    if (need) { e->f7_mask = 0; e->f7_all = 0; e->f7_open = 0; e->f7_reason = 0; }
    if (need) {
        if (e->f6_list_start && q->device->enc_fence) waits[nw++] = q->device->enc_fence;
        for (i = 0; i < q->f6_npend; i++) waits[nw++] = f6_fence(q, q->f6_pend[i].idx);
        f6_encode(enc, kind, waits, nw, 0);
        InterlockedExchangeAdd(&g_fence_waits, (LONG)nw);
        q->f6_npend = 0; e->f6_sync_needed = 0; e->f6_list_start = 0; e->f6_enc_synced = 1;
        InterlockedIncrement(&g_f6_synced);
    } else e->f6_enc_synced = 0;
    e->f6_cur = q->f6_next++ & 63;
}
static void f6_end(struct mad_exec *e, int kind, obj_handle_t enc) {
    struct mad_queue *q = e->q;
    struct mad_f6_pend *p;
    f6_encode(enc, kind, NULL, 0, f6_fence(q, e->f6_cur));
    InterlockedIncrement(&g_fence_updates);
    if (e->f7_open) { e->f7_mask |= 1ull << q->f6_npend; e->f7_open = 0; }   /* ml1137: the barrier needed this encoder */
    p = &q->f6_pend[q->f6_npend++];   /* < 40 here: a begin with 40 pending syncs and empties the set */
    p->idx = (unsigned char)e->f6_cur; p->kind = (unsigned char)kind; p->natt = (unsigned char)e->f6_natt;
    memcpy(p->att, e->f6_att, sizeof p->att);
    e->f6_natt = 0;
}
/* At commit: one blit encoder waits for everything pending and moves the device
 * fence, so the next batch (either queue) starts after all of this one. */
static void f6_join(struct mad_queue *q) {
    obj_handle_t waits[48], benc, dfence;
    unsigned i, nw = 0;
    if (!q->f6_npend || !q->open_cb) return;   /* ml1136: whatever the current mode */
    dfence = mad_enc_fence_obj(q->device);
    benc = MTLCommandBuffer_blitCommandEncoder(q->open_cb);
    if (!benc) return;
    for (i = 0; i < q->f6_npend; i++) waits[nw++] = f6_fence(q, q->f6_pend[i].idx);
    f6_encode(benc, F6_BLIT, waits, nw, dfence);
    MTLCommandEncoder_endEncoding(benc);
    q->f6_npend = 0;
    InterlockedIncrement(&g_f6_joins);
}
/* ml1136: a list in another mode that follows mode-6 lists first waits for the
 * encoders they left pending (the device fence does not cover them until a join). */
static void f6_drain(struct mad_exec *e, int kind, obj_handle_t enc) {
    struct mad_queue *q = e->q;
    obj_handle_t waits[48];
    unsigned i, n = 0;
    if (!q->f6_npend) return;
    for (i = 0; i < q->f6_npend; i++) waits[n++] = f6_fence(q, q->f6_pend[i].idx);
    f6_encode(enc, kind, waits, n, 0);
    q->f6_npend = 0;
}
/* ml1137: what a STATE-AWARE rule would require for this barrier batch, against
 * the encoders pending now and the one still open (counted, not applied):
 *   read -> read: nothing;  render target / depth -> read: the passes that had
 *   it attached;  copy dest -> read: pending blits;  UAV -> read and UAV
 *   barriers: pending compute and render encoders;  anything -> write, COMMON,
 *   aliasing: everything (as mode 6 does). */
static int f7_has_att(const struct mad_f6_pend *p, const struct mad_resource *r) {
    unsigned j;
    for (j = 0; j < p->natt; j++) if (p->att[j] == r) return 1;
    return 0;
}
static void f7_need(struct mad_exec *e, UINT8 cls, const struct mad_resource *r) {
    struct mad_queue *q = e->q;
    unsigned i;
    if (cls == BC_NONE || cls == BC_RAR) return;
    if (cls == BC_ALL) { e->f7_all = 1; return; }
    for (i = 0; i < q->f6_npend; i++) {
        const struct mad_f6_pend *p = &q->f6_pend[i];
        if ((cls == BC_RAW_ATT && p->kind == F6_RENDER && r && f7_has_att(p, r)) ||
            (cls == BC_RAW_COPY && p->kind == F6_BLIT) ||
            (cls == BC_RAW_UAV && p->kind != F6_BLIT)) e->f7_mask |= 1ull << i;
    }
    if (cls == BC_RAW_ATT && e->renc && r) {
        unsigned k;
        for (k = 0; k < e->enc_nrt; k++) if (e->enc_rt[k] == r) e->f7_open = 1;
        if (e->enc_depth == r) e->f7_open = 1;
    }
    if (cls == BC_RAW_COPY && e->benc) e->f7_open = 1;
    if (cls == BC_RAW_UAV && (e->cenc || e->renc)) e->f7_open = 1;
}
static void f7_census_barrier(struct mad_exec *e, const struct mad_cmd *c) {
    unsigned k;
    for (k = 0; k < c->u.barrier.n; k++) {
        UINT8 cls = c->u.barrier.cls[k];
        if (cls < 5) InterlockedIncrement(&g_bc_ent[cls]);
        f7_need(e, cls, c->u.barrier.res[k]);
    }
    if (c->u.barrier.cls_noref != BC_NONE) {
        if (c->u.barrier.cls_noref < 5) InterlockedIncrement(&g_bc_ent[c->u.barrier.cls_noref]);
        f7_need(e, c->u.barrier.cls_noref, NULL);
    }
    e->f7_reason |= 1;
}
static void exec_fence_render(struct mad_exec *e, obj_handle_t enc, int update) {
    struct wmtcmd_render_fence_op f;
    obj_handle_t fence;
    if (!enc || !e->mode) return;   /* ml1136: the list's own mode */
    fence = mad_enc_fence_obj(e->q->device);
    if (!fence) return;
    if (e->mode == 6) { if (update) f6_end(e, F6_RENDER, enc); else f6_begin(e, F6_RENDER, enc); return; }   /* ml1134 */
    if (!update) f6_drain(e, F6_RENDER, enc);   /* ml1136 */
    if (!update && (e->mode == 2 || e->mode == 3)) { if (!e->fence_needed) return; e->fence_needed = 0; e->nwr = 0; e->wr_all = 0; }   /* ml1111, ml1116 */
    memset(&f, 0, sizeof f);
    f.type = update ? WMTRenderCommandUpdateFence : WMTRenderCommandWaitForFence;
    f.fence = fence;
    f.stages = update ? WMTRenderStageFragment : (enum WMTRenderStages)(WMTRenderStageVertex | WMTRenderStageObject);
    /* ml1118: fence-chain = 5 keeps the full chain (every encoder waits for the
     * one before it, so transitivity holds) but lets a render pass's vertex and
     * tiling work overlap the previous render pass's fragment work, which is
     * what a tile-based GPU loses most at every encoder boundary. The vertex
     * stage still waits whenever a compute or blit encoder ran since the last
     * vertex-stage wait (skinning, culling, indirect arguments). Hazard it does
     * not cover: a vertex shader reading a texture the previous render pass
     * just drew. */
    if (!update && e->mode == 5) {
        if (InterlockedExchange(&e->q->device->f5_nonrender, 0)) f.stages = (enum WMTRenderStages)(WMTRenderStageVertex | WMTRenderStageObject);
        else f.stages = WMTRenderStageFragment;
    }
    MTLRenderCommandEncoder_encodeCommands(enc, (const struct wmtcmd_base *)&f);
    InterlockedIncrement(update ? &g_fence_updates : &g_fence_waits);
}
static void exec_fence_blit(struct mad_exec *e, obj_handle_t enc, int update) {
    struct wmtcmd_blit_fence_op f;
    obj_handle_t fence;
    if (!enc || !e->mode) return;   /* ml1136 */
    fence = mad_enc_fence_obj(e->q->device);
    if (!fence) return;
    if (e->mode == 6) { if (update) f6_end(e, F6_BLIT, enc); else f6_begin(e, F6_BLIT, enc); return; }   /* ml1134 */
    if (!update) f6_drain(e, F6_BLIT, enc);   /* ml1136 */
    if (!update && (e->mode == 2 || e->mode == 3)) { if (!e->fence_needed) return; e->fence_needed = 0; e->nwr = 0; e->wr_all = 0; }   /* ml1111, ml1116 */
    memset(&f, 0, sizeof f);
    if (update) InterlockedExchange(&e->q->device->f5_nonrender, 1);   /* ml1118 */
    f.type = update ? WMTBlitCommandUpdateFence : WMTBlitCommandWaitForFence;
    f.fence = fence;
    MTLBlitCommandEncoder_encodeCommands(enc, (const struct wmtcmd_base *)&f);
    InterlockedIncrement(update ? &g_fence_updates : &g_fence_waits);
}
static void exec_fence_compute(struct mad_exec *e, obj_handle_t enc, int update) {
    struct wmtcmd_compute_fence_op f;
    obj_handle_t fence;
    if (!enc || !e->mode) return;   /* ml1136 */
    fence = mad_enc_fence_obj(e->q->device);
    if (!fence) return;
    if (e->mode == 6) { if (update) f6_end(e, F6_COMPUTE, enc); else f6_begin(e, F6_COMPUTE, enc); return; }   /* ml1134 */
    if (!update) f6_drain(e, F6_COMPUTE, enc);   /* ml1136 */
    if (!update && (e->mode == 2 || e->mode == 3)) { if (!e->fence_needed) return; e->fence_needed = 0; e->nwr = 0; e->wr_all = 0; }   /* ml1111, ml1116 */
    memset(&f, 0, sizeof f);
    if (update) InterlockedExchange(&e->q->device->f5_nonrender, 1);   /* ml1118 */
    f.type = update ? WMTComputeCommandUpdateFence : WMTComputeCommandWaitForFence;
    f.fence = fence;
    MTLComputeCommandEncoder_encodeCommands(enc, (const struct wmtcmd_base *)&f);
    InterlockedIncrement(update ? &g_fence_updates : &g_fence_waits);
}

static UINT mad_pf_bytes(UINT pf);
/* ml1137: attachment census (1 in 16 frames). Bytes are the attachment's full
 * mip level at its texel size; what matters is the split, not the absolute. */
static LONG64 f7_att_bytes(const struct mad_resource *r, UINT level) {
    UINT b = mad_pf_bytes((UINT)r->tex_pf), w = r->width >> level, h = r->height >> level;
    if (!b) b = r->is_depth ? (r->has_stencil ? 5 : 4) : 4;
    if (!w) w = 1;
    if (!h) h = 1;
    return (LONG64)w * h * b * (r->samples ? r->samples : 1);
}
/* A stored attachment: what happens to it NEXT in this command list? cleared =
 * the store was wasted; read / rebound = needed; write = overwritten by a write
 * state (usually needed: partial writes); none = no use in this list. */
static void f7_store_census(struct mad_exec *e, const struct mad_resource *r, UINT level) {
    const struct mad_list *l = e->l;
    LONG64 b = f7_att_bytes(r, level), *cls = &g_ac_st_none;
    unsigned j, k, lim;
    int rebound = 0;
    InterlockedExchangeAdd64(&g_ac_store, b);
    for (k = 0; k < e->npend; k++) if (e->pend[k].res == r) { cls = &g_ac_st_cleared; goto done; }
    if (e->f7_next_rts) {
        for (k = 0; k < e->nrt; k++) if (e->rt[k] == r) rebound = 1;
        if (e->depth == r) rebound = 1;
    }
    lim = e->cur + 4096 < l->ncmds ? e->cur + 4096 : l->ncmds;
    for (j = e->cur; j < lim; j++) {
        const struct mad_cmd *c = &l->cmds[j];
        switch (c->kind) {
        case MC_CLEAR_RT: case MC_CLEAR_DS:
            if (c->u.clear.res == r) { cls = &g_ac_st_cleared; goto done; }
            break;
        case MC_RTS:
            for (k = 0; k < c->u.rts.n; k++) if (c->u.rts.rt[k] == r) rebound = 1;
            if (c->u.rts.depth == r) rebound = 1;
            break;
        case MC_DRAW: case MC_DRAW_INDEXED: case MC_DRAW_INDIRECT: case MC_DRAW_INDEXED_INDIRECT: case MC_DISPATCH: case MC_DISPATCH_INDIRECT:
            if (rebound) { cls = &g_ac_st_rebound; goto done; }
            break;
        case MC_BARRIER:
            for (k = 0; k < c->u.barrier.n; k++)
                if (c->u.barrier.res[k] == r) { cls = rebound ? &g_ac_st_rebound : c->u.barrier.cls[k] == BC_ALL ? &g_ac_st_write : &g_ac_st_read; goto done; }
            break;
        case MC_COPY_T2T: case MC_RESOLVE:
            if (c->u.tt.src == r) { cls = &g_ac_st_read; goto done; }
            if (c->u.tt.dst == r) { cls = &g_ac_st_write; goto done; }
            break;
        case MC_COPY_T2B:
            if (c->u.bt.tex == r) { cls = &g_ac_st_read; goto done; }
            break;
        case MC_COPY_B2T:
            if (c->u.bt.tex == r) { cls = &g_ac_st_write; goto done; }
            break;
        default: break;
        }
    }
    if (rebound) cls = &g_ac_st_rebound;
done:
    InterlockedExchangeAdd64(cls, b);
}
static void exec_end(struct mad_exec *e) {
    struct mad_resource *crt[8]; struct mad_resource *cdepth = NULL; struct mad_rtvp crtp[8], cdp; unsigned cn = 0, cseq = 0, cdraws = 0;   /* ml1098 */
    if (e->renc) exec_fence_render(e, e->renc, 1);     /* ml1091 */
    if (e->benc) exec_fence_blit(e, e->benc, 1);
    if (e->cenc) exec_fence_compute(e, e->cenc, 1);
    if (e->renc && g_att_census && e->l) {   /* ml1137 */
        unsigned k;
        for (k = 0; k < e->enc_nrt; k++) if (e->enc_rt[k] && e->enc_rt[k]->texture) f7_store_census(e, e->enc_rt[k], e->enc_rtp[k].level);
        if (e->enc_depth && e->enc_depth->texture) f7_store_census(e, e->enc_depth, e->enc_dp.level);
    }
    e->f7_next_rts = 0;
    if (e->renc) {
        if (g_capture_on) { cn = e->enc_nrt; memcpy(crt, e->enc_rt, sizeof crt); memcpy(crtp, e->enc_rtp, sizeof crtp); cdepth = e->enc_depth; cdp = e->enc_dp; cseq = e->renc_seq; cdraws = e->pass_draws; }
        MTLCommandEncoder_endEncoding(e->renc); e->renc = 0; e->enc_nrt = 0; e->enc_depth = NULL; e->enc_w = e->enc_h = 0;
        if (e->q->vis && e->q->vis->dirty) { e->q->vis->next++; e->q->vis->dirty = 0; }   /* ml1088: DXMT's endEncoder */
        e->vis_prev = ~(UINT64)0; e->enc_vis_buf = 0;
        e->pass_draws = 0;
    }
    if (e->benc) { MTLCommandEncoder_endEncoding(e->benc); e->benc = 0; }
    if (e->cenc) { MTLCommandEncoder_endEncoding(e->cenc); e->cenc = 0; }
    if (cdraws && g_capture_on) mad_capture_pass(e, crt, cn, crtp, cdepth, &cdp, cseq);   /* ml1098: after the pass, before anything else */
}

/* ml1098: one attachment -> one shared buffer, one file later. */
static void mad_capture_one(struct mad_exec *e, obj_handle_t benc, struct mad_resource *r, const struct mad_rtvp *v,
                            unsigned seq, unsigned idx, const char *kind, UINT options) {
    UINT w = 0, h = 0, d = 0, bytes = 0, block = 1; UINT64 bpr, total; obj_handle_t buf;
    struct WMTBufferInfo bi; struct wmtcmd_blit_copy_from_texture_to_buffer k; struct mad_capbuf *cb;
    static unsigned said_budget;
    if (!r || !r->texture || r->samples > 1 || r->tex_type == WMTTextureType3D) return;
    mad_mip_dims(r, v->level, &w, &h, &d);
    if (options == 2) bytes = 1;                                              /* stencil aspect */
    else if (r->is_depth) { bytes = r->tex_pf == WMTPixelFormatDepth16Unorm ? 2 : 4; options = r->has_stencil ? 1 : 0; }
    else { mad_format_info(r->desc.Format, &bytes, &block); if (!bytes || (block != 1 && block != 4)) return; }
    if (!w || !h) return;
    /* ml1141: block-compressed textures (sampled inputs, never targets) copy out
     * as whole 4x4 blocks: bytes is per BLOCK there. */
    bpr = (UINT64)((w + block - 1) / block) * bytes; total = bpr * ((h + block - 1) / block);
    {   /* ml1140: big atlases (Lumen surface cache, shadow maps: 4096^2 at 16-64 MB
         * each) ate the whole budget in the first capture of a UE5 frame, so the
         * G-buffer, lighting and final image were never written. Skip targets over
         * 16 MB unless madeira.cfg capture-big = 1. */
        static int big = -1; static unsigned said_big;
        if (big < 0) big = mad_cfg_int_pe("capture-big", 0) ? 1 : 0;
        if (!big && total > (16ull << 20)) {
            if (said_big++ < 8) d3d12_log("[capture] ml1140 skipped a %ux%u target (%llu MB) at enc#%u; set capture-big = 1 to include atlases\n",
                                          w, h, (unsigned long long)(total >> 20), seq);
            return;
        }
    }
    if (g_cap_bytes + total > MAD_CAPTURE_BUDGET) {
        if (!said_budget++) d3d12_log("[capture] budget of %llu MB reached at enc#%u; later targets of this frame are not captured\n",
                                      (unsigned long long)(MAD_CAPTURE_BUDGET >> 20), seq);
        return;
    }
    memset(&bi, 0, sizeof bi); bi.length = total; bi.options = WMTResourceStorageModeShared;
    buf = MTLDevice_newBuffer(e->q->device->mtl_device, &bi);
    if (!buf || !bi.memory.ptr) { if (buf) NSObject_release(buf); return; }
    memset(&k, 0, sizeof k);
    k.type = WMTBlitCommandCopyFromTextureToBuffer;
    k.src = r->texture; k.slice = v->slice; k.level = v->level;
    k.size.width = w; k.size.height = h; k.size.depth = 1;
    k.dst = buf; k.offset = 0; k.bytes_per_row = (UINT32)bpr; k.bytes_per_image = (UINT32)total; k.options = options;
    MTLBlitCommandEncoder_encodeCommands(benc, (const struct wmtcmd_base *)&k);
    if (!mad_grow((void **)&g_capbufs, &g_capbufs_cap, g_ncapbufs + 1, sizeof *g_capbufs)) { NSObject_release(buf); return; }
    cb = &g_capbufs[g_ncapbufs++];
    memset(cb, 0, sizeof *cb);
    cb->buf = buf; cb->cpu = bi.memory.ptr; cb->bytes = total; cb->w = w; cb->h = h; cb->bpr = (UINT)bpr;
    cb->pf = options == 2 ? (UINT)WMTPixelFormatStencil8 : (r->is_depth ? (UINT)WMTPixelFormatDepth32Float : (UINT)r->tex_pf);
    cb->dxgi = (UINT)r->desc.Format; cb->enc = seq; cb->idx = idx;
    snprintf(cb->kind, sizeof cb->kind, "%s", kind);
    { const char *n = r->name ? r->name : "res"; unsigned i; for (i = 0; i < sizeof cb->name - 1 && n[i]; i++) cb->name[i] = isalnum((unsigned char)n[i]) ? n[i] : '_'; cb->name[i] = 0; }
    g_cap_bytes += total;
}
static void mad_capture_pass(struct mad_exec *e, struct mad_resource **rt, unsigned nrt, const struct mad_rtvp *rtp,
                             struct mad_resource *depth, const struct mad_rtvp *dp, unsigned seq) {
    obj_handle_t benc = MTLCommandBuffer_blitCommandEncoder(e->cb); unsigned i;
    if (!benc) return;
    g_enc_seq++;
    exec_fence_blit(e, benc, 0);
    for (i = 0; i < nrt && i < 8; i++) mad_capture_one(e, benc, rt[i], &rtp[i], seq, i, "rt", 0);
    if (depth) {
        mad_capture_one(e, benc, depth, dp, seq, 8, "depth", 0);
        if (depth->has_stencil) mad_capture_one(e, benc, depth, dp, seq, 9, "stencil", 2);
    }
    exec_fence_blit(e, benc, 1);
    MTLCommandEncoder_endEncoding(benc);
}
static void mad_device_flush_all(struct mad_device *d);
static void mad_capture_finish(struct mad_device *d, UINT64 frame) {
    unsigned i, ok = 0; UINT64 mb = g_cap_bytes >> 20;
    mad_device_flush_all(d);
    if (d->gpu_event) MTLSharedEvent_waitUntilSignaledValue(d->gpu_event, (UINT64)d->gpu_serial_committed, 10000);
    for (i = 0; i < g_ncapbufs; i++) {
        struct mad_capbuf *c = &g_capbufs[i]; struct madeira_ctl_args a;
        memset(&a, 0, sizeof a);
        a.op = 1; a.ptr = (UINT64)(ULONG_PTR)c->cpu; a.len = c->bytes;
        snprintf(a.name, sizeof a.name, "f%llu_e%05u_%s%u_%ux%u_pf%u_dx%u_%s.raw", (unsigned long long)frame, c->enc, c->kind, c->idx, c->w, c->h, c->pf, c->dxgi, c->name);
        MadeiraCtl(&a);
        ok += a.ret ? 1 : 0;
        d3d12_log("[capture] %s %s (%llu bytes, bpr %u)\n", a.ret ? "wrote" : "FAILED", a.name, (unsigned long long)c->bytes, c->bpr);
        NSObject_release(c->buf);
    }
    d3d12_log("[capture] frame %llu complete: %u of %u files written, %llu MB, in Documents/capture/\n", (unsigned long long)frame, ok, g_ncapbufs, (unsigned long long)mb);
    g_ncapbufs = 0; g_cap_bytes = 0;
}
/* ml1098: a madeira.cfg integer, through the bridge (the PE has no sandbox path). */
static int mad_cfg_str_pe(const char *key, char *out, size_t cap) {   /* ml1106 */
    struct madeira_ctl_args a;
    memset(&a, 0, sizeof a); a.op = 2; a.ptr = (UINT64)(ULONG_PTR)out; a.len = cap;
    snprintf(a.name, sizeof a.name, "%s", key);
    if (cap) out[0] = 0;
    MadeiraCtl(&a);
    return a.ret ? 1 : 0;
}
/* ml1106: a slice of a buffer into a capture record (kinds vb / ib / iargs). */
static void mad_capture_buffer(struct mad_exec *e, obj_handle_t benc, struct mad_resource *r, UINT64 off, UINT64 max,
                               const char *kind, unsigned idx, unsigned seq) {
    UINT64 len = r->size > off ? r->size - off : 0; obj_handle_t buf; struct WMTBufferInfo bi; struct wmtcmd_blit_copy_from_buffer_to_buffer k; struct mad_capbuf *cb;
    if (!r->buffer || !len) return;
    if (len > max) len = max;
    memset(&bi, 0, sizeof bi); bi.length = len; bi.options = WMTResourceStorageModeShared;
    buf = MTLDevice_newBuffer(e->q->device->mtl_device, &bi);
    if (!buf || !bi.memory.ptr) { if (buf) NSObject_release(buf); return; }
    memset(&k, 0, sizeof k); k.type = WMTBlitCommandCopyFromBufferToBuffer;
    k.src = r->buffer; k.src_offset = off; k.dst = buf; k.dst_offset = 0; k.copy_length = len;
    MTLBlitCommandEncoder_encodeCommands(benc, (const struct wmtcmd_base *)&k);
    if (!mad_grow((void **)&g_capbufs, &g_capbufs_cap, g_ncapbufs + 1, sizeof *g_capbufs)) { NSObject_release(buf); return; }
    cb = &g_capbufs[g_ncapbufs++]; memset(cb, 0, sizeof *cb);
    cb->buf = buf; cb->cpu = bi.memory.ptr; cb->bytes = len; cb->w = (UINT)len; cb->h = 1; cb->bpr = (UINT)len; cb->enc = seq; cb->idx = idx;
    snprintf(cb->kind, sizeof cb->kind, "%s", kind);
    { const char *n = r->name ? r->name : "buf"; unsigned i; for (i = 0; i < sizeof cb->name - 1 && n[i]; i++) cb->name[i] = isalnum((unsigned char)n[i]) ? n[i] : '_'; cb->name[i] = 0; }
    g_cap_bytes += len;
    d3d12_log("[capture-draw] %s%u <- %s off=%llu len=%llu (resource %llu bytes, gpu 0x%llx)\n", kind, idx, cb->name,
              (unsigned long long)off, (unsigned long long)len, (unsigned long long)r->size, (unsigned long long)r->gpu_address);
}
static struct mad_resource *mad_texture_of_view(struct mad_device *d, UINT64 id, int *xv);
static struct mad_resource *mad_resolve_address(struct mad_device *d, UINT64 addr, UINT64 *off);
static int mad_air_resolve(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root,
                           const UINT32 (*consts)[64], const struct madeira_ir_air_range *rg,
                           unsigned vis_mask, struct mad_descriptor *desc, UINT64 *direct_va, const char **why);
/* ml1106: everything the matched draw will read, copied out BEFORE it runs
 * (after its producers: the blit is in the fence chain). */
static void mad_capture_draw_inputs(struct mad_exec *e, const struct mad_cmd *c) {
    obj_handle_t benc; unsigned k, seq = e->renc_seq; struct mad_rtvp v0; static unsigned said_tex;
    exec_end(e);
    benc = MTLCommandBuffer_blitCommandEncoder(e->cb); if (!benc) return;
    g_enc_seq++;
    exec_fence_blit(e, benc, 0);
    memset(&v0, 0, sizeof v0); v0.layers = 1;
    d3d12_log("[capture-draw] ml1106 ===== draw with ps='%s' vs='%s' after enc#%u: kind=%d topo=%u inputs follow =====\n",
              e->pso->ps_name, e->pso->vs_name, seq, (int)c->kind, (unsigned)e->topo);
    for (k = 0; k < 16; k++) if (e->vb[k].res) mad_capture_buffer(e, benc, e->vb[k].res, e->vb[k].off, 65536, "vb", k, seq);
    if (e->ib) mad_capture_buffer(e, benc, e->ib, e->ib_off, 65536, "ib", 0, seq);
    if ((c->kind == MC_DRAW_INDIRECT || c->kind == MC_DRAW_INDEXED_INDIRECT) && c->u.ind.args)
        mad_capture_buffer(e, benc, c->u.ind.args, c->u.ind.off, 64, "iargs", 0, seq);
    for (k = 0; k < e->pso->ps_nair; k++) {
        const struct madeira_ir_air_range *rg = &e->pso->ps_air[k]; struct mad_descriptor de; UINT64 direct = 0; const char *why = "?";
        struct mad_resource *r; int xv = -1;
        if (rg->type != MADEIRA_IR_AIR_SRV && rg->type != MADEIRA_IR_AIR_CBV) continue;
        if (!mad_air_resolve(e, e->rs, e->root, (const UINT32 (*)[64])e->consts, rg, ~0u, &de, &direct, &why)) continue;
        if (rg->type == MADEIRA_IR_AIR_CBV || !(rg->flags & MADEIRA_IR_AIR_F_TEXTURE) || (de.metadata & (1ull << 63))) {
            /* ml1107: constant buffers and buffer SRVs (raw / structured / typed):
             * the first 4 KB from the descriptor's address, as kind cb / buf. */
            UINT64 va = direct ? direct : de.gpu_va, boff = 0; struct mad_resource *br;
            if (!va) continue;
            br = mad_resolve_address(e->q->device, va, &boff);
            if (!br || !br->buffer) { d3d12_log("[capture-draw] %s%u va=0x%llx resolves to no live buffer\n", rg->type == MADEIRA_IR_AIR_CBV ? "b" : "t", rg->lower_bound, (unsigned long long)va); continue; }
            mad_capture_buffer(e, benc, br, boff, 4096, rg->type == MADEIRA_IR_AIR_CBV ? "cb" : "buf", rg->lower_bound, seq);
            continue;
        }
        r = mad_texture_of_view(e->q->device, de.texture_view_id, &xv);
        if (!r || !r->texture) continue;
        d3d12_log("[capture-draw] t%u -> view %llu = %s %ux%u pf%u dx%u mips %u layers %u (subview %d)\n", rg->lower_bound,
                  (unsigned long long)de.texture_view_id, r->name ? r->name : "?", r->width, r->height, (unsigned)r->tex_pf, (unsigned)r->desc.Format, r->tex_mips, r->tex_layers, xv);
        if (said_tex++ < 64) mad_capture_one(e, benc, r, &v0, seq, 100 + rg->lower_bound, "tex", 0);
    }
    exec_fence_blit(e, benc, 1);
    MTLCommandEncoder_endEncoding(benc);
}
/* ml1141: everything a matched DISPATCH will read, logged range by range from
 * the root signature and copied out BEFORE it runs. Converter (DXIL) pipelines
 * only: the sm5 backend's tables are logged by mad_air_build_tables. */
static void mad_capture_dispatch_inputs(struct mad_exec *e, const struct mad_cmd *c) {
    struct mad_device *d = e->q->device; const struct mad_rootsig *rs = e->crs;
    static struct mad_resource *seen[96]; static unsigned nseen; static UINT64 seen_frame;
    obj_handle_t benc; unsigned i, k, ri, seq; char line[1024]; int n;
    static const char *const rt_name[4] = { "SRV", "UAV", "CBV", "SMP" };
    if (!rs) return;
    if (seen_frame != g_capture_frame) { seen_frame = g_capture_frame; nseen = 0; }
    exec_end(e);
    benc = MTLCommandBuffer_blitCommandEncoder(e->cb); if (!benc) return;
    seq = ++g_enc_seq;
    exec_fence_blit(e, benc, 0);
    d3d12_log("[capture-cs] ml1141 ===== '%s' #%d list#%u enc#%u %s %ux%ux%u, %u root params =====\n", e->cpso->vs_name, g_capture_cs_shots,
              g_list_seq, seq, c->kind == MC_DISPATCH_INDIRECT ? "indirect" : "direct",
              c->kind == MC_DISPATCH ? c->u.dispatch.x : 0, c->kind == MC_DISPATCH ? c->u.dispatch.y : 0, c->kind == MC_DISPATCH ? c->u.dispatch.z : 0,
              (unsigned)rs->nparams);
    if (c->kind == MC_DISPATCH_INDIRECT && c->u.ind.args) mad_capture_buffer(e, benc, c->u.ind.args, c->u.ind.off, 12, "iargs", 0, seq);
    for (i = 0; i < rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        const struct madeira_ir_root_param *p = &rs->params[i]; UINT64 va = e->croot[i];
        if (p->type == MADEIRA_IR_PARAM_CONSTANTS) {
            n = snprintf(line, sizeof line, "[capture-cs] p%u: %u root constants (b%u space%u):", i, p->num_constants, p->shader_register, p->register_space);
            for (k = 0; k < p->num_constants && k < 16; k++) n += snprintf(line + n, sizeof line - n, " %08x", e->cconsts[i][k]);
            d3d12_log("%s\n", line);
            continue;
        }
        if (p->type != MADEIRA_IR_PARAM_TABLE) {   /* root CBV / SRV / UAV: a GPU address */
            UINT64 off = 0; struct mad_resource *r = va ? mad_resolve_address(d, va, &off) : NULL;
            d3d12_log("[capture-cs] p%u: root %s r%u space%u va=0x%llx -> %s size %llu +%llu\n", i,
                      p->type == MADEIRA_IR_PARAM_CBV ? "CBV" : p->type == MADEIRA_IR_PARAM_SRV ? "SRV" : "UAV", p->shader_register, p->register_space,
                      (unsigned long long)va, r ? (r->name ? r->name : "buffer") : "NOTHING LIVE", r ? (unsigned long long)r->size : 0ull, (unsigned long long)off);
            if (r && r->buffer && p->type == MADEIRA_IR_PARAM_CBV) mad_capture_buffer(e, benc, r, off, 1024, "cb", i, seq);
            continue;
        }
        {   /* descriptor table: which heap, then every range */
            const struct mad_heap *h = NULL; unsigned base, run = 0;
            if (e->srv && va >= e->srv->gpu_address && va < e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) h = e->srv;
            else if (e->smp && va >= e->smp->gpu_address && va < e->smp->gpu_address + (UINT64)e->smp->count * sizeof(struct mad_descriptor)) h = e->smp;
            if (!h || !h->cpu) { d3d12_log("[capture-cs] p%u: table va=0x%llx is in no bound heap\n", i, (unsigned long long)va); continue; }
            base = (unsigned)((va - h->gpu_address) / sizeof(struct mad_descriptor));
            for (ri = 0; ri < p->num_ranges; ri++) {
                const struct madeira_ir_root_range *rg; unsigned nd, off;
                if (p->first_range + ri >= rs->nranges) break;
                rg = &rs->ranges[p->first_range + ri];
                nd = rg->num_descriptors; if (nd == 0xffffffffu || nd > 64) nd = 64;
                off = rg->table_offset != 0xffffffffu ? rg->table_offset : run;
                run = off + nd;
                for (k = 0; k < nd && base + off + k < h->count; k++) {
                    const struct mad_descriptor *de = &h->cpu[base + off + k];
                    unsigned reg = rg->base_register + k;
                    const char *rn = rt_name[rg->range_type & 3];
                    if (rg->range_type == MADEIRA_IR_RANGE_SAMPLER) {
                        float bias; UINT32 bb = (UINT32)de->metadata; memcpy(&bias, &bb, sizeof bias);
                        if (de->gpu_va) d3d12_log("[capture-cs] p%u %s s%u space%u: sampler, LOD bias %.3f\n", i, rn, reg, rg->register_space, bias);
                        continue;
                    }
                    if (de->texture_view_id && !(de->metadata >> 63)) {
                        int xv = -1; struct mad_resource *r = mad_texture_of_view(d, de->texture_view_id, &xv);
                        unsigned l0 = 0, nl, s0 = 0, u;
                        if (!r) { d3d12_log("[capture-cs] p%u %s %c%u space%u: texture view %llx NOT FOUND\n", i, rn, rg->range_type == 1 ? 'u' : 't', reg, rg->register_space, (unsigned long long)de->texture_view_id); continue; }
                        nl = r->tex_mips;
                        if (xv >= 0) { l0 = r->xview[xv].lvl0; nl = r->xview[xv].nlvl; s0 = r->xview[xv].sl0; }
                        d3d12_log("[capture-cs] p%u %s %c%u space%u: %s %ux%u x%u type%u pf%u dx%u, %u mips, view mips %u+%u slice %u\n", i, rn,
                                  rg->range_type == 1 ? 'u' : 't', reg, rg->register_space, r->name ? r->name : "?", r->width, r->height,
                                  r->tex_layers, (unsigned)r->tex_type, (unsigned)r->tex_pf, (unsigned)r->desc.Format, r->tex_mips, l0, nl, s0);
                        if (rg->range_type != MADEIRA_IR_RANGE_SRV) continue;
                        for (u = 0; u < nseen; u++) if (seen[u] == r) break;
                        if (u < nseen || nseen >= 96) continue;
                        seen[nseen++] = r;
                        { struct mad_rtvp v; memset(&v, 0, sizeof v); v.level = (UINT16)l0; v.slice = (UINT16)s0; v.layers = 1;
                          mad_capture_one(e, benc, r, &v, seq, i * 1000 + off + k, "tex", 0); }
                    } else if (de->gpu_va) {
                        UINT64 boff = 0; struct mad_resource *br = mad_resolve_address(d, de->gpu_va, &boff);
                        d3d12_log("[capture-cs] p%u %s %c%u space%u: buffer %s size %llu +%llu, metadata 0x%llx%s\n", i, rn,
                                  rg->range_type == 1 ? 'u' : rg->range_type == 2 ? 'b' : 't', reg, rg->register_space,
                                  br ? (br->name ? br->name : "buffer") : "NOTHING LIVE", br ? (unsigned long long)br->size : 0ull,
                                  (unsigned long long)boff, (unsigned long long)de->metadata, (de->metadata >> 63) ? " (typed)" : "");
                        if (br && br->buffer && rg->range_type == MADEIRA_IR_RANGE_CBV) mad_capture_buffer(e, benc, br, boff, 1024, "cb", i * 1000 + off + k, seq);
                    } else if (de->texture_view_id) {
                        d3d12_log("[capture-cs] p%u %s %c%u space%u: typed buffer view %llx, metadata 0x%llx\n", i, rn, rg->range_type == 1 ? 'u' : 't',
                                  reg, rg->register_space, (unsigned long long)de->texture_view_id, (unsigned long long)de->metadata);
                    }
                }
            }
        }
    }
    exec_fence_blit(e, benc, 1);
    MTLCommandEncoder_endEncoding(benc);
}
static long long mad_cfg_int_pe(const char *key, long long dflt) {
    struct madeira_ctl_args a; char v[64];
    memset(&a, 0, sizeof a); a.op = 2; a.ptr = (UINT64)(ULONG_PTR)v; a.len = sizeof v;
    snprintf(a.name, sizeof a.name, "%s", key);
    MadeiraCtl(&a);
    return (a.ret && v[0]) ? _strtoi64(v, NULL, 0) : dflt;
}
static int mad_upload_swap_on(void) {   /* ml1154: madeira.cfg upload-swap (default 1) */
    static int on = -1;
    if (on < 0) { on = mad_cfg_int_pe("upload-swap", 1) ? 1 : 0;
                  d3d12_log("[madeira-d3d12] ml1154 upload-swap = %d (%s)\n", on, on ? "CPU-visible buffers >= 8 MB live on file-backed storage, off the jetsam footprint" : "Metal-owned storage"); }
    return on;
}

static int mad_rtvp_eq(const struct mad_rtvp *a, const struct mad_rtvp *b) {
    return a->level == b->level && a->slice == b->slice && a->layers == b->layers && a->plane == b->plane;
}
static int exec_pending_index(struct mad_exec *e, struct mad_resource *r, const struct mad_rtvp *v) {
    unsigned i;
    for (i = 0; i < e->npend; i++) if (e->pend[i].res == r && mad_rtvp_eq(&e->pend[i].v, v)) return (int)i;
    return -1;
}
/* ml925: one attachment of a pass: mip level, array slice or 3D plane. */
static void mad_attach_view(struct WMTColorAttachmentInfo *a, const struct mad_resource *r, const struct mad_rtvp *v) {
    a->level = v->level;
    if (r->tex_type == WMTTextureType3D) { a->slice = 0; a->depth_plane = v->plane; }
    else { a->slice = v->slice; a->depth_plane = 0; }
}
static void exec_drop_pending(struct mad_exec *e, int i) {
    if (i < 0) return;
    e->pend[i] = e->pend[--e->npend];
}

/* A clear whose target is not part of the next pass still has to happen: it
 * gets a pass of its own with nothing drawn. */
static void exec_flush_clear(struct mad_exec *e, int i) {
    struct WMTRenderPassInfo rpi;
    obj_handle_t enc;
    if (i < 0 || !e->pend[i].res || !e->pend[i].res->texture) { exec_drop_pending(e, i); return; }
    if (e->renc) InterlockedIncrement(&g_pass_end_clear);
    InterlockedIncrement(&g_pass_clear_only);
    exec_end(e);
    memset(&rpi, 0, sizeof rpi);
    if (e->pend[i].v.layers > 1) rpi.render_target_array_length = e->pend[i].v.layers;   /* ml925 */
    if (e->pend[i].is_depth) {
        UINT8 cf = e->pend[i].flags;   /* ml904 */
        rpi.depth.texture = e->pend[i].res->texture;
        rpi.depth.level = e->pend[i].v.level; rpi.depth.slice = e->pend[i].v.slice;
        rpi.stencil.level = e->pend[i].v.level; rpi.stencil.slice = e->pend[i].v.slice;
        rpi.depth.load_action = (cf & D3D12_CLEAR_FLAG_DEPTH) ? WMTLoadActionClear : WMTLoadActionLoad; rpi.depth.store_action = WMTStoreActionStore;
        rpi.depth.clear_depth = e->pend[i].depth;
        if (e->pend[i].res->has_stencil) {
            rpi.stencil.texture = e->pend[i].res->texture;
            rpi.stencil.load_action = (cf & D3D12_CLEAR_FLAG_STENCIL) ? WMTLoadActionClear : WMTLoadActionLoad; rpi.stencil.store_action = WMTStoreActionStore;
            rpi.stencil.clear_stencil = e->pend[i].stencil;
        }
    } else {
        rpi.colors[0].texture = e->pend[i].res->texture;
        mad_attach_view(&rpi.colors[0], e->pend[i].res, &e->pend[i].v);
        rpi.colors[0].load_action = WMTLoadActionClear; rpi.colors[0].store_action = WMTStoreActionStore;
        rpi.colors[0].clear_color.r = e->pend[i].rgba[0]; rpi.colors[0].clear_color.g = e->pend[i].rgba[1];
        rpi.colors[0].clear_color.b = e->pend[i].rgba[2]; rpi.colors[0].clear_color.a = e->pend[i].rgba[3];
    }
    rpi.render_target_width = e->pend[i].res->width >> e->pend[i].v.level;
    rpi.render_target_height = e->pend[i].res->height >> e->pend[i].v.level;
    if (!rpi.render_target_width) rpi.render_target_width = 1; if (!rpi.render_target_height) rpi.render_target_height = 1;
    rpi.default_raster_sample_count = e->pend[i].res->samples ? e->pend[i].res->samples : 1;
    enc = MTLCommandBuffer_renderCommandEncoder(e->cb, &rpi); if (enc) g_enc_seq++;
    e->f6_att[0] = e->pend[i].res; e->f6_natt = 1;   /* ml1134 */
    if (enc) { exec_fence_render(e, enc, 0); exec_fence_render(e, enc, 1); }   /* ml1091: a clear pass writes its target; keep it in the chain */
    e->f6_natt = 0;
    if (enc) MTLCommandEncoder_endEncoding(enc);
    exec_drop_pending(e, i);
}

static void exec_add_clear(struct mad_exec *e, struct mad_resource *r, const struct mad_rtvp *v, const float *rgba, float depth, int is_depth, UINT8 stencil, UINT8 flags) {
    int i;
    if (!r) return;
    /* A clear ends the pass in progress so the next one can load it as a
     * clear; a clear mid-pass would otherwise be lost. */
    if (e->renc) { InterlockedIncrement(&g_pass_end_clear); exec_end(e); }
    i = exec_pending_index(e, r, v);
    if (i >= 0 && is_depth && e->pend[i].is_depth && e->pend[i].flags) {
        /* ml904: a second clear of the other aspect merges; the values of the
         * aspects actually named are the ones that count. ml908: only an entry
         * that is STILL PENDING merges. The slot a dropped entry vacates keeps
         * its old bytes, so a fresh entry landing there used to inherit the
         * previous clear's flags -- a stencil-only clear after a consumed
         * depth+stencil clear became a depth clear too, which is exactly the
         * UE5 pre-pass -> stencil clear -> base pass shape (vfetch case 5c). */
        if (flags & D3D12_CLEAR_FLAG_DEPTH) e->pend[i].depth = depth;
        if (flags & D3D12_CLEAR_FLAG_STENCIL) e->pend[i].stencil = stencil;
        e->pend[i].flags |= flags;
        return;
    }
    if (i < 0) {
        if (e->npend == 16) exec_flush_clear(e, 0);
        i = (int)e->npend++;
    }
    e->pend[i].res = r; e->pend[i].v = *v; e->pend[i].is_depth = is_depth; e->pend[i].depth = depth; e->pend[i].stencil = stencil;
    e->pend[i].flags = is_depth ? flags : 0;
    if (rgba) memcpy(e->pend[i].rgba, rgba, sizeof e->pend[i].rgba); else memset(e->pend[i].rgba, 0, sizeof e->pend[i].rgba);
}

/* The rasterisation area of a pass with no attachments: nothing else can
 * supply it, so it comes from the viewport the command list has set. */
static void exec_attachless_area(const struct mad_exec *e, UINT *w, UINT *h) {
    *w = (UINT)(e->vp.TopLeftX + e->vp.Width);
    *h = (UINT)(e->vp.TopLeftY + e->vp.Height);
}

static obj_handle_t mad_vis_chunk(struct mad_exec *e, struct mad_vis_batch *v, UINT64 slot, void **cpu_out);
static int exec_same_targets(struct mad_exec *e) {
    UINT i;
    if (!e->renc || e->enc_nrt != e->nrt || e->enc_depth != e->depth) return 0;
    if (e->q->vis) {   /* ml1088: a chunk boundary crossed mid-pass forces a new pass (once per 8192 slots) */
        obj_handle_t want = mad_vis_chunk(e, e->q->vis, e->q->vis->next, NULL);
        if (want != e->enc_vis_buf) { InterlockedIncrement(&g_vis_restarts); return 0; }
    }
    /* ml934b: with no attachments there is nothing in the loops below to
     * compare, so every attachment-less pass looked identical to every other
     * one and they shared a single encoder -- the second pass then rasterised
     * into the first one's area. UE runs these back to back at wildly
     * different sizes (Nanite raster at 736x416, shadow object culling at
     * 12288x2048), so the area has to be part of the comparison. */
    if (!e->nrt && !e->depth) {
        UINT w, h; exec_attachless_area(e, &w, &h);
        if (w != e->enc_w || h != e->enc_h) return 0;
    }
    for (i = 0; i < e->nrt; i++) if (e->enc_rt[i] != e->rt[i] || !mad_rtvp_eq(&e->enc_rtp[i], &e->rtp[i])) return 0;
    if (e->depth && !mad_rtvp_eq(&e->enc_dp, &e->dp)) return 0;
    return 1;
}

static unsigned g_said_attachless;
/* ml1142: madeira.cfg encoder-labels = 1 names every Metal encoder after the
 * pass that opened it ("R#<seq> <vs>|<ps>", "C#<seq> <kernel>", "B#<seq> copy"),
 * so Instruments' Metal System Trace attributes GPU time per pass. Off by
 * default: one NSString per encoder is not free. */
static int g_enc_labels = -1;
static void mad_label(obj_handle_t enc, const char *fmt, ...) {
    char s[128]; va_list ap; obj_handle_t str;
    if (g_enc_labels < 0) g_enc_labels = mad_cfg_int_pe("encoder-labels", 0) ? 1 : 0;
    if (!enc || !g_enc_labels) return;
    va_start(ap, fmt); vsnprintf(s, sizeof s, fmt, ap); va_end(ap);
    str = NSString_alloc_init(s, WMTUTF8StringEncoding);
    if (str) { MTLCommandEncoder_setLabel(enc, str); NSObject_release(str); }
}
static int exec_begin_render(struct mad_exec *e) {
    struct WMTRenderPassInfo rpi;
    UINT i, w = 0, h = 0;
    unsigned k;
    int attachless = 0;
    if (exec_same_targets(e)) { InterlockedIncrement(&g_pass_reused); return 1; }
    if (e->renc) InterlockedIncrement(&g_pass_end_rts);
    e->f7_next_rts = 1;   /* ml1137: the pass being closed hands over to the targets bound now */
    exec_end(e);
    /* ml934: a render pass with NO colour target AND no depth is legal in
     * D3D12, and it is exactly what Nanite's hardware rasteriser uses: it
     * rasterises into UAVs -- the 64-bit-atomic visibility buffer -- and binds
     * neither a render target nor a depth buffer. Refusing an encoder here
     * dropped every one of those draws, and dropped them without counting them
     * as "skipped", so nothing in the log named it; on screen it was
     * cluster-shaped holes with the sky showing through. Metal renders
     * attachment-less passes too, but nothing can infer the render area, so it
     * comes from the viewport the list has already set. */
    if (!e->nrt && !e->depth) {
        exec_attachless_area(e, &w, &h);
        if (!w || !h) return 0;
        attachless = 1;
    }
    /* Pending clears for targets outside this pass go first, on their own. */
    for (k = 0; k < e->npend; ) {
        int bound = (e->pend[k].res == e->depth && mad_rtvp_eq(&e->pend[k].v, &e->dp));
        for (i = 0; i < e->nrt && !bound; i++) if (e->rt[i] == e->pend[k].res && mad_rtvp_eq(&e->pend[k].v, &e->rtp[i])) bound = 1;
        if (!bound) exec_flush_clear(e, (int)k); else k++;
    }
    memset(&rpi, 0, sizeof rpi);
    for (i = 0; i < e->nrt; i++) exec_note_write(e, e->rt[i]);   /* ml1116 */
    exec_note_write(e, e->depth);
    for (i = 0; i < e->nrt; i++) {
        struct mad_resource *r = e->rt[i];
        int p;
        if (!r || !r->texture) continue;
        p = exec_pending_index(e, r, &e->rtp[i]);
        rpi.colors[i].texture = r->texture;
        mad_attach_view(&rpi.colors[i], r, &e->rtp[i]);   /* ml925 */
        if (e->rtp[i].layers > 1 && e->rtp[i].layers > rpi.render_target_array_length) rpi.render_target_array_length = e->rtp[i].layers;
        rpi.colors[i].load_action = p >= 0 ? WMTLoadActionClear : WMTLoadActionLoad;
        rpi.colors[i].store_action = WMTStoreActionStore;
        if (p >= 0) {
            rpi.colors[i].clear_color.r = e->pend[p].rgba[0]; rpi.colors[i].clear_color.g = e->pend[p].rgba[1];
            rpi.colors[i].clear_color.b = e->pend[p].rgba[2]; rpi.colors[i].clear_color.a = e->pend[p].rgba[3];
            exec_drop_pending(e, p);
        }
        if (!w) { w = r->width >> e->rtp[i].level; h = r->height >> e->rtp[i].level; }
    }
    if (e->depth && e->depth->texture) {
        int p = exec_pending_index(e, e->depth, &e->dp);
        UINT8 cf = p >= 0 ? e->pend[p].flags : 0;   /* ml904: which aspects the clear named */
        rpi.depth.texture = e->depth->texture;
        rpi.depth.level = e->dp.level; rpi.depth.slice = e->dp.slice;                /* ml925 */
        rpi.stencil.level = e->dp.level; rpi.stencil.slice = e->dp.slice;
        if (e->dp.layers > 1 && e->dp.layers > rpi.render_target_array_length) rpi.render_target_array_length = e->dp.layers;
        rpi.depth.load_action = (cf & D3D12_CLEAR_FLAG_DEPTH) ? WMTLoadActionClear : WMTLoadActionLoad;
        rpi.depth.store_action = WMTStoreActionStore;
        if (e->depth->has_stencil) {
            rpi.stencil.texture = e->depth->texture;
            rpi.stencil.load_action = (cf & D3D12_CLEAR_FLAG_STENCIL) ? WMTLoadActionClear : WMTLoadActionLoad;
            rpi.stencil.store_action = WMTStoreActionStore;
            if (p >= 0) rpi.stencil.clear_stencil = e->pend[p].stencil;
        }
        if (p >= 0) { rpi.depth.clear_depth = e->pend[p].depth; exec_drop_pending(e, p); }
        if (!w) { w = e->depth->width >> e->dp.level; h = e->depth->height >> e->dp.level; }
    }
    if (!w) w = 1; if (!h) h = 1;
    rpi.render_target_width = w; rpi.render_target_height = h;
    rpi.default_raster_sample_count = (e->nrt && e->rt[0] && e->rt[0]->samples) ? e->rt[0]->samples
                                    : (e->depth && e->depth->samples) ? e->depth->samples : 1;
    e->enc_vis_buf = 0;
    if (e->q->device->has_query_heaps) {   /* ml1088: every pass carries the slot buffer, so a Begin mid-pass costs nothing */
        struct mad_vis_batch *v = mad_vis_get(e);
        if (v) { rpi.visibility_buffer = mad_vis_chunk(e, v, v->next, NULL); e->enc_vis_buf = rpi.visibility_buffer; }
    }
    e->vis_prev = ~(UINT64)0;
    if (g_att_census) {   /* ml1137 */
        for (i = 0; i < e->nrt; i++)
            if (e->rt[i] && e->rt[i]->texture)
                InterlockedExchangeAdd64(rpi.colors[i].load_action == WMTLoadActionClear ? &g_ac_clear : &g_ac_load, f7_att_bytes(e->rt[i], e->rtp[i].level));
        if (e->depth && e->depth->texture)
            InterlockedExchangeAdd64(rpi.depth.load_action == WMTLoadActionClear ? &g_ac_clear : &g_ac_load, f7_att_bytes(e->depth, e->dp.level));
    }
    e->renc = MTLCommandBuffer_renderCommandEncoder(e->cb, &rpi); if (e->renc) e->renc_seq = ++g_enc_seq;
    if (g_enc_labels) mad_label(e->renc, "R#%u %s|%s %ux%u", e->renc_seq, e->pso ? e->pso->vs_name : "-", e->pso ? e->pso->ps_name : "-", w, h);   /* ml1142 */
    e->f6_natt = 0;   /* ml1134: what this pass writes, for the same-attachment ordering rule */
    for (i = 0; i < e->nrt && e->f6_natt < 8; i++) if (e->rt[i]) e->f6_att[e->f6_natt++] = e->rt[i];
    if (e->depth) e->f6_att[e->f6_natt++] = e->depth;
    if (e->renc) exec_fence_render(e, e->renc, 0);   /* ml1091 */
    if (e->renc) {   /* ml1070 */
        LONG64 bytes = 0;
        for (i = 0; i < e->nrt; i++) if (e->rt[i]) bytes += (LONG64)e->rt[i]->width * e->rt[i]->height * 4 * (e->rt[i]->samples ? e->rt[i]->samples : 1);
        if (e->depth) bytes += (LONG64)e->depth->width * e->depth->height * 4;
        InterlockedIncrement(&g_pass_begun);
        InterlockedExchangeAdd64(&g_pass_attach_bytes, bytes * 2);   /* load + store */
    }
    /* ml934c: the host names the encoder a GPU fault happened in, but only the
     * guest knows what went into it, and draw-dump is sampled. Name every
     * attachment-less pass unconditionally: these are the passes the
     * attachment-less change newly enabled, so they are the suspects, and the
     * host's enc# resolves straight to one of these lines. */
    if (attachless && e->renc && g_said_attachless++ < 20000)
        d3d12_log("[attachless] enc#%u %ux%u UAV-only\n", e->renc_seq, w, h);
    if (!e->renc) { d3d12_log("[madeira-d3d12] no render encoder\n"); return 0; }
    e->enc_nrt = e->nrt; memcpy(e->enc_rt, e->rt, sizeof e->rt); e->enc_depth = e->depth;
    e->pass_draws = 0;   /* ml1098 */
    e->enc_w = w; e->enc_h = h;
    memcpy(e->enc_rtp, e->rtp, sizeof e->rtp); e->enc_dp = e->dp;   /* ml925 */
    return 1;
}

static int exec_begin_blit(struct mad_exec *e) {
    if (e->benc) return 1;
    if (e->renc) InterlockedIncrement(&g_pass_end_blit);
    exec_end(e);
    e->benc = MTLCommandBuffer_blitCommandEncoder(e->cb); if (e->benc) g_enc_seq++;
    if (g_enc_labels) mad_label(e->benc, "B#%u copy", g_enc_seq);   /* ml1142 */
    if (e->benc) exec_fence_blit(e, e->benc, 0);   /* ml1091 */
    if (!e->benc) d3d12_log("[madeira-d3d12] no blit encoder\n");
    return e->benc != 0;
}

/* One slot of root values for this draw, from the list's shared chunks. */
static int exec_arg_slot_for(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root,
                             const UINT32 (*consts)[64], obj_handle_t *buf, UINT64 *off, const UINT *ovr, const struct mad_pso *pso);
static int exec_arg_slot(struct mad_exec *e, obj_handle_t *buf, UINT64 *off) {
    return exec_arg_slot_for(e, e->rs, e->root, (const UINT32 (*)[64])e->consts, buf, off,
                             (e->pso && e->pso->has_root_off) ? e->pso->root_off : NULL, e->pso);
}
/* ml1008: take one zeroed slot from the per-list argument ring, handing back
 * the buffer, the offset, a CPU pointer and the slot's GPU address. Factored out
 * of exec_arg_slot_for because the DXBC backend needs two tables per dispatch
 * plus, when root constants are consumed as a constant buffer, GPU-visible
 * storage to point at -- all with the same per-dispatch lifetime the ring
 * already guarantees. */
/* ml1061: ARGUMENT-RING LIFETIME.
 * A list's ring chunks were rewound at ID3D12GraphicsCommandList::Reset on the
 * theory that "the allocator's reset rule says the GPU is done with them". It
 * does not: a LIST may be reset the moment it has been submitted; only the
 * ALLOCATOR must wait for the GPU. The rings are written at replay time and read
 * at GPU time, so re-recording a list rewrote arguments the GPU had not consumed
 * yet. A fully synchronous Signal() hid that (the GPU was always idle by the next
 * frame); an asynchronous one cannot. Chunks now retire with the serial of the
 * batch that used them and return to a device pool once the GPU has passed it. */
static UINT64 mad_gpu_completed(struct mad_device *d) {
    return d->gpu_event ? MTLSharedEvent_signaledValue(d->gpu_event) : ~(UINT64)0;
}
static int mad_ring_chunk_get(struct mad_device *d, struct mad_ringchunk *out) {
    struct WMTBufferInfo bi;
    int got = 0;
    EnterCriticalSection(&d->ring_lock);
    if (!d->nring_pool && d->nring_retired) {
        UINT64 done = mad_gpu_completed(d); unsigned i = 0;
        while (i < d->nring_retired) {
            if (d->ring_retired[i].serial <= done) {
                if (mad_grow((void **)&d->ring_pool, &d->ring_pool_cap, d->nring_pool + 1, sizeof *d->ring_pool))
                    d->ring_pool[d->nring_pool++] = d->ring_retired[i];
                d->ring_retired[i] = d->ring_retired[--d->nring_retired];
            } else i++;
        }
    }
    if (d->nring_pool) { *out = d->ring_pool[--d->nring_pool]; got = 1; }
    LeaveCriticalSection(&d->ring_lock);
    if (got) return 1;
    memset(&bi, 0, sizeof bi);
    bi.length = MAD_ARG_RING_BYTES;
    bi.options = WMTResourceStorageModeShared;
    out->buf = MTLDevice_newBuffer(d->mtl_device, &bi);
    if (!out->buf || !bi.memory.ptr) return 0;
    out->cpu = bi.memory.ptr; out->gpu = bi.gpu_address; out->serial = 0;
    return 1;
}
static void mad_ring_retire(struct mad_device *d, struct mad_list *l, UINT64 serial) {
    unsigned k;
    EnterCriticalSection(&d->ring_lock);
    for (k = 0; k < l->nrings; k++)
        if (mad_grow((void **)&d->ring_retired, &d->ring_retired_cap, d->nring_retired + 1, sizeof *d->ring_retired)) {
            struct mad_ringchunk *c = &d->ring_retired[d->nring_retired++];
            c->buf = l->rings[k]; c->cpu = l->ring_cpu[k]; c->gpu = l->ring_gpu[k]; c->serial = serial;
        } else NSObject_release(l->rings[k]);   /* the command buffer still holds it */
    LeaveCriticalSection(&d->ring_lock);
    l->nrings = 0;
}
static int mad_list_ring_grow(struct mad_exec *e) {
    struct mad_list *l = e->l; struct mad_ringchunk c;
    if (!mad_ring_chunk_get(e->q->device, &c)) return 0;
    l->rings = realloc(l->rings, (l->nrings + 1) * sizeof *l->rings);
    l->ring_cpu = realloc(l->ring_cpu, (l->nrings + 1) * sizeof *l->ring_cpu);
    l->ring_gpu = realloc(l->ring_gpu, (l->nrings + 1) * sizeof *l->ring_gpu);
    l->rings[l->nrings] = c.buf; l->ring_cpu[l->nrings] = c.cpu; l->ring_gpu[l->nrings] = c.gpu; l->nrings++;
    return 1;
}

/* ml1087: n CONSECUTIVE slots (one contiguous table). A table that does not
 * fit the rest of the current chunk starts at the next one; the tail is wasted,
 * never split. Before this a pixel shader with more than 136 qwords of
 * arguments could not be bound at all -- ph-rdr51 skipped 796 draws of one
 * 140-qword shader. */
/* ml1130: zero only the bytes the caller's table occupies. Whole 1088-byte
 * slots were cleared for every table (~6.5 KB per draw, plus an 8 KB useResource
 * array): memset was ~12 % of the submission worker's running samples in the
 * ph-rdr83 profile, and on a power-capped phone the memory traffic costs frames. */
static int exec_ring_take_z(struct mad_exec *e, unsigned n, size_t zero_bytes, obj_handle_t *buf, UINT64 *off, void **cpu, UINT64 *gpu);
static int exec_ring_take_n(struct mad_exec *e, unsigned n, obj_handle_t *buf, UINT64 *off, void **cpu, UINT64 *gpu) {
    return exec_ring_take_z(e, n, (size_t)n * MAD_ARG_SLOT_BYTES, buf, off, cpu, gpu);
}
static int exec_ring_take_z(struct mad_exec *e, unsigned n, size_t zero_bytes, obj_handle_t *buf, UINT64 *off, void **cpu, UINT64 *gpu) {
    struct mad_list *l = e->l;
    const unsigned per = MAD_ARG_RING_BYTES / MAD_ARG_SLOT_BYTES;
    unsigned chunk, slot;
    if (!n || n > per) return 0;
    if ((l->ring_used % per) + n > per) l->ring_used += per - (l->ring_used % per);
    chunk = l->ring_used / per;
    slot = l->ring_used % per;
    if (chunk >= l->nrings && !mad_list_ring_grow(e)) return 0;   /* ml1061: pooled, GPU-lifetime aware */
    *cpu = (unsigned char *)l->ring_cpu[chunk] + (size_t)slot * MAD_ARG_SLOT_BYTES;
    if (zero_bytes > (size_t)n * MAD_ARG_SLOT_BYTES) zero_bytes = (size_t)n * MAD_ARG_SLOT_BYTES;
    if (zero_bytes) memset(*cpu, 0, zero_bytes);
    *buf = l->rings[chunk];
    *off = (UINT64)slot * MAD_ARG_SLOT_BYTES;
    *gpu = l->ring_gpu[chunk];
    l->ring_used += n;
    return 1;
}
static int exec_ring_take(struct mad_exec *e, obj_handle_t *buf, UINT64 *off, void **cpu, UINT64 *gpu) {
    return exec_ring_take_n(e, 1, buf, off, cpu, gpu);
}

static int exec_arg_slot_for(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root,
                             const UINT32 (*consts)[64], obj_handle_t *buf, UINT64 *off, const UINT *ovr, const struct mad_pso *pso) {
    struct mad_list *l = e->l;
    unsigned chunk = l->ring_used / (MAD_ARG_RING_BYTES / MAD_ARG_SLOT_BYTES);
    unsigned slot = l->ring_used % (MAD_ARG_RING_BYTES / MAD_ARG_SLOT_BYTES);
    if (chunk >= l->nrings && !mad_list_ring_grow(e)) return 0;   /* ml1061: pooled, GPU-lifetime aware */
    {
        unsigned char *dst = (unsigned char *)l->ring_cpu[chunk] + slot * MAD_ARG_SLOT_BYTES;
        if (rs) {
            UINT offsets[MAD_ROOT_PARAM_MAX], i, end = 0;
            if (ovr) memcpy(offsets, ovr, sizeof offsets); else mad_root_layout(rs, offsets);
            /* ml1130: clear the root layout plus the draw-param/draw-info block the
             * shaders read (512..576), not the whole 1088-byte slot. The vertex
             * table at 576 is written in full whenever it is bound (ml927). */
            for (i = 0; i < rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
                UINT sz = rs->params[i].type == MADEIRA_IR_PARAM_CONSTANTS
                          ? (rs->params[i].num_constants > 64 ? 64u : rs->params[i].num_constants) * 4u : 8u;
                if (offsets[i] + sz > end) end = offsets[i] + sz;
            }
            if (pso && pso->has_static_off && pso->static_off + 8 > end) end = pso->static_off + 8;
            end = (end + 63u) & ~63u;
            if (end > MAD_ARG_DRAWPARAMS_OFF) memset(dst, 0, MAD_ARG_SLOT_BYTES);
            else { memset(dst, 0, end); memset(dst + MAD_ARG_DRAWPARAMS_OFF, 0, MAD_ARG_VBTABLE_OFF - MAD_ARG_DRAWPARAMS_OFF); }
            for (i = 0; i < rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
                if (rs->params[i].type == MADEIRA_IR_PARAM_CONSTANTS) {
                    UINT n = rs->params[i].num_constants;
                    if (n > 64) n = 64;
                    if (offsets[i] + n * 4 <= MAD_ARG_SLOT_BYTES) memcpy(dst + offsets[i], consts[i], n * 4);
                } else if (offsets[i] + 8 <= MAD_ARG_SLOT_BYTES) {
                    UINT64 v = root[i];
                    if (!v && e->q->device->null_gpu) {
                        static unsigned said_null;
                        v = e->q->device->null_gpu;
                        if (said_null++ < 24)
                            d3d12_log("[madeira-d3d12] root parameter %u (type %u) never set for '%s'; pointing it at zeros\n",
                                      i, (unsigned)rs->params[i].type,
                                      rs == e->crs ? (e->cpso ? e->cpso->vs_name : "?") : (e->pso ? e->pso->vs_name : "?"));
                    }
                    memcpy(dst + offsets[i], &v, 8);
                }
            }
            if (pso && pso->has_static_off && rs->stab_gpu && pso->static_off + 8 <= MAD_ARG_SLOT_BYTES)   /* ml923 */
                memcpy(dst + pso->static_off, &rs->stab_gpu, 8);
        } else {
            memset(dst, 0, MAD_ARG_SLOT_BYTES);   /* ml1130: unchanged for the no-signature case */
            memcpy(dst, root, MAD_ROOT_PARAM_MAX * 8);   /* no signature bound: flat addresses */
        }
    }
    *buf = l->rings[chunk]; *off = (UINT64)slot * MAD_ARG_SLOT_BYTES;
    l->ring_used++;
    return 1;
}

/* ml927: the converter runtime's geometry-emulation draw contract, ported from
 * metal_irconverter_runtime.h (IRRuntimeCalculateDrawInfoForGSEmulation,
 * IRRuntimeCalculateObjectTgCountForTessellationAndGeometryEmulation,
 * IRRuntimeCalculateThreadgroupSizeForGeometry). The object stage runs the
 * vertex shader over `objVertexStride` vertices per threadgroup (+ the strip
 * overlap), the mesh stage runs the geometry shader over `maxPrims` input
 * primitives per threadgroup; both read IRRuntimeDrawInfo at bind point 5 and
 * IRRuntimeDrawParams at bind point 4. */
struct mad_gs_drawinfo {
    UINT16 index_type; UINT8 primitive_topology, threads_per_patch;
    UINT16 max_input_prims, obj_vertex_stride, mesh_prim_stride, gs_instance_count, patches_per_obj_tg, input_cps_per_patch;
    UINT64 index_buffer;
};
static UINT mad_gs_prim(D3D12_PRIMITIVE_TOPOLOGY t) {
    switch (t) {
    case D3D_PRIMITIVE_TOPOLOGY_POINTLIST: return 0;
    case D3D_PRIMITIVE_TOPOLOGY_LINELIST: return 1;
    case D3D_PRIMITIVE_TOPOLOGY_LINESTRIP: return 2;
    case D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: return 4;
    case D3D_PRIMITIVE_TOPOLOGY_LINELIST_ADJ: return 5;
    case D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST_ADJ: return 6;
    case D3D_PRIMITIVE_TOPOLOGY_LINESTRIP_ADJ: return 7;
    default: return 3;
    }
}
static UINT mad_gs_vcount(UINT pt) { static const UINT n[8] = { 1, 2, 2, 3, 3, 4, 6, 4 }; return pt < 8 ? n[pt] : 3; }
static UINT mad_gs_overlap(UINT pt) { return pt == 2 ? 1 : pt == 4 ? 2 : pt == 7 ? 3 : 0; }
static void mad_gs_draw(UINT pt, UINT vertex_size, UINT max_prims, UINT instances, UINT count, UINT16 index_type, UINT64 index_buffer,
                        struct mad_gs_drawinfo *di, struct WMTSize *grid, struct WMTSize *obj_tg, struct WMTSize *mesh_tg) {
    UINT pvc = mad_gs_vcount(pt), align = pvc ? pvc : 1;
    UINT payload_vertex_bytes = 16384u - 32u;
    UINT max_v_by_payload = ((payload_vertex_bytes / (vertex_size ? vertex_size : 1)) / align) * align;
    UINT max_prims_by_amp = 1024u * max_prims;
    UINT max_prims_per_obj = max_v_by_payload / align; if (max_prims_per_obj > max_prims_by_amp) max_prims_per_obj = max_prims_by_amp;
    if (max_prims_per_obj > 256u / align) max_prims_per_obj = 256u / align;
    if (!max_prims_per_obj) max_prims_per_obj = 1;
    memset(di, 0, sizeof *di);
    di->index_type = index_type; di->primitive_topology = (UINT8)pt; di->threads_per_patch = (UINT8)pvc;
    di->max_input_prims = (UINT16)max_prims; di->obj_vertex_stride = (UINT16)(max_prims_per_obj * pvc);
    di->mesh_prim_stride = (UINT16)max_prims; di->gs_instance_count = (UINT16)instances;
    di->patches_per_obj_tg = (UINT16)max_prims_per_obj; di->input_cps_per_patch = (UINT16)pvc; di->index_buffer = index_buffer;
    {
        UINT stride = di->obj_vertex_stride ? di->obj_vertex_stride : 1, ov = mad_gs_overlap(pt);
        UINT n = count > ov ? count - ov : 0;
        grid->width = (n + stride - 1) / stride; grid->height = instances ? instances : 1; grid->depth = 1;
        obj_tg->width = stride + ov; obj_tg->height = 1; obj_tg->depth = 1;
        mesh_tg->width = max_prims ? max_prims : 1; mesh_tg->height = 1; mesh_tg->depth = 1;
    }
}

static enum WMTPrimitiveType mad_prim(D3D12_PRIMITIVE_TOPOLOGY t) {
    switch (t) {
    case D3D_PRIMITIVE_TOPOLOGY_POINTLIST: return WMTPrimitiveTypePoint;
    case D3D_PRIMITIVE_TOPOLOGY_LINELIST: return WMTPrimitiveTypeLine;
    case D3D_PRIMITIVE_TOPOLOGY_LINESTRIP: return WMTPrimitiveTypeLineStrip;
    case D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: return WMTPrimitiveTypeTriangleStrip;
    default: return WMTPrimitiveTypeTriangle;
    }
}


/* ml878: pipeline variant for the strides a draw actually binds. */
static obj_handle_t mad_pso_for_strides(struct mad_pso *p, const UINT strides[16]) {
    unsigned k, i; obj_handle_t err = 0, rps;
    struct WMTVertexDescriptorInfo vd;
    static unsigned said;
    for (i = 0; i < 16; i++) if ((p->vb_mask & (1u << i)) && strides[i] != p->vb_stride[i]) break;
    if (i == 16) return p->rps;                      /* the base pipeline already matches */
    EnterCriticalSection(&p->var_lock);
    for (k = 0; k < p->nvar; k++) if (!memcmp(p->var[k].strides, strides, sizeof p->var[k].strides)) {
        rps = p->var[k].rps; LeaveCriticalSection(&p->var_lock); return rps;
    }
    vd = p->vd;
    for (i = 0; i < 16; i++) if (p->vb_mask & (1u << i)) {
        if (strides[i] == 0) {
            /* ml904: constant step -- one element for every vertex. Metal's
             * MTLVertexStepFunctionConstant (0) with step rate 0; the stride
             * is kept at the packed size so the element's own layout stands. */
            vd.layouts[6 + i].step_function = 0; vd.layouts[6 + i].step_rate = 0;
            vd.layouts[6 + i].stride = p->vb_stride[i];
        } else vd.layouts[6 + i].stride = strides[i];
    }
    rps = MTLDevice_newRenderPipelineStateVD(p->device_handle, &p->rp, &vd, &err);
    if (err) mad_log_nserror("render pipeline (vertex-descriptor variant)", err);
    if (!rps) {
        /* ml904: second try for the constant case with a zero stride, in case
         * this Metal wants the layout that way. */
        int retry = 0;
        for (i = 0; i < 16; i++) if ((p->vb_mask & (1u << i)) && strides[i] == 0) { vd.layouts[6 + i].stride = 0; retry = 1; }
        if (retry) { err = 0; rps = MTLDevice_newRenderPipelineStateVD(p->device_handle, &p->rp, &vd, &err); if (err) mad_log_nserror("render pipeline (retry)", err); }
    }
    if (!rps) {
        if (said++ < 8) d3d12_log("[madeira-d3d12] stride variant failed (slot0 stride %u vs assumed %u, slot1 stride %u); using the base pipeline\n",
                                  strides[0], p->vb_stride[0], strides[1]);
        LeaveCriticalSection(&p->var_lock); return p->rps;
    }
    if (p->nvar < 8) { memcpy(p->var[p->nvar].strides, strides, sizeof p->var[0].strides); p->var[p->nvar].rps = rps; p->nvar++; }
    else { NSObject_release(p->var[0].rps); memmove(&p->var[0], &p->var[1], sizeof p->var[0] * 7);
           memcpy(p->var[7].strides, strides, sizeof p->var[0].strides); p->var[7].rps = rps; }
    if (said < 8) { said++; d3d12_log("[madeira-d3d12] pipeline stride variant built (%u variants cached)\n", p->nvar); }
    LeaveCriticalSection(&p->var_lock);
    return rps;
}

static unsigned g_cap_kinds;   /* ml910: kinds captured since the last flush */
static unsigned g_k9_n;        /* ml929: K9 captures since the last flush */
static struct mad_resource *mad_resolve_address(struct mad_device *d, UINT64 addr, UINT64 *off);
/* ml913: name every table entry that is a buffer descriptor pointing at no
 * live resource (host shader validation reported 8132 "Invalid device load ...
 * out of bounds of user address space" from compute kernels). Census frames
 * only: the resolve walks the live list. */
static void exec_desc_check(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root, const char *who) {
    static unsigned said, checked;
    unsigned i, k;
    if (!rs || !e->srv || !e->srv->cpu || said >= 40 || checked++ > 20000) return;
    for (i = 0; i < rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 va = root[i]; unsigned idx;
        if (rs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
        if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) continue;
        idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
        for (k = 0; k < 16 && idx + k < e->srv->count; k++) {
            const struct mad_descriptor *de = &e->srv->cpu[idx + k];
            UINT64 off = 0;
            if (de->texture_view_id || !de->gpu_va) continue;
            if (!mad_resolve_address(e->q->device, de->gpu_va, &off) && said++ < 40)
                d3d12_log("[desc-check] '%s' table p%u heap[%u]: buffer descriptor va=%llx size=%llu points at NO live resource%s\n",
                          who, i, idx + k, (unsigned long long)de->gpu_va, (unsigned long long)(de->metadata & 0xffffffffu),
                          (e->q->device->null_gpu && de->gpu_va >= e->q->device->null_gpu && de->gpu_va < e->q->device->null_gpu + 65536) ? " (= the runtime's null buffer)" : "");
        }
    }
}
/* ml910: copy `len` bytes of a GPU buffer into the capture ring, GPU-ordered
 * (a blit in this command buffer, before the draw that follows). */
static int exec_capture_bytes(struct mad_exec *e, const char *label, struct mad_resource *r, UINT64 off, UINT len, UINT kind) {
    struct mad_device *d = e->q->device;
    struct wmtcmd_blit_copy_from_buffer_to_buffer k;
    if (!r || !r->buffer || off + len > r->size || d->ncap >= 96) return 0;
    if (!d->cap_buf) {
        struct WMTBufferInfo bi; memset(&bi, 0, sizeof bi);
        bi.length = 65536; bi.options = WMTResourceStorageModeShared;
        d->cap_buf = MTLDevice_newBuffer(d->mtl_device, &bi);
        if (!d->cap_buf || !bi.memory.ptr) { d->cap_buf = 0; return 0; }
        d->cap_cpu = bi.memory.ptr;
    }
    if (d->cap_used + len > 65536) return 0;
    if (!exec_begin_blit(e)) return 0;
    memset(&k, 0, sizeof k);
    k.type = WMTBlitCommandCopyFromBufferToBuffer;
    k.src = r->buffer; k.src_offset = off; k.dst = d->cap_buf; k.dst_offset = d->cap_used; k.copy_length = len;
    MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
    snprintf(d->cap[d->ncap].label, sizeof d->cap[d->ncap].label, "%s", label);
    d->cap[d->ncap].off = d->cap_used; d->cap[d->ncap].len = len; d->cap[d->ncap].kind = kind;
    d->ncap++; d->cap_used += (len + 15) & ~15u; d->cap_total++;
    return 1;
}

/* ml918: which resource (and which of its views) a texture descriptor names. */
static struct mad_resource *mad_texture_of_view(struct mad_device *d, UINT64 id, int *xv) {
    /* Textures are not in the live (GPU-address) list; every texture that has
     * ever had an SRV or UAV is in srv_res / uav_res, which is what a table
     * entry can name. */
    unsigned i, k, pass;
    struct mad_resource *found = NULL;
    *xv = -1;
    if (!id) return NULL;
    AcquireSRWLockShared(&d->list_lock);
    for (pass = 0; pass < 2 && !found; pass++) {
        struct mad_resource **list = pass ? d->uav_res : d->srv_res; unsigned n = pass ? d->nuav : d->nsrv;
        for (i = 0; i < n && !found; i++) {
            struct mad_resource *r = list[i];
            if (!r || !r->texture) continue;
            if (r->gpu_resource_id == id) { found = r; break; }
            for (k = 0; k < r->nxview; k++) if (r->xview[k].id == id) { *xv = (int)k; found = r; break; }
        }
    }
    ReleaseSRWLockShared(&d->list_lock);
    return found;
}
/* ---------------------------------------------------------------------------
 * ml1008: the DXBC/SM5.x binding bridge.
 *
 * The two backends bind through entirely different layouts. Apple's converter
 * reads ONE top-level argument buffer in which a descriptor-table root argument
 * is the absolute GPU address of its first descriptor. Our DXBC compiler
 * instead reads TWO argument buffers at fixed Metal buffer indices (reported as
 * ConstanttBufferTableBindIndex / ArgumentBufferBindIndex, measured at 29 and
 * 30), each a flat array of 64-bit words: a resource lands at its reflected
 * StructurePtrOffset, which is a WORD index, and occupies one to three words
 * depending on its kind.
 *
 * So for these pipelines the runtime has to resolve each declaration range to a
 * real descriptor itself. Two traps, both measured rather than assumed:
 *
 *  - The reflected slot is the declaration RANGE ID, not the register. Under
 *    SM 5.1 those differ, and in 22 of the 24 captured shaders they do: range
 *    id 0 means b17 / t104 / u1. Binding by the range id binds the wrong
 *    resource with a perfectly clean compile, which is why the range identity
 *    is carried separately in madeira_ir_air_range::lower_bound.
 *
 *  - The compiler's resource lookups take a dynamic index and discard it, so a
 *    multi-element range would silently collapse onto its first descriptor.
 *    Those are refused in the conversion service, before a pipeline exists.
 * ------------------------------------------------------------------------- */

/* Our own descriptors already distinguish the three shapes the DXBC backend
 * encodes differently, so no extra per-descriptor state is needed:
 *   plain buffer : texture_view_id == 0, gpu_va = address, metadata = byte length
 *   texture      : texture_view_id != 0, metadata bit 63 clear, low half = min LOD clamp
 *   typed buffer : texture_view_id != 0, metadata bit 63 SET (mad_typed_buffer_view) */
#define MAD_DESC_TYPEDBUF (1ull << 63)

/* The view's array length, which the backend packs above the min LOD clamp.
 * mad_texture_of_view already reverses a view id to its resource and view
 * index; the view records how many slices it spans. */
static UINT mad_air_array_len(struct mad_device *d, UINT64 view_id) {
    int xv = -1;
    struct mad_resource *r;
    UINT32 va = 0, vb = 0;
    if (mad_vmap_get(d, view_id, &va, &vb) && va) return va;   /* ml1049: O(1), and survives any cache policy */
    r = mad_texture_of_view(d, view_id, &xv);
    if (!r) return 1;
    if (xv >= 0) {
        UINT n = r->xview[xv].nsl;
        return n && n != ~0u ? n : (r->tex_layers ? r->tex_layers : 1);
    }
    return r->tex_layers ? r->tex_layers : 1;
}

/* A typed-buffer view's element count and first element, recomputed exactly as
 * mad_typed_buffer_view did when it built the view. */
static int mad_air_texbuf(struct mad_device *d, UINT64 view_id, UINT32 *count, UINT32 *first) {
    /* ml1049: this walked srv_res / uav_res. Those hold TEXTURES (the buffer
     * branch of both view creators returns before the insertion), so a typed
     * buffer view was never found and every draw or dispatch binding one was
     * skipped. The view now records itself by id when it is created. */
    return mad_vmap_get(d, view_id, count, first);
}

static UINT mad_air_range_type(UINT air_type) {
    switch (air_type) {
    case MADEIRA_IR_AIR_CBV:     return MADEIRA_IR_RANGE_CBV;
    case MADEIRA_IR_AIR_SAMPLER: return MADEIRA_IR_RANGE_SAMPLER;
    case MADEIRA_IR_AIR_SRV:     return MADEIRA_IR_RANGE_SRV;
    default:                     return MADEIRA_IR_RANGE_UAV;
    }
}
static UINT mad_air_param_type(UINT air_type) {
    switch (air_type) {
    case MADEIRA_IR_AIR_CBV: return MADEIRA_IR_PARAM_CBV;
    case MADEIRA_IR_AIR_SRV: return MADEIRA_IR_PARAM_SRV;
    case MADEIRA_IR_AIR_UAV: return MADEIRA_IR_PARAM_UAV;
    default:                 return 0xffffffffu;   /* samplers are never root descriptors */
    }
}

/* Resolve one declaration range against the root signature.
 *
 * Exactly one of *desc (a descriptor read out of the bound heap) or *direct_va
 * (a root descriptor's address, which has no descriptor at all) is produced.
 * Anything unresolvable reports why instead of binding zeros quietly. */
static int mad_air_resolve(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root,
                           const UINT32 (*consts)[64], const struct madeira_ir_air_range *rg,
                           unsigned vis_mask,   /* ml1049: bit per madeira_ir_visibility this stage may see */
                           struct mad_descriptor *desc, UINT64 *direct_va, const char **why) {
    UINT want_range = mad_air_range_type(rg->type);
    UINT want_param = mad_air_param_type(rg->type);
    unsigned i, j;

    *direct_va = 0;
    memset(desc, 0, sizeof *desc);
    if (!rs) { *why = "no root signature bound"; return 0; }

    for (i = 0; i < rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        const struct madeira_ir_root_param *pp = &rs->params[i];

        /* ml1049: a root signature may give the SAME register to different
         * stages through different parameters. Taking the first match handed a
         * pixel shader the vertex stage's buffer (or its unset zero). */
        if (pp->visibility < 32 && !((1u << pp->visibility) & vis_mask)) continue;

        if (pp->type == MADEIRA_IR_PARAM_TABLE) {
            /* ml1012: a range may declare its offset as
             * D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND (0xffffffff), meaning
             * "immediately after the previous range in this table". Reading the
             * raw field made that a ~4-billion descriptor index, which is
             * exactly why every such constant buffer reported "descriptor
             * address past the end of the heap" (32 times in one run, all of
             * them this). The offset must be accumulated across the table's
             * ranges IN ORDER -- the same rule mad_table_count already applies
             * when it sizes a table. */
            unsigned running = 0;
            for (j = 0; j < pp->num_ranges; j++) {
                unsigned ri = pp->first_range + j;
                const struct madeira_ir_root_range *rr;
                UINT64 table_gpu, slot_gpu;
                struct mad_heap *h;
                UINT64 byte_off;
                UINT idx, range_off;
                if (ri >= rs->nranges) break;   /* ml1009: ranges are blob-sized now */
                rr = &rs->ranges[ri];
                range_off = (rr->table_offset == 0xffffffffu) ? running : rr->table_offset;
                if (rr->num_descriptors != ~0u) running = range_off + rr->num_descriptors;
                if (rr->range_type != want_range) continue;
                if (rr->register_space != rg->space) continue;
                if (rg->lower_bound < rr->base_register) continue;
                if (rr->num_descriptors != ~0u &&
                    rg->lower_bound >= rr->base_register + rr->num_descriptors) continue;

                idx = range_off + (rg->lower_bound - rr->base_register);
                table_gpu = root[i];
                if (!table_gpu) { *why = "descriptor table root argument never set"; return 0; }
                h = (rg->type == MADEIRA_IR_AIR_SAMPLER) ? e->smp : e->srv;
                if (!h || !h->cpu || !h->gpu_address) { *why = "the matching descriptor heap is not bound"; return 0; }
                slot_gpu = table_gpu + (UINT64)idx * sizeof(struct mad_descriptor);
                if (slot_gpu < h->gpu_address) { *why = "descriptor address below the bound heap"; return 0; }
                byte_off = slot_gpu - h->gpu_address;
                if (byte_off % sizeof(struct mad_descriptor)) { *why = "descriptor address is not slot-aligned"; return 0; }
                if (byte_off / sizeof(struct mad_descriptor) >= h->count) { *why = "descriptor address past the end of the heap"; return 0; }
                *desc = h->cpu[byte_off / sizeof(struct mad_descriptor)];
                return 1;
            }
            continue;
        }

        if (pp->type == MADEIRA_IR_PARAM_CONSTANTS) {
            /* Root constants consumed as a constant buffer. The backend wants a
             * POINTER, so the words need GPU-visible storage; copy them into a
             * ring slot whose lifetime already matches the dispatch. */
            UINT n;
            obj_handle_t cb; UINT64 coff, cgpu; void *ccpu;
            if (rg->type != MADEIRA_IR_AIR_CBV) continue;
            if (pp->shader_register != rg->lower_bound || pp->register_space != rg->space) continue;
            n = pp->num_constants > 64 ? 64 : pp->num_constants;
            if (!exec_ring_take_z(e, 1, 256, &cb, &coff, &ccpu, &cgpu)) { *why = "no ring slot for root constants"; return 0; }   /* ml1130 */
            memcpy(ccpu, consts[i], (size_t)n * 4);
            *direct_va = cgpu + coff;
            return 1;
        }

        if (pp->type == want_param) {
            if (pp->shader_register != rg->lower_bound || pp->register_space != rg->space) continue;
            if (!root[i]) { *why = "root descriptor never set"; return 0; }
            /* A root SRV/UAV carries an address and no length, and the backend
             * needs a byte length for buffer bindings. Refuse rather than
             * invent a bound. */
            if (rg->type != MADEIRA_IR_AIR_CBV) { *why = "root SRV/UAV has no length for this binding"; return 0; }
            *direct_va = root[i];
            return 1;
        }
    }

    /* Static samplers are baked into the shader by the DXIL converter, but the
     * DXBC backend expects them in the table like any other sampler. */
    if (rg->type == MADEIRA_IR_AIR_SAMPLER) {
        for (i = 0; i < rs->nsamplers && i < 32; i++)
            if (rs->samplers[i].shader_register == rg->lower_bound &&
                rs->samplers[i].register_space == rg->space &&
                (rs->samplers[i].visibility >= 32 || ((1u << rs->samplers[i].visibility) & vis_mask))) {
                *why = "static sampler (not yet placed in the sm5 argument table)";
                return 0;
            }
    }
    *why = "no root-signature entry covers this register";
    return 0;
}

/* ml1011: the DXBC backend's vertex-buffer table, bound at Metal index 16.
 *
 * Its fetch code indexes this table by the PACKED position of a slot within the
 * slot mask the shader was compiled against -- popcount of the mask bits below
 * that slot -- not by the raw D3D slot. Building it against a different mask
 * would fetch the wrong stream, so the mask travels with the pipeline.
 * Entry layout is airconv's dxmt_vertex_buffer_entry: { device u8 *base,
 * uint stride, uint length }. */
#define MAD_AIR_VB_TABLE_INDEX 16u
struct mad_air_vb_entry { UINT64 base; UINT32 stride; UINT32 length; };

static int mad_air_build_vb_table_mask(struct mad_exec *e, const struct mad_pso *pso, UINT slot_mask,   /* ml1083: mask of the stage being bound */
                                       obj_handle_t *buf, UINT64 *off) {
    struct mad_air_vb_entry *tab;
    UINT64 gpu;
    void *cpu;
    unsigned slot, n = 0;
    static unsigned said;

    *buf = 0; *off = 0;
    if (!slot_mask) return 1;   /* the shader fetches nothing */
    if (__builtin_popcount(slot_mask) * sizeof *tab > MAD_ARG_SLOT_BYTES) return 0;
    if (!exec_ring_take_z(e, 1, (size_t)__builtin_popcount(slot_mask) * sizeof *tab, buf, off, &cpu, &gpu)) return 0;   /* ml1130 */
    tab = (struct mad_air_vb_entry *)cpu;

    for (slot = 0; slot < 16; slot++) {
        if (!(slot_mask & (1u << slot))) continue;
        /* packed index, exactly as the generated fetch computes it */
        unsigned idx = (unsigned)__builtin_popcount(slot_mask & ((1u << slot) - 1u));
        struct mad_resource *r = e->vb[slot].res;
        if (!r || !r->buffer) {
            if (said++ < 16)
                d3d12_log("[madeira-d3d12] ml1011 '%s' fetches vertex slot %u but nothing is bound there\n",
                          pso->vs_name, slot);
            tab[idx].base = 0; tab[idx].stride = 0; tab[idx].length = 0;
            continue;
        }
        tab[idx].base = r->gpu_address + e->vb[slot].off;
        /* ml1153: a BOUND stream's StrideInBytes is used as given, 0 included:
         * D3D reads the same element for every vertex/instance then (the ml904
         * rule, which only the vertex-descriptor path had). Promoting 0 to the
         * packed stride made UE's GPU-culled instanced draws read the NEXT
         * draws' per-draw instance offsets (a stride-0 uint stream), so every
         * foliage vertex/instance took another plant's transform: the depth
         * prepass and the base pass drew different grass (ph-valley09/10). */
        tab[idx].stride = e->vb[slot].stride;
        tab[idx].length = (UINT32)(r->size > e->vb[slot].off ? r->size - e->vb[slot].off : 0);
        n++;
    }
    (void)n;
    return 1;
}
static int mad_air_build_vb_table(struct mad_exec *e, const struct mad_pso *pso,
                                  obj_handle_t *buf, UINT64 *off) {
    return mad_air_build_vb_table_mask(e, pso, pso->air_slot_mask, buf, off);
}

/* Build the two argument buffers for one dispatch. Returns 0 and logs the first
 * unresolvable range rather than dispatching against a half-filled table. */
static int mad_air_build_tables_ex(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root,
                                   const UINT32 (*consts)[64], const struct mad_pso *pso,
                                   UINT cb_bind, UINT arg_bind, UINT arg_qwords, UINT nair,
                                   const struct madeira_ir_air_range *airv, unsigned vis_mask,   /* ml1083: one stage, described explicitly */
                                   obj_handle_t *cb_buf, UINT64 *cb_off,
                                   obj_handle_t *arg_buf, UINT64 *arg_off) {
    struct mad_device *d = e->q->device;
    UINT64 *cb_words = NULL, *arg_words = NULL;
    UINT64 gpu;
    void *cpu;
    unsigned k;
    static unsigned said_fail;

    *cb_buf = *arg_buf = 0; *cb_off = *arg_off = 0;

    if (cb_bind != ~0u) {
        size_t cbz = 8;   /* ml1130: up to the highest constant-buffer entry this stage has */
        for (k = 0; k < nair; k++) if (airv[k].cb_table && ((size_t)airv[k].ptr_offset + 3) * 8 > cbz) cbz = ((size_t)airv[k].ptr_offset + 3) * 8;
        if (!exec_ring_take_z(e, 1, cbz, cb_buf, cb_off, &cpu, &gpu)) return 0;
        cb_words = (UINT64 *)cpu;
    }
    if (arg_bind != ~0u) {
        unsigned nslots = (unsigned)(((UINT64)arg_qwords * 8 + MAD_ARG_SLOT_BYTES - 1) / MAD_ARG_SLOT_BYTES);   /* ml1087 */
        if (nslots > MAD_ARG_RING_BYTES / MAD_ARG_SLOT_BYTES) {
            if (said_fail++ < 8)
                d3d12_log("[madeira-d3d12] ml1008 '%s' wants a %u-qword argument table; a whole ring chunk holds %u\n",
                          pso->vs_name, arg_qwords, (unsigned)(MAD_ARG_RING_BYTES / 8));
            return 0;
        }
        if (!exec_ring_take_z(e, nslots ? nslots : 1, (size_t)arg_qwords * 8, arg_buf, arg_off, &cpu, &gpu)) return 0;   /* ml1130 */
        arg_words = (UINT64 *)cpu;
    }

    for (k = 0; k < nair; k++) {
        const struct madeira_ir_air_range *rg = &airv[k];
        struct mad_descriptor de;
        UINT64 direct = 0;
        const char *why = "?";
        UINT64 *tab = rg->cb_table ? cb_words : arg_words;
        UINT off = rg->ptr_offset;

        if (!tab) { why = "the table this range belongs to was not reported"; goto bad; }
        if (!mad_air_resolve(e, rs, root, consts, rg, vis_mask, &de, &direct, &why)) {
            /* If the stage filter is what lost it, the signature's visibility
             * was parsed wrong or the engine relies on lax behaviour: bind as
             * before and COUNT it, rather than trade one skipped draw for another. */
            const char *why2 = "?";
            if (vis_mask == ~0u || !mad_air_resolve(e, rs, root, consts, rg, ~0u, &de, &direct, &why2)) goto bad;
            InterlockedIncrement(&g_vis_fallback);
        }

        if (g_dump_tables)   /* ml1106 */
            d3d12_log("[capture-draw]   %s%u space%u -> %s word %u: va=0x%llx view=%llu meta=0x%llx direct=0x%llx flags=%#x\n",
                      rg->type == 0 ? "b" : rg->type == 1 ? "s" : rg->type == 2 ? "t" : "u", rg->lower_bound, rg->space,
                      rg->cb_table ? "cb-table" : "arg-table", off, (unsigned long long)de.gpu_va, (unsigned long long)de.texture_view_id,
                      (unsigned long long)de.metadata, (unsigned long long)direct, rg->flags);
        if (rg->type == MADEIRA_IR_AIR_CBV) {
            /* One word: the buffer's address. */
            tab[off] = direct ? direct : de.gpu_va;
            if (!tab[off]) {
                /* ml1049: a NULL descriptor in a bound table. D3D12 only requires a
                 * descriptor to be valid if the shader actually reads it, and a real
                 * GPU runs the draw; skipping the whole draw was our invention. A
                 * null CBV reads as zeros, which is what the 64 KB null buffer is. */
                if (!d->null_gpu) { why = "constant buffer resolved to address zero"; goto bad; }
                tab[off] = d->null_gpu;
                InterlockedIncrement(&g_null_cbv_bound);
            }
            continue;
        }
        if (rg->type == MADEIRA_IR_AIR_SAMPLER) {
            /* Three words: sampler id, cube-sampler id, LOD bias. Our sampler
             * descriptor keeps the id in gpu_va and the bias in metadata. */
            tab[off + 0] = de.gpu_va;
            tab[off + 1] = de.texture_view_id ? de.texture_view_id : de.gpu_va;
            tab[off + 2] = de.metadata & 0xffffffffull;
            continue;
        }
        /* SRV and UAV share the encoding; the flags pick which of the three. */
        if (rg->flags & MADEIRA_IR_AIR_F_BUFFER) {
            tab[off + 0] = de.gpu_va;
            tab[off + 1] = de.metadata & 0xffffffffull;          /* byte length */
        } else if (rg->flags & MADEIRA_IR_AIR_F_TEXTURE) {
            if (de.metadata & MAD_DESC_TYPEDBUF) {
                UINT32 count = 0, first = 0;
                if (!mad_air_texbuf(d, de.texture_view_id, &count, &first)) {
                    why = "typed buffer view not found"; goto bad;
                }
                tab[off + 0] = de.texture_view_id;
                tab[off + 1] = ((UINT64)count << 32) | (UINT64)first;
            } else {
                tab[off + 0] = de.texture_view_id;
                tab[off + 1] = ((UINT64)mad_air_array_len(d, de.texture_view_id) << 32)
                             | (de.metadata & 0xffffffffull);     /* min LOD clamp */
            }
        } else {
            why = "range has neither the buffer nor the texture flag"; goto bad;
        }
        if (rg->flags & MADEIRA_IR_AIR_F_UAV_COUNTER)
            tab[off + 2] = 0;   /* no counter resource is modelled yet; the shader reads zero */
        continue;

    bad:
        mad_skip_why(why);
        if (said_fail++ < 32) {
            static const char *cls[4] = { "b", "s", "t", "u" };
            d3d12_log("[madeira-d3d12] ml1008 '%s': cannot bind %s%u space %u (id %u, flags %#x): %s\n",
                      pso->vs_name, rg->type < 4 ? cls[rg->type] : "?", rg->lower_bound,
                      rg->space, rg->range_id, rg->flags, why);
        }
        return 0;
    }
    return 1;
}
static int mad_air_build_tables(struct mad_exec *e, const struct mad_rootsig *rs, const UINT64 *root,
                                const UINT32 (*consts)[64], const struct mad_pso *pso,
                                int fragment_stage,   /* ml1011: 0 = vertex/compute, 1 = fragment */
                                obj_handle_t *cb_buf, UINT64 *cb_off,
                                obj_handle_t *arg_buf, UINT64 *arg_off) {
    /* ml1049: compute sees every parameter; the fragment stage ALL + PIXEL; the
     * vertex function ALL + VERTEX + GEOMETRY (the emulated GS shares it). */
    const unsigned vis_mask = pso->is_compute ? ~0u
        : fragment_stage ? ((1u << MADEIRA_IR_VIS_ALL) | (1u << MADEIRA_IR_VIS_PIXEL))
                         : ((1u << MADEIRA_IR_VIS_ALL) | (1u << MADEIRA_IR_VIS_VERTEX) | (1u << MADEIRA_IR_VIS_GEOMETRY));
    return mad_air_build_tables_ex(e, rs, root, consts, pso,
                                   fragment_stage ? pso->ps_cb_bind    : pso->cb_bind,
                                   fragment_stage ? pso->ps_arg_bind   : pso->arg_bind,
                                   fragment_stage ? pso->ps_arg_qwords : pso->arg_qwords,
                                   fragment_stage ? pso->ps_nair       : pso->nair,
                                   fragment_stage ? pso->ps_air : pso->air, vis_mask,
                                   cb_buf, cb_off, arg_buf, arg_off);
}
/* ml1083: one tessellation stage's tables. */
static int mad_air_build_tess_tables(struct mad_exec *e, const struct mad_tess_stage *st, unsigned vis,
                                     obj_handle_t *cb_buf, UINT64 *cb_off, obj_handle_t *arg_buf, UINT64 *arg_off) {
    return mad_air_build_tables_ex(e, e->rs, e->root, (const UINT32 (*)[64])e->consts, e->pso,
                                   st->cb_bind, st->arg_bind, st->arg_qwords, st->nair, st->air,
                                   (1u << MADEIRA_IR_VIS_ALL) | (1u << vis), cb_buf, cb_off, arg_buf, arg_off);
}

/* ml1011: DXGI_FORMAT -> WMTAttributeFormat for vertex-buffer elements.
 *
 * Extracted from DXMT's own dxmt_format.cpp table rather than hand-derived: it
 * is the mapping its D3D11 input layouts have always used, so the DXBC backend
 * sees exactly the formats it was written against. Anything not listed returns
 * Invalid and the caller refuses the pipeline by name instead of guessing. */
/* ml1023: is this render-target format UNORM? The DXBC backend clamps a
 * pixel shader's output differently for UNORM targets, so it has to be told. */
static int mad_format_is_unorm(DXGI_FORMAT f) {
    switch (f) {
    case DXGI_FORMAT_R8G8B8A8_UNORM:      case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
    case DXGI_FORMAT_B8G8R8A8_UNORM:      case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
    case DXGI_FORMAT_B8G8R8X8_UNORM:      case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB:
    case DXGI_FORMAT_R8_UNORM:            case DXGI_FORMAT_R8G8_UNORM:
    case DXGI_FORMAT_R16_UNORM:           case DXGI_FORMAT_R16G16_UNORM:
    case DXGI_FORMAT_R16G16B16A16_UNORM:  case DXGI_FORMAT_R10G10B10A2_UNORM:
    case DXGI_FORMAT_A8_UNORM:
        return 1;
    default:
        return 0;
    }
}

static enum WMTAttributeFormat mad_attr_format(DXGI_FORMAT f) {
    switch (f) {
    case DXGI_FORMAT_R32G32B32A32_UINT:               return WMTAttributeFormatUInt4;
    case DXGI_FORMAT_R32G32B32A32_SINT:               return WMTAttributeFormatInt4;
    case DXGI_FORMAT_R32G32B32A32_FLOAT:              return WMTAttributeFormatFloat4;
    case DXGI_FORMAT_R32G32B32_UINT:                  return WMTAttributeFormatUInt3;
    case DXGI_FORMAT_R32G32B32_SINT:                  return WMTAttributeFormatInt3;
    case DXGI_FORMAT_R32G32B32_FLOAT:                 return WMTAttributeFormatFloat3;
    case DXGI_FORMAT_R16G16B16A16_FLOAT:              return WMTAttributeFormatHalf4;
    case DXGI_FORMAT_R16G16B16A16_UNORM:              return WMTAttributeFormatUShort4Normalized;
    case DXGI_FORMAT_R16G16B16A16_UINT:               return WMTAttributeFormatUShort4;
    case DXGI_FORMAT_R16G16B16A16_SNORM:              return WMTAttributeFormatShort4Normalized;
    case DXGI_FORMAT_R16G16B16A16_SINT:               return WMTAttributeFormatShort4;
    case DXGI_FORMAT_R32G32_FLOAT:                    return WMTAttributeFormatFloat2;
    case DXGI_FORMAT_R32G32_UINT:                     return WMTAttributeFormatUInt2;
    case DXGI_FORMAT_R32G32_SINT:                     return WMTAttributeFormatInt2;
    case DXGI_FORMAT_R10G10B10A2_UNORM:               return WMTAttributeFormatUInt1010102Normalized;
    case DXGI_FORMAT_R11G11B10_FLOAT:                 return WMTAttributeFormatFloatRG11B10;
    case DXGI_FORMAT_R8G8B8A8_UNORM:                  return WMTAttributeFormatUChar4Normalized;
    case DXGI_FORMAT_R8G8B8A8_UINT:                   return WMTAttributeFormatUChar4;
    case DXGI_FORMAT_R8G8B8A8_SNORM:                  return WMTAttributeFormatChar4Normalized;
    case DXGI_FORMAT_R8G8B8A8_SINT:                   return WMTAttributeFormatChar4;
    case DXGI_FORMAT_R16G16_FLOAT:                    return WMTAttributeFormatHalf2;
    case DXGI_FORMAT_R16G16_UNORM:                    return WMTAttributeFormatUShort2Normalized;
    case DXGI_FORMAT_R16G16_UINT:                     return WMTAttributeFormatUShort2;
    case DXGI_FORMAT_R16G16_SNORM:                    return WMTAttributeFormatShort2Normalized;
    case DXGI_FORMAT_R16G16_SINT:                     return WMTAttributeFormatShort2;
    case DXGI_FORMAT_R32_FLOAT:                       return WMTAttributeFormatFloat;
    case DXGI_FORMAT_R32_UINT:                        return WMTAttributeFormatUInt;
    case DXGI_FORMAT_R32_SINT:                        return WMTAttributeFormatInt;
    case DXGI_FORMAT_R8G8_UNORM:                      return WMTAttributeFormatUChar2Normalized;
    case DXGI_FORMAT_R8G8_UINT:                       return WMTAttributeFormatUChar2;
    case DXGI_FORMAT_R8G8_SNORM:                      return WMTAttributeFormatChar2Normalized;
    case DXGI_FORMAT_R8G8_SINT:                       return WMTAttributeFormatChar2;
    case DXGI_FORMAT_R16_FLOAT:                       return WMTAttributeFormatHalf;
    case DXGI_FORMAT_R16_UNORM:                       return WMTAttributeFormatUShortNormalized;
    case DXGI_FORMAT_R16_UINT:                        return WMTAttributeFormatUShort;
    case DXGI_FORMAT_R16_SNORM:                       return WMTAttributeFormatShortNormalized;
    case DXGI_FORMAT_R16_SINT:                        return WMTAttributeFormatShort;
    case DXGI_FORMAT_R8_UNORM:                        return WMTAttributeFormatUCharNormalized;
    case DXGI_FORMAT_R8_UINT:                         return WMTAttributeFormatUChar;
    case DXGI_FORMAT_R8_SNORM:                        return WMTAttributeFormatCharNormalized;
    case DXGI_FORMAT_R8_SINT:                         return WMTAttributeFormatChar;
    case DXGI_FORMAT_R1_UNORM:                        return WMTAttributeFormatFloatRGB9E5;
    case DXGI_FORMAT_R9G9B9E5_SHAREDEXP:              return WMTAttributeFormatFloatRGB9E5;
    case DXGI_FORMAT_B8G8R8A8_UNORM:                  return WMTAttributeFormatUChar4Normalized_BGRA;
    default: return WMTAttributeFormatInvalid;
    }
}

static UINT mad_pf_bytes(UINT pf) {
    switch (pf) {
    case 10: case 13: return 1;
    case 25: case 30: return 2;
    case 53: case 54: case 55: case 65: case 70: case 71: case 80: case 81: case 90: case 92: return 4;
    case 103: case 105: case 110: case 115: return 8;
    case 125: return 16;
    default: return 0;
    }
}
/* A 4x4 block at the centre of one subresource, GPU-ordered, into the ring. */
/* ml924: a rectangle of one subresource (array slice, or z-slice of a 3D
 * texture), GPU-ordered, into the ring. seq=1 records the texel count so the
 * printer lists every texel in order (small textures: histograms, grids). */
static int exec_capture_region(struct mad_exec *e, const char *label, struct mad_resource *r, UINT slice, UINT level,
                               UINT x0, UINT y0, UINT rw, UINT rh, int seq) {
    struct mad_device *d = e->q->device;
    struct wmtcmd_blit_copy_from_texture_to_buffer k;
    UINT bpp = mad_pf_bytes((UINT)r->tex_pf), w, h, len;
    if (!r->texture || !bpp || r->is_depth || r->samples > 1 || d->ncap >= 96) return 0;
    w = r->width >> level; h = r->height >> level; if (!w || !h) return 0;
    if (x0 >= w || y0 >= h) return 0;
    if (x0 + rw > w) rw = w - x0; if (y0 + rh > h) rh = h - y0;
    len = rw * rh * bpp;
    if (!d->cap_buf) {
        struct WMTBufferInfo bi; memset(&bi, 0, sizeof bi);
        bi.length = 65536; bi.options = WMTResourceStorageModeShared;
        d->cap_buf = MTLDevice_newBuffer(d->mtl_device, &bi);
        if (!d->cap_buf || !bi.memory.ptr) { d->cap_buf = 0; return 0; }
        d->cap_cpu = bi.memory.ptr;
    }
    if (d->cap_used + len > 65536) return 0;
    if (!exec_begin_blit(e)) return 0;
    memset(&k, 0, sizeof k);
    k.type = WMTBlitCommandCopyFromTextureToBuffer;
    k.src = r->texture; k.level = level;
    if (r->tex_type == WMTTextureType3D) { k.slice = 0; k.origin.z = slice < r->tex_depth ? slice : 0; }
    else { k.slice = slice; k.origin.z = 0; }
    k.origin.x = x0; k.origin.y = y0; k.size.width = rw; k.size.height = rh; k.size.depth = 1;
    k.bytes_per_row = rw * bpp; k.bytes_per_image = len;
    k.dst = d->cap_buf; k.offset = d->cap_used;
    MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
    snprintf(d->cap[d->ncap].label, sizeof d->cap[0].label, "%s", label);
    d->cap[d->ncap].off = d->cap_used; d->cap[d->ncap].len = len; d->cap[d->ncap].kind = 100 + (UINT)r->tex_pf;
    d->cap[d->ncap].nt = seq ? rw * rh : 0;
    d->ncap++; d->cap_used += (len + 15) & ~15u; d->cap_total++;
    return 1;
}
/* A 4x4 block at the centre of one subresource; the whole level when it has
 * at most 256 texels (then every texel is listed in order). */
static int exec_capture_texels(struct mad_exec *e, const char *label, struct mad_resource *r, UINT slice, UINT level) {
    UINT w = r->width >> level, h = r->height >> level;
    if (!w || !h) return 0;
    if (w * h <= 256) return exec_capture_region(e, label, r, slice, level, 0, 0, w, h, 1);
    if (w < 4 || h < 4) return exec_capture_region(e, label, r, slice, level, 0, 0, 1, 1, 1);
    return exec_capture_region(e, label, r, slice, level, w / 2 - 2, h / 2 - 2, 4, 4, 0);
}

/* ml918: the post-process chain. For the first three 816-wide single-target
 * draws and the first ScreenPassVS draw into the 960x540 back buffer: every
 * texture descriptor in every table (resolved to its resource and view), a
 * 4x4 centre block of the first few inputs BEFORE the draw, the root CBVs,
 * and (from exec_draw) a 4x4 centre block of the output AFTER the draw. */
static void exec_capture_pp(struct mad_exec *e, unsigned kind) {
    struct mad_device *d = e->q->device;
    unsigned i, k, grabbed = 0; char lab[160];
    d3d12_log("[cap] K%u list#%u PP vs='%s' ps='%s' rt0=%ux%u pf%u (%s)\n", kind, g_list_seq, e->pso->vs_name, e->pso->ps_name,
              e->rt[0]->width, e->rt[0]->height, (unsigned)e->rt[0]->tex_pf, e->rt[0]->name);
    if (e->rs && e->srv && e->srv->cpu) for (i = 0; i < e->rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 va = e->root[i]; unsigned idx; char line[900]; int n;
        if (e->rs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
        if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) continue;
        idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
        n = snprintf(line, sizeof line, "[cap] K%u table p%u heap[%u..] (%u):", kind, i, idx, mad_table_count(e->rs, i, 12));
        for (k = 0; k < mad_table_count(e->rs, i, 12) && idx + k < e->srv->count && n < (int)sizeof line - 120; k++) {
            const struct mad_descriptor *de = &e->srv->cpu[idx + k];
            if (de->texture_view_id) {
                int xv; struct mad_resource *r = mad_texture_of_view(d, de->texture_view_id, &xv);
                if (!r) n += snprintf(line + n, sizeof line - n, " [%u]tex%llx=?", k, (unsigned long long)de->texture_view_id);
                else if (xv < 0) n += snprintf(line + n, sizeof line - n, " [%u]%s %ux%u pf%u t%u", k, r->name, r->width, r->height, (unsigned)r->tex_pf, (unsigned)r->tex_type);
                else n += snprintf(line + n, sizeof line - n, " [%u]%s %ux%u pf%u t%u VIEW(t%u pf%u swz%x l%u+%u s%u+%u)", k, r->name, r->width, r->height,
                                   (unsigned)r->tex_pf, (unsigned)r->tex_type, r->xview[xv].type, r->xview[xv].pf, r->xview[xv].swz,
                                   r->xview[xv].lvl0, r->xview[xv].nlvl, r->xview[xv].sl0, r->xview[xv].nsl);
                if (r && grabbed < 12 && !r->is_depth && (de->metadata >> 63) == 0) {
                    UINT sl = xv >= 0 ? r->xview[xv].sl0 : 0, lv = xv >= 0 ? r->xview[xv].lvl0 : 0;
                    if (r->tex_type == WMTTextureType3D) {   /* ml924: the middle z-slice, and texel (0,0,0) */
                        sl = r->tex_depth / 2;
                        snprintf(lab, sizeof lab, "K%u IN p%u[%u] %s %ux%u pf%u origin z0", kind, i, k, r->name, r->width, r->height, (unsigned)r->tex_pf);
                        exec_capture_region(e, lab, r, 0, lv, 0, 0, 1, 1, 1);
                    }
                    snprintf(lab, sizeof lab, "K%u IN p%u[%u] %s %ux%u pf%u s%u l%u", kind, i, k, r->name, r->width, r->height, (unsigned)r->tex_pf, sl, lv);
                    if (exec_capture_texels(e, lab, r, sl, lv)) grabbed++;
                }
            } else if (de->gpu_va) {
                UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, de->gpu_va, &off);
                n += snprintf(line + n, sizeof line - n, " [%u]buf+%llu/%llu%s", k, (unsigned long long)off, (unsigned long long)(de->metadata & 0xffffffffu), r ? "" : "(NOT LIVE)");
                if (r && grabbed < 8) {   /* ml921: buffer inputs too (exposure lives in one) */
                    snprintf(lab, sizeof lab, "K%u IN p%u[%u] buffer %s+%llu (%llu B)", kind, i, k, r->cpu ? "upload" : "default", (unsigned long long)off, (unsigned long long)r->size);
                    if (exec_capture_bytes(e, lab, r, off, 64, 15)) grabbed++;
                }
            } else n += snprintf(line + n, sizeof line - n, " [%u]null", k);
        }
        d3d12_log("%s\n", line);
    }
    if (e->rs) for (i = 0; i < e->rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 off = 0; struct mad_resource *r;
        if (e->rs->params[i].type != MADEIRA_IR_PARAM_CBV || !e->root[i]) continue;
        r = mad_resolve_address(d, e->root[i], &off);
        snprintf(lab, sizeof lab, "K%u rootCBV p%u -> %s+%llu", kind, i, r ? (r->cpu ? "upload" : "default") : "UNRESOLVED", (unsigned long long)off);
        if (r) exec_capture_bytes(e, lab, r, off, 96, 16);
    }
    e->cap_after = kind;
}

/* ml920: the compute producer of the black post-process input. In census
 * frames, the first dispatch whose tables name a texture of width 816 in
 * RG11B10F (the temporal upscaler's output): every table entry resolved, a
 * 4x4 centre block of that texture BEFORE the dispatch, the root CBVs, and
 * (from exec_dispatch) the same block AFTER it. */
/* ml930: how many descriptors a table parameter actually spans (the sum of
 * its ranges); scanning past that reads the NEXT table's descriptors and
 * attributed neighbours' resources to the wrong dispatch. Unbounded ranges
 * keep the old cap. */
static unsigned mad_table_count(const struct mad_rootsig *rs, unsigned i, unsigned cap) {
    unsigned n = 0, k;
    if (!rs || i >= rs->nparams) return cap;
    for (k = 0; k < rs->params[i].num_ranges; k++) {
        unsigned ri = rs->params[i].first_range + k, nd;
        if (ri >= rs->nranges) return cap;
        nd = rs->ranges[ri].num_descriptors;
        if (nd == 0xffffffffu || nd > 4096) return cap;
        if (rs->ranges[ri].table_offset != 0xffffffffu && rs->ranges[ri].table_offset + nd > n) n = rs->ranges[ri].table_offset + nd;
        else n += nd;
    }
    return n && n < cap ? n : cap;
}
static void exec_capture_cs(struct mad_exec *e, const struct mad_cmd *c) {
    struct mad_device *d = e->q->device;
    struct mad_resource *target = NULL; unsigned i, k; char lab[160];
    if (!e->crs || !e->srv || !e->srv->cpu || d->cap_total >= 2000) return;
    /* ml922/ml924: named kernels of the exposure chain, and the kernel that
     * writes the local-exposure grid. Every table entry resolved; textures and
     * buffers captured BEFORE and AFTER the dispatch, plus the root CBVs. */
    {
        unsigned kind = 0; const char *nm = e->cpso->vs_name;
        if (!strcmp(nm, "EyeAdaptationCS")) kind = 10;
        else if (!strcmp(nm, "HistogramConvertCS")) kind = 11;
        else if (!strcmp(nm, "MainAtomicCS")) kind = 12;
        else if (!(g_cap_kinds & (1u << 13))) {   /* the grid producer: any table naming a 3D RG32Float texture */
            for (i = 0; i < e->crs->nparams && i < MAD_ROOT_PARAM_MAX && !kind; i++) {
                UINT64 va = e->croot[i]; unsigned idx;
                if (e->crs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
                if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) continue;
                idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
                for (k = 0; k < 8 && idx + k < e->srv->count; k++) {
                    const struct mad_descriptor *de = &e->srv->cpu[idx + k]; int xv; struct mad_resource *r;
                    if (!de->texture_view_id || (de->metadata >> 63)) continue;
                    r = mad_texture_of_view(d, de->texture_view_id, &xv);
                    if (r && r->tex_type == WMTTextureType3D && r->tex_pf == 105) { kind = 13; break; }
                }
            }
        }
        if (kind && !(g_cap_kinds & (1u << kind))) {
            g_cap_kinds |= 1u << kind;
            d3d12_log("[cap] K%u list#%u CS '%s' %ux%ux%u\n", kind, g_list_seq, nm,
                      c->kind == MC_DISPATCH ? c->u.dispatch.x : 0, c->kind == MC_DISPATCH ? c->u.dispatch.y : 0, c->kind == MC_DISPATCH ? c->u.dispatch.z : 0);
            for (i = 0; i < e->crs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
                UINT64 va = e->croot[i]; unsigned idx; char line[900]; int n;
                if (e->crs->params[i].type == MADEIRA_IR_PARAM_CBV && va) {
                    UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, va, &off);
                    snprintf(lab, sizeof lab, "K%u rootCBV p%u -> %s+%llu", kind, i, r ? (r->cpu ? "upload" : "default") : "UNRESOLVED", (unsigned long long)off);
                    if (r) exec_capture_bytes(e, lab, r, off, 96, 16); else d3d12_log("[cap] %s\n", lab);
                    continue;
                }
                if (e->crs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
                if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) continue;
                idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
                n = snprintf(line, sizeof line, "[cap] K%u table p%u heap[%u..] (%u):", kind, i, idx, mad_table_count(e->crs, i, 8));
                for (k = 0; k < mad_table_count(e->crs, i, 8) && idx + k < e->srv->count && n < (int)sizeof line - 120; k++) {
                    const struct mad_descriptor *de = &e->srv->cpu[idx + k];
                    if (de->texture_view_id) {
                        int xv; struct mad_resource *r = mad_texture_of_view(d, de->texture_view_id, &xv);
                        if (!r) n += snprintf(line + n, sizeof line - n, " [%u]tex%llx=?%s", k, (unsigned long long)de->texture_view_id, (de->metadata >> 63) ? "(typedbuf)" : "");
                        else {
                            UINT sl = r->tex_type == WMTTextureType3D ? r->tex_depth / 2 : 0;
                            n += snprintf(line + n, sizeof line - n, " [%u]%s %ux%u pf%u t%u%s", k, r->name, r->width, r->height, (unsigned)r->tex_pf, (unsigned)r->tex_type, (de->metadata >> 63) ? "(typedbuf)" : "");
                            if (de->metadata >> 63) continue;
                            snprintf(lab, sizeof lab, "K%u IN p%u[%u] %s %ux%u pf%u z%u", kind, i, k, r->name, r->width, r->height, (unsigned)r->tex_pf, sl); exec_capture_texels(e, lab, r, sl, 0);
                            if (e->ncap_after_tex < 6 && r->width * r->height <= 256) { e->cap_after_tex[e->ncap_after_tex].r = r; e->cap_after_tex[e->ncap_after_tex].slice = sl;
                                snprintf(e->cap_after_tex[e->ncap_after_tex].label, 96, "K%u AFTER p%u[%u] %s %ux%u pf%u z%u", kind, i, k, r->name, r->width, r->height, (unsigned)r->tex_pf, sl); e->ncap_after_tex++; }
                        }
                    } else if (de->gpu_va) {
                        UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, de->gpu_va, &off);
                        n += snprintf(line + n, sizeof line - n, " [%u]buf+%llu/%llu%s", k, (unsigned long long)off, (unsigned long long)(de->metadata & 0xffffffffu), r ? "" : "(NOT LIVE)");
                        if (r) {
                            snprintf(lab, sizeof lab, "K%u BEFORE p%u[%u] buffer+%llu", kind, i, k, (unsigned long long)off); exec_capture_bytes(e, lab, r, off, 64, 15);
                            if (e->ncap_after_buf < 6) { e->cap_after_buf[e->ncap_after_buf].r = r; e->cap_after_buf[e->ncap_after_buf].off = off;
                                snprintf(e->cap_after_buf[e->ncap_after_buf].label, 96, "K%u AFTER p%u[%u] buffer+%llu", kind, i, k, (unsigned long long)off); e->ncap_after_buf++; }
                        }
                    } else n += snprintf(line + n, sizeof line - n, " [%u]null", k);
                }
                d3d12_log("%s\n", line);
            }
            /* ml930: fall through to the K9 scan; a dispatch can be both (the
             * 102x58 kernel with the grid AND the 816x460 output was hidden) */
        }
    }
    /* ml929: every dispatch in the census frame that names the 816-wide
     * RG11B10F texture (the upscaler's output), not just the first: the one
     * whose OUT differs from its IN is the writer. */
    if (g_k9_n >= 10) return;
    for (i = 0; i < e->crs->nparams && i < MAD_ROOT_PARAM_MAX && !target; i++) {
        UINT64 va = e->croot[i]; unsigned idx;
        if (e->crs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
        if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) continue;
        idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
        for (k = 0; k < 12 && idx + k < e->srv->count; k++) {
            const struct mad_descriptor *de = &e->srv->cpu[idx + k]; int xv; struct mad_resource *r;
            if (!de->texture_view_id || (de->metadata >> 63)) continue;
            r = mad_texture_of_view(d, de->texture_view_id, &xv);
            if (r && r->width == 816 && r->tex_pf == WMTPixelFormatRG11B10Float) { target = r; break; }
        }
    }
    if (!target) return;
    g_cap_kinds |= 1u << 9; g_k9_n++;
    { unsigned k9_big = 0;
    d3d12_log("[cap] K9 list#%u CS '%s' pso=%p %ux%ux%u names %s %ux%u pf%u\n", g_list_seq, e->cpso->vs_name, (void *)e->cpso,
              c->kind == MC_DISPATCH ? c->u.dispatch.x : 0, c->kind == MC_DISPATCH ? c->u.dispatch.y : 0, c->kind == MC_DISPATCH ? c->u.dispatch.z : 0,
              target->name, target->width, target->height, (unsigned)target->tex_pf);
    for (i = 0; i < e->crs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 va = e->croot[i]; unsigned idx; char line[900]; int n;
        if (e->crs->params[i].type == MADEIRA_IR_PARAM_CBV && va) {
            UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, va, &off);
            snprintf(lab, sizeof lab, "K9 rootCBV p%u -> %s+%llu", i, r ? (r->cpu ? "upload" : "default") : "UNRESOLVED", (unsigned long long)off);
            if (r) exec_capture_bytes(e, lab, r, off, 96, 16); else d3d12_log("[cap] %s\n", lab);
            continue;
        }
        if (e->crs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
        if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) {
            d3d12_log("[cap] K9 table p%u va=%llx not in the SRV heap\n", i, (unsigned long long)va); continue; }
        idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
        n = snprintf(line, sizeof line, "[cap] K9 table p%u heap[%u..] (%u):", i, idx, mad_table_count(e->crs, i, 12));
        for (k = 0; k < mad_table_count(e->crs, i, 12) && idx + k < e->srv->count && n < (int)sizeof line - 120; k++) {
            const struct mad_descriptor *de = &e->srv->cpu[idx + k];
            if (de->texture_view_id) {
                int xv; struct mad_resource *r = mad_texture_of_view(d, de->texture_view_id, &xv);
                if (!r) n += snprintf(line + n, sizeof line - n, " [%u]tex%llx=?%s", k, (unsigned long long)de->texture_view_id, (de->metadata >> 63) ? "(typedbuf)" : "");
                else {
                    n += snprintf(line + n, sizeof line - n, " [%u]%s %ux%u pf%u t%u%s", k, r->name, r->width, r->height, (unsigned)r->tex_pf, (unsigned)r->tex_type, xv >= 0 ? " VIEW" : "");
                    if (xv >= 0) n += snprintf(line + n, sizeof line - n, "(t%u pf%u l%u+%u s%u+%u)", r->xview[xv].type, r->xview[xv].pf, r->xview[xv].lvl0, r->xview[xv].nlvl, r->xview[xv].sl0, r->xview[xv].nsl);
                    if (r->width >= 400 && !r->is_depth && !(de->metadata >> 63) && r != target && k9_big < 6) {   /* ml930: the big inputs (history) too */
                        UINT sl = xv >= 0 ? r->xview[xv].sl0 : 0, lv = xv >= 0 ? r->xview[xv].lvl0 : 0;
                        snprintf(lab, sizeof lab, "K9 IN p%u[%u] %s %ux%u pf%u s%u l%u", i, k, r->name, r->width, r->height, (unsigned)r->tex_pf, sl, lv);
                        if (exec_capture_texels(e, lab, r, sl, lv)) k9_big++;
                        snprintf(lab, sizeof lab, "K9 IN p%u[%u] %s at (100,100)", i, k, r->name);
                        exec_capture_region(e, lab, r, sl, lv, 100, 100, 4, 4, 0);
                    }
                }
            } else if (de->gpu_va) {
                UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, de->gpu_va, &off);
                n += snprintf(line + n, sizeof line - n, " [%u]buf+%llu/%llu%s", k, (unsigned long long)off, (unsigned long long)(de->metadata & 0xffffffffu), r ? "" : "(NOT LIVE)");
            } else n += snprintf(line + n, sizeof line - n, " [%u]null", k);
        }
        d3d12_log("%s\n", line);
    }
    snprintf(lab, sizeof lab, "K9 IN before '%s' %s %ux%u pf%u", e->cpso->vs_name, target->name, target->width, target->height, (unsigned)target->tex_pf);
    exec_capture_texels(e, lab, target, 0, 0);
    snprintf(lab, sizeof lab, "K9 IN before '%s' %s at (100,100)", e->cpso->vs_name, target->name);
    exec_capture_region(e, lab, target, 0, 0, 100, 100, 4, 4, 0);
    e->cap_after_cs = target;
    }
}

/* Pick a few draws per census frame: an indirect scene-depth draw, an indirect
 * base-pass draw, a direct indexed base-pass draw, a direct scene-depth draw.
 * For each: the indirect args (or the first indices), the first vertices of
 * stream 0 and 1, and the first 64 bytes of every root CBV. */
static void exec_capture_draw(struct mad_exec *e, const struct mad_cmd *c) {
    struct mad_device *d = e->q->device;
    char lab[160]; unsigned i;
    int indirect = (c->kind == MC_DRAW_INDIRECT || c->kind == MC_DRAW_INDEXED_INDIRECT);
    int scene_depth = e->depth && e->depth->width == 736 && e->nrt == 0;
    int base_pass = e->nrt >= 5;
    unsigned kind = indirect ? (scene_depth ? 1 : base_pass ? 2 : 0) : (base_pass && c->kind == MC_DRAW_INDEXED ? 3 : scene_depth && c->kind == MC_DRAW_INDEXED ? 4 : 0);
    if (!kind && e->nrt == 1 && e->rt[0] && !e->depth) {   /* ml918: post-process chain */
        if (e->rt[0]->width == 816) kind = !(g_cap_kinds & (1u << 5)) ? 5 : !(g_cap_kinds & (1u << 6)) ? 6 : !(g_cap_kinds & (1u << 7)) ? 7 : 0;
        else if (e->rt[0]->width == 960 && e->rt[0]->height == 540 && !strcmp(e->pso->vs_name, "ScreenPassVS")) kind = 8;
    }
    if (!kind || d->cap_total >= 2000) return;
    if (g_cap_kinds & (1u << kind)) return;   /* each kind once per fence interval */
    g_cap_kinds |= 1u << kind;
    if (kind >= 5) { exec_capture_pp(e, kind); return; }
    if (indirect)
        snprintf(lab, sizeof lab, "K%u list#%u %s vs='%s' ps='%s' rt=%u ARGS@%llu", kind, g_list_seq,
                 c->kind == MC_DRAW_INDEXED_INDIRECT ? "dii" : "di", e->pso->vs_name, e->pso->ps_name, e->nrt, (unsigned long long)c->u.ind.off);
    else
        snprintf(lab, sizeof lab, "K%u list#%u dix vs='%s' ps='%s' rt=%u idx=%u start=%u base=%d inst=%u", kind, g_list_seq,
                 e->pso->vs_name, e->pso->ps_name, e->nrt, c->u.drawi.icount, c->u.drawi.start, (int)c->u.drawi.base, c->u.drawi.inst);
    d3d12_log("[cap] %s\n", lab);
    if (indirect) exec_capture_bytes(e, lab, c->u.ind.args, c->u.ind.off, 20, 10);
    if (e->ib && e->ib->buffer) {
        UINT isz = e->ib_type == WMTIndexTypeUInt32 ? 4 : 2;
        UINT64 o = e->ib_off + (c->kind == MC_DRAW_INDEXED ? (UINT64)c->u.drawi.start * isz : 0);
        snprintf(lab, sizeof lab, "K%u indices@%llu/%s", kind, (unsigned long long)o, isz == 4 ? "u32" : "u16");
        exec_capture_bytes(e, lab, e->ib, o, 48, isz == 4 ? 11 : 12);
    }
    for (i = 0; i < 3; i++) if (e->vb[i].res && e->vb[i].res->buffer) {
        snprintf(lab, sizeof lab, "K%u vb%u@%llu st%u", kind, i, (unsigned long long)e->vb[i].off, e->vb[i].stride);
        exec_capture_bytes(e, lab, e->vb[i].res, e->vb[i].off, 48, 13);
    }
    if (e->rs) for (i = 0; i < e->rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 off = 0; struct mad_resource *r;
        if (e->rs->params[i].type != MADEIRA_IR_PARAM_CBV || !e->root[i]) continue;
        r = mad_resolve_address(d, e->root[i], &off);
        snprintf(lab, sizeof lab, "K%u rootCBV p%u va=%llx -> %s+%llu", kind, i, (unsigned long long)e->root[i], r ? (r->cpu ? "upload" : "default") : "UNRESOLVED", (unsigned long long)off);
        if (r) exec_capture_bytes(e, lab, r, off, 96, 16); else d3d12_log("[cap] %s\n", lab);
    }
    {
        char line[600]; int n = snprintf(line, sizeof line, "[cap] K%u root:", kind);
        for (i = 0; i < 12 && n < (int)sizeof line - 24; i++) n += snprintf(line + n, sizeof line - n, " %llx", (unsigned long long)e->root[i]);
        d3d12_log("%s\n", line);
    }
    /* ml911: the descriptor tables. Entries are CPU-authored (the heap is
     * shared memory the application wrote), so reading them here is exact;
     * the BUFFERS they point at are GPU-written (GPUScene), so those are
     * captured GPU-ordered like everything else. */
    if (e->rs && e->srv && e->srv->cpu) for (i = 0; i < e->rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        UINT64 va = e->root[i]; unsigned k, idx; char line[900]; int n;
        if (e->rs->params[i].type != MADEIRA_IR_PARAM_TABLE || !va) continue;
        if (va < e->srv->gpu_address || va >= e->srv->gpu_address + (UINT64)e->srv->count * sizeof(struct mad_descriptor)) {
            d3d12_log("[cap] K%u table p%u va=%llx is not in the bound SRV heap (%s)\n", kind, i, (unsigned long long)va,
                      (e->smp && va >= e->smp->gpu_address && va < e->smp->gpu_address + (UINT64)e->smp->count * sizeof(struct mad_descriptor)) ? "sampler heap" : "unknown");
            continue;
        }
        idx = (unsigned)((va - e->srv->gpu_address) / sizeof(struct mad_descriptor));
        n = snprintf(line, sizeof line, "[cap] K%u table p%u heap[%u..]:", kind, i, idx);
        for (k = 0; k < 10 && idx + k < e->srv->count && n < (int)sizeof line - 80; k++) {
            const struct mad_descriptor *de = &e->srv->cpu[idx + k];
            if (de->texture_view_id) n += snprintf(line + n, sizeof line - n, " [%u]tex%llx%s", k, (unsigned long long)de->texture_view_id, (de->metadata >> 63) ? "(typedbuf)" : "");
            else if (de->gpu_va) {
                UINT64 off = 0; struct mad_resource *r = mad_resolve_address(d, de->gpu_va, &off);
                n += snprintf(line + n, sizeof line - n, " [%u]buf%llx+%llu/%llu%s", k, (unsigned long long)de->gpu_va, (unsigned long long)off,
                              (unsigned long long)(de->metadata & 0xffffffffu), r ? (r->cpu ? "u" : "d") : "?");
                if (r && k < 6) { snprintf(lab, sizeof lab, "K%u p%u[%u] buf+%llu (%s, %llu B)", kind, i, k, (unsigned long long)off, r->cpu ? "upload" : "default", (unsigned long long)r->size);
                                  exec_capture_bytes(e, lab, r, off, 64, 15); }
            } else n += snprintf(line + n, sizeof line - n, " [%u]null", k);
        }
        d3d12_log("%s\n", line);
    }
}

static float mad_half(USHORT h) {
    UINT s = (h >> 15) & 1, e = (h >> 10) & 31, m = h & 1023; float f;
    if (e == 0) f = ldexpf((float)m, -24); else if (e == 31) f = m ? NAN : INFINITY; else f = ldexpf((float)(m | 1024), (int)e - 25);
    return s ? -f : f;
}
static float mad_f11(UINT v) { UINT e = (v >> 6) & 31, m = v & 63; if (e == 0) return ldexpf((float)m, -20); if (e == 31) return m ? NAN : INFINITY; return ldexpf((float)(m | 64), (int)e - 21); }
static float mad_f10(UINT v) { UINT e = (v >> 5) & 31, m = v & 31; if (e == 0) return ldexpf((float)m, -19); if (e == 31) return m ? NAN : INFINITY; return ldexpf((float)(m | 32), (int)e - 20); }

/* Print every capture whose command buffer has completed (called after the
 * fence wait, so all of them have). */
static void mad_capture_flush(struct mad_device *d) {
    unsigned i, j;
    g_cap_kinds = 0; g_k9_n = 0;
    if (!d->ncap) return;
    for (i = 0; i < d->ncap; i++) {
        const unsigned char *p = d->cap_cpu + d->cap[i].off;
        char line[900]; int n = snprintf(line, sizeof line, "[cap-data] %s:", d->cap[i].label);
        switch (d->cap[i].kind) {
        case 10: { const UINT *u = (const UINT *)p; n += snprintf(line + n, sizeof line - n, " args idx/vcount=%u inst=%u start=%u base=%d istart=%u", u[0], u[1], u[2], (int)u[3], u[4]); break; }
        case 11: { const UINT *u = (const UINT *)p; for (j = 0; j < 12; j++) n += snprintf(line + n, sizeof line - n, " %u", u[j]); break; }
        case 12: { const USHORT *u = (const USHORT *)p; for (j = 0; j < 24; j++) n += snprintf(line + n, sizeof line - n, " %u", u[j]); break; }
        case 13: { const float *f = (const float *)p; const UINT *u = (const UINT *)p;
                   for (j = 0; j < 12; j++) n += snprintf(line + n, sizeof line - n, " %g", f[j]);
                   n += snprintf(line + n, sizeof line - n, " | hex"); for (j = 0; j < 8; j++) n += snprintf(line + n, sizeof line - n, " %08x", u[j]); break; }
        case 14: { const float *f = (const float *)p; for (j = 0; j < 16; j++) n += snprintf(line + n, sizeof line - n, " %g", f[j]); break; }
        case 16: { const float *f = (const float *)p; for (j = 0; j < 24; j++) n += snprintf(line + n, sizeof line - n, " %g", f[j]); break; }   /* ml930: 96 bytes, covers offset 72 */
        default: if (d->cap[i].kind >= 100) {
            UINT pf = d->cap[i].kind - 100, bpp = mad_pf_bytes(pf), t, nt = d->cap[i].nt ? d->cap[i].nt : (d->cap[i].len >= 16 * bpp ? 4 : 1);
            for (t = 0; t < nt; t++) {
                const unsigned char *q = d->cap[i].nt ? p + t * bpp : p + (t * 4 + t) * bpp;   /* sequential, or texels (0,0) (1,1) (2,2) (3,3) */
                float c[4] = { 0, 0, 0, 0 };
                if (n > (int)sizeof line - 80) { d3d12_log("%s\n", line); n = snprintf(line, sizeof line, "[cap-data] %s +%u:", d->cap[i].label, t); }   /* ml924: continue on a new line */
                if (pf == 53 || pf == 54 || pf == 103) {   /* ml924: integer formats */
                    UINT u[2] = { 0, 0 }; memcpy(u, q, bpp);
                    if (bpp == 8) n += snprintf(line + n, sizeof line - n, " (%u %u)", u[0], u[1]); else n += snprintf(line + n, sizeof line - n, " %u", u[0]);
                    continue;
                }
                switch (pf) {
                case 115: { const USHORT *h = (const USHORT *)q; unsigned j; for (j = 0; j < 4; j++) c[j] = mad_half(h[j]); break; }
                case 65:  { const USHORT *h = (const USHORT *)q; c[0] = mad_half(h[0]); c[1] = mad_half(h[1]); break; }
                case 25:  { const USHORT *h = (const USHORT *)q; c[0] = mad_half(h[0]); break; }
                case 125: memcpy(c, q, 16); break;
                case 105: memcpy(c, q, 8); break;   /* ml924: RG32Float (the local-exposure grid) */
                case 55:  memcpy(c, q, 4); break;
                case 92:  { UINT v; memcpy(&v, q, 4); c[0] = mad_f11(v & 0x7ff); c[1] = mad_f11((v >> 11) & 0x7ff); c[2] = mad_f10(v >> 22); c[3] = 1; break; }
                case 90:  { UINT v; memcpy(&v, q, 4); c[0] = (v & 1023) / 1023.f; c[1] = ((v >> 10) & 1023) / 1023.f; c[2] = ((v >> 20) & 1023) / 1023.f; c[3] = (v >> 30) / 3.f; break; }
                case 70: case 71: c[0] = q[0] / 255.f; c[1] = q[1] / 255.f; c[2] = q[2] / 255.f; c[3] = q[3] / 255.f; break;
                case 80: case 81: c[0] = q[2] / 255.f; c[1] = q[1] / 255.f; c[2] = q[0] / 255.f; c[3] = q[3] / 255.f; break;
                case 110: { const USHORT *h = (const USHORT *)q; unsigned j; for (j = 0; j < 4; j++) c[j] = h[j] / 65535.f; break; }
                case 10: case 13: c[0] = q[0] / 255.f; break;
                default: break;
                }
                n += snprintf(line + n, sizeof line - n, " (%.4g %.4g %.4g %.4g)", c[0], c[1], c[2], c[3]);
            }
            break; }
        case 15: { const float *f = (const float *)p; const UINT *u = (const UINT *)p;
                   for (j = 0; j < 16; j++) n += snprintf(line + n, sizeof line - n, " %g", f[j]);
                   n += snprintf(line + n, sizeof line - n, " | hex"); for (j = 0; j < 8; j++) n += snprintf(line + n, sizeof line - n, " %08x", u[j]); break; }
        }
        d3d12_log("%s\n", line);
    }
    d->ncap = 0; d->cap_used = 0;
}

/* ONE useResource PER RESOURCE AND ENCODER. Every draw and dispatch
 * re-declared the heaps and the list's root-descriptor resources (up to 64) on
 * its encoder, although a declaration holds for the rest of the encoder; each
 * is an Objective-C call on the unix side inside the replay the game's render
 * thread waits for. mad_use_seen returns 1 when `h` is already declared on
 * `enc` with at least this usage and these stages. Encoders stay alive until
 * the replay's autorelease pool drains (ml1049), so a handle is not reused
 * within a list. madeira.cfg use-dedup = 0 restores a declaration per call. */
static int g_use_dedup = -1;
/* A draw's declarations count only once its chain has been encoded: a draw
 * that returns early leaves them uncommitted, and the next begin drops them. */
static void mad_use_begin(struct mad_exec *e, obj_handle_t enc) {
    if (e->ud_enc != enc) { e->ud_enc = enc; e->ud_n = e->ud_committed = 0; }
    else e->ud_n = e->ud_committed;
}
static void mad_use_commit(struct mad_exec *e) { e->ud_committed = e->ud_n; }
static int mad_use_seen(struct mad_exec *e, obj_handle_t enc, obj_handle_t h, UINT32 usage, UINT32 stages) {
    unsigned i;
    if (g_use_dedup < 0) g_use_dedup = mad_cfg_int_pe("use-dedup", 1) ? 1 : 0;
    if (!g_use_dedup || !enc || !h || e->ud_enc != enc) return 0;
    for (i = 0; i < e->ud_n; i++)
        if (e->ud[i].h == h && (e->ud[i].usage & usage) == usage && (e->ud[i].stages & stages) == stages) return 1;
    if (e->ud_n < sizeof e->ud / sizeof e->ud[0]) {
        e->ud[e->ud_n].h = h; e->ud[e->ud_n].usage = usage; e->ud[e->ud_n].stages = stages; e->ud_n++;
    }
    return 0;
}

static void exec_draw(struct mad_exec *e, const struct mad_cmd *c) {
    struct wmtcmd_render_setpso c_pso;
    struct wmtcmd_render_draw_indirect c_di;
    struct wmtcmd_render_setblendcolor c_bl;
    struct wmtcmd_render_draw_indexed_indirect c_dii;
    struct wmtcmd_render_setviewport c_vp;
    struct wmtcmd_render_setscissorrect c_sc;
    struct wmtcmd_render_setbuffer sb[6 + 16 + 2];
    struct wmtcmd_render_useresource ur[256];
    struct wmtcmd_render_setdsso c_dss;
    struct wmtcmd_render_setrasterizerstate c_ras;
    struct wmtcmd_render_draw c_draw;
    struct wmtcmd_render_draw_indexed c_dix;
    struct wmtcmd_render_draw_meshthreadgroups c_mesh;   /* ml927 */
    struct wmtcmd_render_dxmt_geometry_draw c_gd; struct wmtcmd_render_dxmt_geometry_draw_indexed c_gdi; UINT64 gs_daboff = 0;   /* ml1147 */
    struct wmtcmd_render_setvisibilitymode c_vis;         /* ml1088 */
    struct mad_gs_drawinfo gdi; int gsemu;
    struct mad_tess *tv = NULL; unsigned tfmt = 0;   /* ml1083: the tessellation pipeline and index-format variant in use */
    struct wmtcmd_base *tail;
    obj_handle_t argbuf = 0; UINT64 argoff = 0;
    unsigned nsb = 0, nur = 0, i, arg_slot_used = 0;
    static unsigned said_nopso, said_trunc;
    struct mad_device *dev = e->q->device;

    /* ml1094: InstanceCount 0 draws NOTHING in D3D12; it was promoted to 1 below
     * (Astra). An engine that zeroes the count of a culled draw would have drawn
     * one instance of it. Not a skip: there is nothing to draw. */
    if ((c->kind == MC_DRAW && !c->u.draw.icount) || (c->kind == MC_DRAW_INDEXED && !c->u.drawi.inst)) { InterlockedIncrement(&g_zero_inst); return; }
    if (!e->pso || (!e->pso->rps && !e->pso->tess)) {   /* ml1086: a tessellation pipeline may have no plain pipeline */
        if (!said_nopso++) d3d12_log("[madeira-d3d12] draw without a pipeline state; skipped\n");
        MAD_SKIP(e);
        return;
    }
    gsemu = e->pso->gs_emu;
    if (gsemu && (c->kind == MC_DRAW_INDIRECT || c->kind == MC_DRAW_INDEXED_INDIRECT)) {
        static unsigned said; if (said++ < 4) d3d12_log("[madeira-d3d12] indirect draw on a geometry-shader pipeline is not implemented; skipped\n");
        MAD_SKIP(e); return;
    }
    if (g_census_on) { exec_capture_draw(e, c); exec_desc_check(e, e->rs, e->root, e->pso->vs_name); }   /* ml910/ml913 */
    if (!exec_begin_render(e)) { MAD_SKIP(e); return; }
    g_dump_tables = 0;
    if (g_capture_on && g_capture_ps[0] && e->pso->ps_name[0] && strstr(g_capture_ps, e->pso->ps_name) && g_capture_ps_shots < 8) {   /* ml1106; ml1152: any listed ps, 8 shots */
        g_capture_ps_shots++;
        mad_capture_draw_inputs(e, c);
        if (!exec_begin_render(e)) { MAD_SKIP(e); return; }
        g_dump_tables = 1;
    }
    if (e->pso->has_tess || e->topo >= D3D_PRIMITIVE_TOPOLOGY_1_CONTROL_POINT_PATCHLIST) {
        /* ml1083: run it, when the pipeline was built and this draw's index
         * format has a variant. Indirect tessellation draws need a dispatch
         * kernel this runtime does not have yet; they stay dropped and counted. */
        if (e->pso->tess && e->topo >= D3D_PRIMITIVE_TOPOLOGY_1_CONTROL_POINT_PATCHLIST &&
            e->topo <= D3D_PRIMITIVE_TOPOLOGY_32_CONTROL_POINT_PATCHLIST &&
            (c->kind == MC_DRAW || c->kind == MC_DRAW_INDEXED)) {
            tfmt = c->kind == MC_DRAW_INDEXED ? (e->ib_type == WMTIndexTypeUInt32 ? 2u : 1u) : 0u;
            if (e->pso->tess->obj[tfmt].rps) tv = e->pso->tess;
        }
        if (tv) goto tess_go;
        /* ml1069: a PATCH-LIST draw is a tessellation draw whether or not this
         * pipeline object showed us hull/domain shaders (a PSO created through a
         * stream description carries them where our parser does not look). Drawn
         * as a triangle list its control points become screen-sized garbage
         * triangles with a full pixel shader each: ph-rdr36's first cutscene went
         * to 200-950 ms per frame right after "topology 35 drawn as triangles" and
         * the driver then reported GPU HANGS. Dropped and counted like has_tess. */
        /* ml1050: a tessellation pipeline's vertex shader emits CONTROL POINTS
         * (object/world space); the domain shader is what projects them. Running
         * the VS alone and rasterising its output as clip space fills the screen
         * with huge garbage triangles over everything else. Until HS/DS run, the
         * pass is begun (its clears are real) and the draw is dropped, counted. */
        InterlockedIncrement(&g_tess_draws);
        MAD_SKIP(e); return;
    }
    if (((e->pso->tess && e->pso->tess->is_gs) || e->pso->tess_strip) && (c->kind == MC_DRAW || c->kind == MC_DRAW_INDEXED)) {   /* ml1147 */
        int strip = e->topo == D3D_PRIMITIVE_TOPOLOGY_LINESTRIP || e->topo == D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP ||
                    e->topo == D3D_PRIMITIVE_TOPOLOGY_LINESTRIP_ADJ || e->topo == D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP_ADJ;
        struct mad_tess *gv = strip ? e->pso->tess_strip : e->pso->tess;   /* ml1147b */
        tfmt = c->kind == MC_DRAW_INDEXED ? (e->ib_type == WMTIndexTypeUInt32 ? 2u : 1u) : 0u;
        if (gv && gv->obj[tfmt].rps) { tv = gv; goto tess_go; }
        {
            static unsigned said_strip;
            if (said_strip++ < 8) d3d12_log("[madeira-d3d12] ml1147 %s draw (topology %u, index format %u) has no geometry variant: drawn without its geometry stage\n",
                                            strip ? "strip" : "list", (unsigned)e->topo, tfmt);
        }
    }
tess_go:
    if (!exec_arg_slot(e, &argbuf, &argoff)) { MAD_SKIP(e); return; }
    arg_slot_used = e->l->ring_used - 1;   /* ml1084: the slot exec_arg_slot took, see the draw-params block */

    memset(&c_pso, 0, sizeof c_pso); c_pso.type = WMTRenderCommandSetPSO; c_pso.pso = tv ? tv->obj[tfmt].rps : e->pso->rps;
    if (e->pso->has_vd && !gsemu && !tv) {
        UINT strides[16];
        /* ml904: a BOUND stream with StrideInBytes 0 means "every vertex reads
         * the same element" (D3D semantics); it must not be promoted to the
         * packed stride, which made the base pass read successive elements of
         * a per-draw constant stream. Unbound slots keep the assumed stride. */
        for (i = 0; i < 16; i++) strides[i] = e->vb[i].res ? e->vb[i].stride : e->pso->vb_stride[i];
        c_pso.pso = mad_pso_for_strides(e->pso, strides);
    }
    tail = (struct wmtcmd_base *)&c_pso;
#define MAD_APPEND(node) do { tail->next.ptr = (node); tail = (struct wmtcmd_base *)(node); } while (0)
    if (e->has_vp) {
        memset(&c_vp, 0, sizeof c_vp); c_vp.type = WMTRenderCommandSetViewport;
        c_vp.viewport.originX = e->vp.TopLeftX; c_vp.viewport.originY = e->vp.TopLeftY;
        c_vp.viewport.width = e->vp.Width; c_vp.viewport.height = e->vp.Height;
        c_vp.viewport.znear = e->vp.MinDepth; c_vp.viewport.zfar = e->vp.MaxDepth;
        MAD_APPEND(&c_vp);
    }
    if (e->has_sc) {
        /* Metal refuses a scissor outside the attachment; clamp to it. */
        UINT tw = e->enc_nrt && e->enc_rt[0] ? e->enc_rt[0]->width : (e->enc_depth ? e->enc_depth->width : 0);
        UINT th = e->enc_nrt && e->enc_rt[0] ? e->enc_rt[0]->height : (e->enc_depth ? e->enc_depth->height : 0);
        LONG x0 = e->sc.left < 0 ? 0 : e->sc.left, y0 = e->sc.top < 0 ? 0 : e->sc.top;
        LONG x1 = e->sc.right, y1 = e->sc.bottom;
        if (tw && x1 > (LONG)tw) x1 = (LONG)tw;
        if (th && y1 > (LONG)th) y1 = (LONG)th;
        if (x1 > x0 && y1 > y0) {
            memset(&c_sc, 0, sizeof c_sc); c_sc.type = WMTRenderCommandSetScissorRect;
            c_sc.scissor_rect.x = (UINT64)x0; c_sc.scissor_rect.y = (UINT64)y0;
            c_sc.scissor_rect.width = (UINT64)(x1 - x0); c_sc.scissor_rect.height = (UINT64)(y1 - y0);
            MAD_APPEND(&c_sc);
        }
    }
    memset(sb, 0, sizeof sb);
#define MAD_SETBUF(stage, buf_, off_, idx_) do { sb[nsb].type = (stage); sb[nsb].buffer = (buf_); \
        sb[nsb].offset = (off_); sb[nsb].index = (idx_); MAD_APPEND(&sb[nsb]); nsb++; } while (0)
    /* kIRArgumentBufferBindPoint 2, descriptor heap 0, sampler heap 1. */
    /* ml927: on a geometry-emulation pipeline the vertex stage is the OBJECT
     * stage and the geometry shader the MESH stage; both take the same
     * bindings the vertex stage would. */
#define MAD_SETBUF_VS(buf_, off_, idx_) do { if (gsemu) { MAD_SETBUF(WMTRenderCommandSetObjectBuffer, buf_, off_, idx_); MAD_SETBUF(WMTRenderCommandSetMeshBuffer, buf_, off_, idx_); } \
                                             else MAD_SETBUF(WMTRenderCommandSetVertexBuffer, buf_, off_, idx_); } while (0)
    if (tv) {   /* ml1083: object stage = vertex (27/28) + hull (29/30); mesh stage = domain (29/30) */
        obj_handle_t vcb = 0, varg = 0, hcb = 0, harg = 0, dcb = 0, darg = 0, pcb = 0, parg = 0, vbt = 0, dab = 0;
        UINT64 vcboff = 0, vargoff = 0, hcboff = 0, hargoff = 0, dcboff = 0, dargoff = 0, pcboff = 0, pargoff = 0, vbtoff = 0, daboff = 0, dgpu = 0;
        void *dcpu = NULL; UINT32 dp[5] = { 0, 0, 0, 0, 0 };
        if (!mad_air_build_tess_tables(e, &tv->obj[tfmt].vs, MADEIRA_IR_VIS_VERTEX, &vcb, &vcboff, &varg, &vargoff)) { MAD_SKIP(e); return; }
        if (!tv->is_gs && !mad_air_build_tess_tables(e, &tv->obj[tfmt].hs, MADEIRA_IR_VIS_HULL, &hcb, &hcboff, &harg, &hargoff)) { MAD_SKIP(e); return; }
        if (!mad_air_build_tess_tables(e, &tv->ds, tv->is_gs ? MADEIRA_IR_VIS_GEOMETRY : MADEIRA_IR_VIS_DOMAIN, &dcb, &dcboff, &darg, &dargoff)) { MAD_SKIP(e); return; }   /* ml1147 */
        if (e->pso->ps_fn &&
            !mad_air_build_tables(e, e->rs, e->root, (const UINT32 (*)[64])e->consts,
                                  e->pso, 1, &pcb, &pcboff, &parg, &pargoff)) { MAD_SKIP(e); return; }
        if (!mad_air_build_vb_table_mask(e, e->pso, tv->obj[tfmt].slot_mask, &vbt, &vbtoff)) { MAD_SKIP(e); return; }
        /* The draw arguments, D3D's own layout (DXMT_DRAW_[INDEXED_]ARGUMENTS):
         * the start index is in ELEMENTS and the index buffer is bound at its
         * view's base, the object function adds the two. */
        if (!exec_ring_take_z(e, 1, 64, &dab, &daboff, &dcpu, &dgpu)) { MAD_SKIP(e); return; }   /* ml1130 */
        gs_daboff = daboff;   /* ml1147: the geometry draw re-points object buffer 21 at this offset */
        if (c->kind == MC_DRAW_INDEXED) {
            dp[0] = c->u.drawi.icount; dp[1] = c->u.drawi.inst ? c->u.drawi.inst : 1; dp[2] = c->u.drawi.start;
            dp[3] = (UINT32)c->u.drawi.base; dp[4] = c->u.drawi.istart;
        } else {
            dp[0] = c->u.draw.vcount; dp[1] = c->u.draw.icount ? c->u.draw.icount : 1; dp[2] = c->u.draw.vstart; dp[3] = c->u.draw.istart;
        }
        memcpy(dcpu, dp, sizeof dp);
        if (vbt)  MAD_SETBUF(WMTRenderCommandSetObjectBuffer, vbt, vbtoff, MAD_AIR_VB_TABLE_INDEX);
        MAD_SETBUF(WMTRenderCommandSetObjectBuffer, dab, daboff, 21);
        if (c->kind == MC_DRAW_INDEXED && e->ib && e->ib->buffer) MAD_SETBUF(WMTRenderCommandSetObjectBuffer, e->ib->buffer, e->ib_off, 20);
        if (vcb)  MAD_SETBUF(WMTRenderCommandSetObjectBuffer, vcb, vcboff, tv->obj[tfmt].vs.cb_bind);
        if (varg) MAD_SETBUF(WMTRenderCommandSetObjectBuffer, varg, vargoff, tv->obj[tfmt].vs.arg_bind);
        if (hcb)  MAD_SETBUF(WMTRenderCommandSetObjectBuffer, hcb, hcboff, tv->obj[tfmt].hs.cb_bind);
        if (harg) MAD_SETBUF(WMTRenderCommandSetObjectBuffer, harg, hargoff, tv->obj[tfmt].hs.arg_bind);
        if (dcb)  MAD_SETBUF(WMTRenderCommandSetMeshBuffer, dcb, dcboff, tv->ds.cb_bind);
        if (darg) MAD_SETBUF(WMTRenderCommandSetMeshBuffer, darg, dargoff, tv->ds.arg_bind);
        if (pcb)  MAD_SETBUF(WMTRenderCommandSetFragmentBuffer, pcb, pcboff, e->pso->ps_cb_bind);
        if (parg) MAD_SETBUF(WMTRenderCommandSetFragmentBuffer, parg, pargoff, e->pso->ps_arg_bind);
    } else if (e->pso && e->pso->backend == MADEIRA_IR_BACKEND_AIRCONV) {   /* ml1011 */
        /* Three tables, not one: the DXBC backend's vertex stage fetches through
         * a vertex-buffer table, and each stage reads its own constant-buffer and
         * argument tables at its own reported indices. */
        obj_handle_t vcb = 0, varg = 0, pcb = 0, parg = 0, vbt = 0;
        UINT64 vcboff = 0, vargoff = 0, pcboff = 0, pargoff = 0, vbtoff = 0;
        if (!mad_air_build_tables(e, e->rs, e->root, (const UINT32 (*)[64])e->consts,
                                  e->pso, 0, &vcb, &vcboff, &varg, &vargoff)) { MAD_SKIP(e); return; }
        if (e->pso->ps_fn &&
            !mad_air_build_tables(e, e->rs, e->root, (const UINT32 (*)[64])e->consts,
                                  e->pso, 1, &pcb, &pcboff, &parg, &pargoff)) { MAD_SKIP(e); return; }
        if (!mad_air_build_vb_table(e, e->pso, &vbt, &vbtoff)) { MAD_SKIP(e); return; }
        if (vbt)  MAD_SETBUF_VS(vbt, vbtoff, MAD_AIR_VB_TABLE_INDEX);
        if (vcb)  MAD_SETBUF_VS(vcb, vcboff, e->pso->cb_bind);
        if (varg) MAD_SETBUF_VS(varg, vargoff, e->pso->arg_bind);
        if (pcb)  MAD_SETBUF(WMTRenderCommandSetFragmentBuffer, pcb, pcboff, e->pso->ps_cb_bind);
        if (parg) MAD_SETBUF(WMTRenderCommandSetFragmentBuffer, parg, pargoff, e->pso->ps_arg_bind);
    } else {
    MAD_SETBUF_VS(argbuf, argoff, 2);
    MAD_SETBUF(WMTRenderCommandSetFragmentBuffer, argbuf, argoff, 2);
    if (e->srv && e->srv->buffer) {
        MAD_SETBUF_VS(e->srv->buffer, 0, 0);
        MAD_SETBUF(WMTRenderCommandSetFragmentBuffer, e->srv->buffer, 0, 0);
    }
    if (e->smp && e->smp->buffer) {
        MAD_SETBUF_VS(e->smp->buffer, 0, 1);
        MAD_SETBUF(WMTRenderCommandSetFragmentBuffer, e->smp->buffer, 0, 1);
    }
    }
    /* Vertex buffers ride at kIRVertexBufferBindPoint (6) + slot -- for the
     * DXIL (MSC) backend only. ml1105: the DXBC backend pulls vertices through
     * its table at Metal index 16, and this loop bound D3D slot 10 at 6 + 10 =
     * 16 ON TOP OF IT, even when slot 10 was only stale IA state the current
     * shader never reads. The captures said it exactly: the invisible robbery
     * frame had slot 10 bound in 194 of 212 G-buffer draws, the visible one in
     * 0 of 213; the horse frame 106 of 133 (Astra, ph-rdr58 capture review).
     * Keep the two compilers' binding ABIs apart. */
    if (!gsemu && !tv && e->pso->backend == MADEIRA_IR_BACKEND_MSC) {
        for (i = 0; i < 16; i++)
            if (e->vb[i].res && e->vb[i].res->buffer)
                MAD_SETBUF(WMTRenderCommandSetVertexBuffer, e->vb[i].res->buffer, e->vb[i].off, (uint8_t)(6 + i));
    }
    /* ml912: the converter's draw contract (metal_irconverter_runtime.h,
     * IRRuntimeDraw*): every vertex stage that reads SV_VertexID /
     * SV_InstanceID takes the draw's own arguments at bind point 4
     * (IRRuntimeDrawParams: the D3D12 argument block verbatim) and a uint16
     * "index type" at bind point 5 (0 = non-indexed, MTLIndexType+1 for
     * indexed). Nothing bound them before; the engine's instanced scene
     * shaders were computing their instance ids from an unbound buffer. For
     * indirect draws the argument buffer itself is bound, as Apple's helper
     * does, so the GPU reads the culling output the draw consumes. */
    if (!tv) {   /* ml1083: a tessellation draw bound its arguments above */
        struct mad_list *l = e->l;
        /* ml1084: this used to take "the last slot taken" (ring_used - 1), which
         * is the argument slot only on the DXIL path. On the DXBC path the table
         * builders above take up to five more slots after it, so the 20-byte
         * draw parameters landed at byte 512 of the LAST table built -- the
         * vertex-buffer table when the shader fetches vertices (harmless, it is
         * 256 bytes), otherwise the PIXEL argument table, whose 64th qword
         * onwards then read {count, instances, start, ...} instead of texture
         * handles. Write into the slot actually bound at index 4. */
        unsigned per = MAD_ARG_RING_BYTES / MAD_ARG_SLOT_BYTES, used = arg_slot_used;
        unsigned char *cpu = (unsigned char *)l->ring_cpu[used / per] + (used % per) * MAD_ARG_SLOT_BYTES;
        UINT32 dp[5] = { 0, 0, 0, 0, 0 };
        UINT16 kind = 0;
        if (c->kind == MC_DRAW_INDEXED) {
            /* ml914: Apple's IRRuntimeDrawIndexedPrimitives stores the index
             * buffer BYTE offset it hands Metal in startIndexLocation, not the
             * D3D element count; match it exactly. */
            UINT isz = e->ib_type == WMTIndexTypeUInt32 ? 4 : 2;
            dp[0] = c->u.drawi.icount; dp[1] = c->u.drawi.inst ? c->u.drawi.inst : 1;
            dp[2] = (UINT32)(e->ib_off + (UINT64)c->u.drawi.start * isz);
            dp[3] = (UINT32)c->u.drawi.base; dp[4] = c->u.drawi.istart;
        } else if (c->kind == MC_DRAW) {
            dp[0] = c->u.draw.vcount; dp[1] = c->u.draw.icount ? c->u.draw.icount : 1; dp[2] = c->u.draw.vstart; dp[3] = c->u.draw.istart;
        }
        if (c->kind == MC_DRAW_INDEXED || c->kind == MC_DRAW_INDEXED_INDIRECT) kind = (UINT16)((e->ib_type == WMTIndexTypeUInt32 ? 1 : 0) + 1);
        memset(&gdi, 0, sizeof gdi);
        if (gsemu) {
            /* ml927: the emulation helpers take the ELEMENT start index and fold
             * the index-buffer byte offset into the buffer address. */
            UINT pt = mad_gs_prim(e->topo), count = c->kind == MC_DRAW_INDEXED ? c->u.drawi.icount : c->u.draw.vcount;
            UINT inst = dp[1]; UINT64 ibaddr = 0;
            struct WMTSize grid, otg, mtg;
            struct { UINT64 addr; UINT32 length, stride; } vbt[31];
            if (c->kind == MC_DRAW_INDEXED) { dp[2] = c->u.drawi.start; if (e->ib) ibaddr = e->ib->gpu_address + e->ib_off; }
            mad_gs_draw(pt, e->pso->gs_vertex_size, e->pso->gs_max_prims, inst, count, kind, ibaddr, &gdi, &grid, &otg, &mtg);
            memset(&c_mesh, 0, sizeof c_mesh); c_mesh.type = WMTRenderCommandDrawMeshThreadgroups;
            c_mesh.threadgroup_per_grid = grid; c_mesh.object_threadgroup_size = otg; c_mesh.mesh_threadgroup_size = mtg;
            memset(vbt, 0, sizeof vbt);
            for (i = 0; i < 16; i++) if (e->vb[i].res && e->vb[i].res->buffer) {
                vbt[i].addr = e->vb[i].res->gpu_address + e->vb[i].off;
                vbt[i].length = (UINT32)(e->vb[i].res->size > e->vb[i].off ? e->vb[i].res->size - e->vb[i].off : 0);
                vbt[i].stride = e->vb[i].stride;
            }
            memcpy(cpu + MAD_ARG_VBTABLE_OFF, vbt, sizeof vbt);
            MAD_SETBUF(WMTRenderCommandSetObjectBuffer, argbuf, argoff + MAD_ARG_VBTABLE_OFF, 6);
        } else gdi.index_type = kind;
        memcpy(cpu + MAD_ARG_DRAWPARAMS_OFF, dp, sizeof dp);
        memcpy(cpu + MAD_ARG_DRAWINFO_OFF, &gdi, sizeof gdi);
        if ((c->kind == MC_DRAW_INDIRECT || c->kind == MC_DRAW_INDEXED_INDIRECT) && c->u.ind.args && c->u.ind.args->buffer)
            MAD_SETBUF(WMTRenderCommandSetVertexBuffer, c->u.ind.args->buffer, c->u.ind.off, 4);
        else
            MAD_SETBUF_VS(argbuf, argoff + MAD_ARG_DRAWPARAMS_OFF, 4);
        MAD_SETBUF_VS(argbuf, argoff + MAD_ARG_DRAWINFO_OFF, 5);
    }
#undef MAD_SETBUF_VS
#undef MAD_SETBUF
    /* ml1130: no 8 KB clear per draw; each entry is zeroed as it is used */
    const UINT32 use_stages = (UINT32)((gsemu || tv) ? (WMTRenderStageObject | WMTRenderStageMesh | WMTRenderStageFragment) : (WMTRenderStageVertex | WMTRenderStageFragment));
    mad_use_begin(e, e->renc);
#define MAD_USE_U(h, u) do { if ((h) && nur < 256 && !mad_use_seen(e, e->renc, (h), (UINT32)(u), use_stages)) { \
        memset(&ur[nur], 0, sizeof ur[nur]); ur[nur].type = WMTRenderCommandUseResource; ur[nur].resource = (h); \
        ur[nur].usage = (enum WMTResourceUsage)(u); ur[nur].stages = (enum WMTRenderStages)use_stages; \
        MAD_APPEND(&ur[nur]); nur++; } } while (0)
#define MAD_USE(h) MAD_USE_U(h, WMTResourceUsageRead)
    if (e->srv) MAD_USE(e->srv->buffer);
    if (e->smp) MAD_USE(e->smp->buffer);
    if (gsemu || tv || e->pso->backend == MADEIRA_IR_BACKEND_AIRCONV) {   /* ml927: the object stage reads vertices and indices through the tables, not encoder bindings; ml1105: so does the DXBC vertex stage */
        for (i = 0; i < 16; i++) if (e->vb[i].res) MAD_USE(e->vb[i].res->buffer);
        if (e->ib) MAD_USE(e->ib->buffer);
    }
    for (i = e->l->nused > 64 ? e->l->nused - 64 : 0; i < e->l->nused; i++) {
        struct mad_resource *r = e->l->used[i];
        if (r) MAD_USE(r->texture ? r->texture : r->buffer);
    }
    /* ml1060: with a residency set (ml880) these two loops are a fallback, and once
     * the application has more than 256 viewed resources they are not even that:
     * the list saturates on the FIRST 256 SRVs, an arbitrary subset, and the UAV
     * loop below never gets a slot. At 15,000 textures every draw still paid for
     * 256 useResource commands (MTLResourceListAddResource was ~2 % of all CPU
     * samples, 26,000 draws per 600 lists). Skip them exactly when they are
     * meaningless; small applications keep the old behaviour. */
    const int ml1060_skip_lists = dev->resset && dev->nsrv > 256;
    if (!ml1060_skip_lists) {
        AcquireSRWLockShared(&dev->list_lock);   /* views are created on other threads */
        for (i = 0; i < dev->nsrv && nur < 256; i++) {
            struct mad_resource *r = dev->srv_res[i];
            if (r) MAD_USE(r->texture ? r->texture : r->buffer);
        }
        for (i = 0; i < dev->nuav && nur < 256; i++) {
            struct mad_resource *r = dev->uav_res[i];
            if (r) MAD_USE_U(r->texture ? r->texture : r->buffer, WMTResourceUsageRead | WMTResourceUsageWrite);
        }
        ReleaseSRWLockShared(&dev->list_lock);
    }
    if (dev->nsrv > 190 && !said_trunc++)
        d3d12_log("[madeira-d3d12] residency list truncated at 256 per draw (%u views); a real residency set is owed\n", dev->nsrv);
#undef MAD_USE
#undef MAD_USE_U
    if (e->enc_depth && (e->pso->dsso || dev->dsso)) {
        memset(&c_dss, 0, sizeof c_dss); c_dss.type = WMTRenderCommandSetDSSO;
        c_dss.dsso = e->pso->dsso ? e->pso->dsso : dev->dsso;
        c_dss.stencil_ref = (uint8_t)e->stencil_ref;
        MAD_APPEND(&c_dss);
    }
    if (e->has_blend) {
        memset(&c_bl, 0, sizeof c_bl); c_bl.type = WMTRenderCommandSetBlendFactorAndStencilRef;
        c_bl.red = e->blend[0]; c_bl.green = e->blend[1]; c_bl.blue = e->blend[2]; c_bl.alpha = e->blend[3];
        c_bl.stencil_ref = (uint8_t)e->stencil_ref;
        MAD_APPEND(&c_bl);
    }
    c_ras = e->pso->raster;
    c_ras.next.ptr = NULL;
    MAD_APPEND(&c_ras);
    for (i = 0; i < 16; i++) {
        if (!(e->pso->vb_mask & (1u << i)) || !e->vb[i].res) continue;
        /* ml878: stride differences are handled by mad_pso_for_strides above */
    }
    if ((g_list_seq <= 3 || (g_list_seq >= 12000 && g_list_seq < 12400) || g_census_on) && g_dump_draws < 40000) {   /* ml893: ~3 frames mid-run */
        char line[1200]; int n; unsigned k;
        g_dump_draws++;
        n = snprintf(line, sizeof(line), "[draw-dump] list#%u enc#%u vs='%s' ps='%s' topo=%u%s rt=%u", g_list_seq, e->renc_seq,
                     e->pso->vs_name, e->pso->ps_name, (unsigned)e->topo, tv ? " TESS" : (e->pso->tess ? " tess-pso" : ""), e->enc_nrt);   /* ml1104: topology + tessellation */
        for (k = 0; k < e->enc_nrt && k < 8; k++) n += snprintf(line + n, sizeof(line) - n, "%s%ux%u/f%u", k ? "," : "[",
                     e->enc_rt[k] ? e->enc_rt[k]->width : 0, e->enc_rt[k] ? e->enc_rt[k]->height : 0,
                     e->enc_rt[k] ? (unsigned)e->enc_rt[k]->desc.Format : 0);
        if (e->enc_nrt) n += snprintf(line + n, sizeof(line) - n, "]");
        if (e->enc_depth)
            n += snprintf(line + n, sizeof(line) - n, " depth=%ux%u/f%u", e->enc_depth->width, e->enc_depth->height, (unsigned)e->enc_depth->desc.Format);
        else
            n += snprintf(line + n, sizeof(line) - n, " depth=n");
        n += snprintf(line + n, sizeof(line) - n, " cull=%u wind=%s dtest=%u/func%u/w%u st=%u/func%u/r%x/w%x/ref%u wm=%x%x%x%x%x%x vp=%g,%g,%gx%g,z%g-%g sc=%s%ld,%ld-%ld,%ld",
                      (unsigned)e->pso->raster.cull_mode, e->pso->raster.winding == WMTWindingCounterClockwise ? "ccw" : "cw",
                      e->pso->dbg_denable, e->pso->dbg_dfunc, e->pso->dbg_dwrite,
                      e->pso->dbg_senable, e->pso->dbg_sfunc, e->pso->dbg_srmask, e->pso->dbg_swmask, (unsigned)e->stencil_ref,
                      e->pso->dbg_wmask[0], e->pso->dbg_wmask[1], e->pso->dbg_wmask[2], e->pso->dbg_wmask[3], e->pso->dbg_wmask[4], e->pso->dbg_wmask[5],
                      e->has_vp ? e->vp.TopLeftX : -1.0f, e->has_vp ? e->vp.TopLeftY : -1.0f, e->has_vp ? e->vp.Width : 0.0f, e->has_vp ? e->vp.Height : 0.0f,
                      e->has_vp ? e->vp.MinDepth : 0.0f, e->has_vp ? e->vp.MaxDepth : 0.0f,
                      e->has_sc ? "" : "none", e->has_sc ? (long)e->sc.left : 0L, e->has_sc ? (long)e->sc.top : 0L, e->has_sc ? (long)e->sc.right : 0L, e->has_sc ? (long)e->sc.bottom : 0L);
        if (e->pso->blend[0]) n += snprintf(line + n, sizeof(line) - n, " blend='%s'", e->pso->blend);   /* ml1106 */
        n += snprintf(line + n, sizeof(line) - n, " srv=%s smp=%s nsrv=%u used=%u vb=[",
                      e->srv ? "y" : "n", e->smp ? "y" : "n", dev->nsrv, e->l->nused);
        for (k = 0; k < 16 && n < (int)sizeof(line) - 120; k++) if (e->vb[k].res)
            n += snprintf(line + n, sizeof(line) - n, " %u:off%llu/sz%llu/st%u%s", k, (unsigned long long)e->vb[k].off,
                          (unsigned long long)e->vb[k].res->size, e->vb[k].stride, e->vb[k].res->buffer ? "" : "(NOBUF)");
        n += snprintf(line + n, sizeof(line) - n, " ]");
        if (c->kind == MC_DRAW_INDIRECT || c->kind == MC_DRAW_INDEXED_INDIRECT)
            n += snprintf(line + n, sizeof(line) - n, " INDIRECT args-off=%llu", (unsigned long long)c->u.ind.off);
        else if (c->kind == MC_DRAW_INDEXED)
            n += snprintf(line + n, sizeof(line) - n, " ib=%s off%llu/sz%llu/%s idx=%u start=%u base=%d inst=%u",
                          e->ib ? "y" : "NONE", (unsigned long long)e->ib_off, e->ib ? (unsigned long long)e->ib->size : 0ull,
                          e->ib_type == WMTIndexTypeUInt32 ? "u32" : "u16", c->u.drawi.icount, c->u.drawi.start,
                          (int)c->u.drawi.base, c->u.drawi.inst);
        else
            n += snprintf(line + n, sizeof(line) - n, " draw vcount=%u start=%u inst=%u",
                          c->u.draw.vcount, c->u.draw.vstart, c->u.draw.icount);
        d3d12_log("%s\n", line);
    }
    if (tv && tv->is_gs) {   /* ml1147: DXMT's geometry draw -- warps of 30/32 vertices, one object threadgroup each, per instance */
        UINT count = c->kind == MC_DRAW_INDEXED ? c->u.drawi.icount : c->u.draw.vcount;
        UINT inst = c->kind == MC_DRAW_INDEXED ? c->u.drawi.inst : c->u.draw.icount;
        UINT vpw = 32, inc = 32, warps;
        static unsigned said_gsbig, said_gsdraw;
        if (!inst) inst = 1;
        switch (e->topo) {   /* DXMT get_gs_vertex_count(): {vertices per warp, advance per warp} */
        case D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST: case D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST_ADJ: vpw = 30; inc = 30; break;
        case D3D_PRIMITIVE_TOPOLOGY_LINESTRIP:          vpw = 32; inc = 31; break;
        case D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP:      vpw = 32; inc = 30; break;
        case D3D_PRIMITIVE_TOPOLOGY_LINESTRIP_ADJ:      vpw = 32; inc = 29; break;
        case D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP_ADJ:  vpw = 32; inc = 28; break;
        default: vpw = 32; inc = 32; break;
        }
        if (c->kind == MC_DRAW_INDEXED && (!e->ib || !e->ib->buffer)) { MAD_SKIP(e); tail->next.ptr = NULL; return; }
        if (!count) { tail->next.ptr = NULL; return; }   /* nothing to draw, not a failure */
        warps = (count - 1) / inc + 1;
        if ((UINT64)warps * inst > 0xffffffffull) {
            if (said_gsbig++ < 4) d3d12_log("[madeira-d3d12] ml1147 geometry draw too large: %u x %u object threadgroups; skipped\n", warps, inst);
            MAD_SKIP(e); tail->next.ptr = NULL; return;
        }
        if (c->kind == MC_DRAW_INDEXED) {
            memset(&c_gdi, 0, sizeof c_gdi); c_gdi.type = WMTRenderCommandDXMTGeometryDrawIndexed;
            c_gdi.draw_arguments_offset = gs_daboff; c_gdi.index_buffer = e->ib->buffer; c_gdi.index_buffer_offset = e->ib_off;
            c_gdi.warp_count = warps; c_gdi.instance_count = inst; c_gdi.vertex_per_warp = vpw;
            MAD_APPEND(&c_gdi);
        } else {
            memset(&c_gd, 0, sizeof c_gd); c_gd.type = WMTRenderCommandDXMTGeometryDraw;
            c_gd.draw_arguments_offset = gs_daboff; c_gd.warp_count = warps; c_gd.instance_count = inst; c_gd.vertex_per_warp = vpw;
            MAD_APPEND(&c_gd);
        }
        if (said_gsdraw++ < 8) d3d12_log("[madeira-d3d12] ml1147 geometry draw: %s %u x %u warps of %u, gs '%s'\n",
                                         c->kind == MC_DRAW_INDEXED ? "indexed" : "plain", warps, inst, vpw, tv->ds_name);
        InterlockedIncrement(&g_gs_drawn);
    } else if (tv) {   /* ml1083: one object threadgroup per (patches_per_group) patches, per instance */
        UINT ncp = (UINT)e->topo - (UINT)D3D_PRIMITIVE_TOPOLOGY_1_CONTROL_POINT_PATCHLIST + 1u;
        UINT count = c->kind == MC_DRAW_INDEXED ? c->u.drawi.icount : c->u.draw.vcount;
        UINT inst = c->kind == MC_DRAW_INDEXED ? c->u.drawi.inst : c->u.draw.icount;
        UINT tpp = tv->threads_per_patch, ppg, patches, ptg;
        static unsigned said_big;
        if (!inst) inst = 1;
        if (c->kind == MC_DRAW_INDEXED && (!e->ib || !e->ib->buffer)) { MAD_SKIP(e); tail->next.ptr = NULL; return; }
        if (!tpp || tpp > 32 || !ncp) { MAD_SKIP(e); tail->next.ptr = NULL; return; }
        patches = count / ncp;
        if (!patches) { tail->next.ptr = NULL; return; }   /* nothing to draw, not a failure */
        ppg = 32 / tpp;
        ptg = (patches - 1) / ppg + 1;
        if ((UINT64)ptg * inst > 0xffffffffull) {   /* Metal's grid is 32-bit per axis; DXMT warns the same way */
            if (said_big++ < 4) d3d12_log("[madeira-d3d12] ml1083 tessellation draw too large: %u x %u object threadgroups; skipped\n", ptg, inst);
            MAD_SKIP(e); tail->next.ptr = NULL; return;
        }
        memset(&c_mesh, 0, sizeof c_mesh); c_mesh.type = WMTRenderCommandDrawMeshThreadgroups;
        c_mesh.threadgroup_per_grid.width = ptg; c_mesh.threadgroup_per_grid.height = inst; c_mesh.threadgroup_per_grid.depth = 1;
        c_mesh.object_threadgroup_size.width = tpp; c_mesh.object_threadgroup_size.height = ppg; c_mesh.object_threadgroup_size.depth = 1;
        c_mesh.mesh_threadgroup_size.width = 32; c_mesh.mesh_threadgroup_size.height = 1; c_mesh.mesh_threadgroup_size.depth = 1;
        MAD_APPEND(&c_mesh);
        InterlockedIncrement(&g_tess_drawn);
        if (c->kind == MC_DRAW) InterlockedIncrement(&g_tess_nonidx);
    } else if (gsemu) {   /* ml927 */
        if (c->kind == MC_DRAW_INDEXED && (!e->ib || !e->ib->buffer)) { MAD_SKIP(e); tail->next.ptr = NULL; return; }
        MAD_APPEND(&c_mesh);
    } else if (c->kind == MC_DRAW_INDEXED_INDIRECT) {
        if (!e->ib || !e->ib->buffer) { MAD_SKIP(e); tail->next.ptr = NULL; return; }
        memset(&c_dii, 0, sizeof c_dii);
        c_dii.type = WMTRenderCommandDrawIndexedIndirect;
        c_dii.primitive_type = mad_prim(e->topo);
        c_dii.index_type = e->ib_type;
        c_dii.index_buffer = e->ib->buffer;
        c_dii.index_buffer_offset = e->ib_off;
        c_dii.indirect_args_buffer = c->u.ind.args->buffer;
        c_dii.indirect_args_offset = c->u.ind.off;
        MAD_APPEND(&c_dii);
    } else if (c->kind == MC_DRAW_INDIRECT) {
        memset(&c_di, 0, sizeof c_di);
        c_di.type = WMTRenderCommandDrawIndirect;
        c_di.primitive_type = mad_prim(e->topo);
        c_di.indirect_args_buffer = c->u.ind.args->buffer;
        c_di.indirect_args_offset = c->u.ind.off;
        MAD_APPEND(&c_di);
    } else if (c->kind == MC_DRAW_INDEXED) {
        if (!e->ib || !e->ib->buffer) { MAD_SKIP(e); tail->next.ptr = NULL; return; }
        memset(&c_dix, 0, sizeof c_dix);
        c_dix.type = WMTRenderCommandDrawIndexed;
        c_dix.primitive_type = mad_prim(e->topo);
        c_dix.index_type = e->ib_type;
        c_dix.index_count = c->u.drawi.icount;
        c_dix.index_buffer = e->ib->buffer;
        c_dix.index_buffer_offset = e->ib_off + (UINT64)c->u.drawi.start * (e->ib_type == WMTIndexTypeUInt32 ? 4 : 2);
        c_dix.instance_count = c->u.drawi.inst ? c->u.drawi.inst : 1;
        c_dix.base_vertex = c->u.drawi.base;
        c_dix.base_instance = c->u.drawi.istart;
        MAD_APPEND(&c_dix);
    } else {
        memset(&c_draw, 0, sizeof c_draw);
        c_draw.type = WMTRenderCommandDraw;
        c_draw.primitive_type = mad_prim(e->topo);
        c_draw.vertex_start = c->u.draw.vstart;
        c_draw.vertex_count = c->u.draw.vcount;
        c_draw.instance_count = c->u.draw.icount ? c->u.draw.icount : 1;
        c_draw.base_instance = c->u.draw.istart;
        MAD_APPEND(&c_draw);
    }
    {   /* ml1088: count this draw into the current slot while a query is open.
         * Placed last so a skipped draw above never leaves the encoder's mode
         * out of step with vis_prev. The mode command goes FIRST in the chain
         * (before the pipeline), which is where DXMT emits it too. */
        struct mad_vis_batch *v = e->q->vis;
        UINT64 want = (v && v->active && e->enc_vis_buf) ? v->next : ~(UINT64)0;
        if (want != e->vis_prev) {
            memset(&c_vis, 0, sizeof c_vis); c_vis.type = WMTRenderCommandSetVisibilityMode;
            if (want == ~(UINT64)0) { c_vis.mode = WMTVisibilityResultModeDisabled; c_vis.offset = 0; }
            else { c_vis.mode = WMTVisibilityResultModeCounting; c_vis.offset = (want % MAD_VIS_SLOTS) * 8; }
            c_vis.next.ptr = &c_pso;
            e->vis_prev = want;
            tail->next.ptr = NULL;
            MTLRenderCommandEncoder_encodeCommands(e->renc, (const struct wmtcmd_base *)&c_vis);
        } else {
            tail->next.ptr = NULL;
            MTLRenderCommandEncoder_encodeCommands(e->renc, (const struct wmtcmd_base *)&c_pso);
        }
        if (want != ~(UINT64)0) v->dirty = 1;
    }
    mad_use_commit(e);   /* this draw's useResource entries reached the encoder */
#undef MAD_APPEND
    e->draws++; e->pass_draws++;   /* ml1098 */
    if (e->nrt && e->rt[0] && e->rtp[0].layers > 1) {   /* ml926: layered draws */
        static unsigned said;
        if (said++ < 24)
            d3d12_log("[layered-draw] list#%u vs='%s' ps='%s' rt0=%s %ux%u t%u pf%u layers %u first %u | %s vcount=%u inst=%u\n", g_list_seq,
                      e->pso ? e->pso->vs_name : "?", e->pso ? e->pso->ps_name : "?", e->rt[0]->name, e->rt[0]->width, e->rt[0]->height,
                      (unsigned)e->rt[0]->tex_type, (unsigned)e->rt[0]->tex_pf, e->rtp[0].layers, e->rt[0]->tex_type == WMTTextureType3D ? e->rtp[0].plane : e->rtp[0].slice,
                      c->kind == MC_DRAW ? "draw" : "drawi", c->kind == MC_DRAW ? c->u.draw.vcount : c->u.drawi.icount,
                      c->kind == MC_DRAW ? c->u.draw.icount : c->u.drawi.inst);
        static unsigned k14_done;   /* ml928: at most four in the whole run; g_cap_kinds resets every flush and this burnt the capture budget */
        if (k14_done < 4 && !(g_cap_kinds & (1u << 14)) && e->q->device->cap_total < 2000) {
            char lab[160]; UINT mid = e->rtp[0].layers / 2;
            g_cap_kinds |= 1u << 14; k14_done++;
            snprintf(lab, sizeof lab, "K14 OUT after layered '%s' %s %ux%u pf%u slice0", e->pso ? e->pso->vs_name : "?", e->rt[0]->name, e->rt[0]->width, e->rt[0]->height, (unsigned)e->rt[0]->tex_pf);
            exec_capture_texels(e, lab, e->rt[0], 0, 0);
            snprintf(lab, sizeof lab, "K14 OUT after layered '%s' %s %ux%u pf%u slice%u", e->pso ? e->pso->vs_name : "?", e->rt[0]->name, e->rt[0]->width, e->rt[0]->height, (unsigned)e->rt[0]->tex_pf, mid);
            exec_capture_texels(e, lab, e->rt[0], mid, 0);
        }
    }
    if (e->cap_after) {   /* ml918: the output of this draw, before anything else touches it */
        char lab[160]; unsigned kk = e->cap_after; e->cap_after = 0;
        if (e->rt[0]) { snprintf(lab, sizeof lab, "K%u OUT rt0 %s %ux%u pf%u", kk, e->rt[0]->name, e->rt[0]->width, e->rt[0]->height, (unsigned)e->rt[0]->tex_pf);
                        exec_capture_texels(e, lab, e->rt[0], 0, 0); }
    }
}

#define MAD_FILLPAT_BYTES (256u << 10)   /* ml1151: one exact UAV-clear pattern buffer */
static void exec_copy(struct mad_exec *e, const struct mad_cmd *c) {
    if (!exec_begin_blit(e)) { MAD_SKIP(e); return; }
    switch (c->kind) {   /* ml1116: the destination is written */
    case MC_FILL_BB: exec_note_write(e, c->u.fill.res); break;
    case MC_COPY_BB: exec_note_write(e, c->u.bb.dst); break;
    default: e->wr_all = 1; break;   /* texture copies: destination fields differ per kind; be conservative */
    }
    switch (c->kind) {
    case MC_FILL_BB: {
        struct wmtcmd_blit_fillbuffer k;
        if (!c->u.fill.res->buffer) { MAD_SKIP(e); return; }
        if (c->u.fill.pattern) {   /* ml1151: a value whose bytes differ, copied from its pattern buffer */
            struct wmtcmd_blit_copy_from_buffer_to_buffer cp; UINT64 o;
            for (o = 0; o < c->u.fill.len; o += MAD_FILLPAT_BYTES) {
                memset(&cp, 0, sizeof cp);
                cp.type = WMTBlitCommandCopyFromBufferToBuffer;
                cp.src = c->u.fill.pattern; cp.src_offset = 0;
                cp.dst = c->u.fill.res->buffer; cp.dst_offset = c->u.fill.off + o;
                cp.copy_length = c->u.fill.len - o < MAD_FILLPAT_BYTES ? c->u.fill.len - o : MAD_FILLPAT_BYTES;
                MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&cp);
            }
            return;
        }
        memset(&k, 0, sizeof k);
        k.type = WMTBlitCommandFillBuffer;
        k.buffer = c->u.fill.res->buffer; k.offset = c->u.fill.off; k.length = c->u.fill.len; k.value = c->u.fill.byte;
        MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
        return;
    }
    case MC_COPY_BB: {
        struct wmtcmd_blit_copy_from_buffer_to_buffer k;
        if (!c->u.bb.dst->buffer || !c->u.bb.src->buffer) { MAD_SKIP(e); return; }
        memset(&k, 0, sizeof k);
        k.type = WMTBlitCommandCopyFromBufferToBuffer;
        k.src = c->u.bb.src->buffer; k.src_offset = c->u.bb.soff;
        k.dst = c->u.bb.dst->buffer; k.dst_offset = c->u.bb.doff;
        k.copy_length = c->u.bb.len;
        MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
        return;
    }
    case MC_COPY_B2T: {
        struct wmtcmd_blit_copy_from_buffer_to_texture k;
        if (!c->u.bt.tex->texture || !c->u.bt.buf->buffer) { MAD_SKIP(e); return; }
        memset(&k, 0, sizeof k);
        k.type = WMTBlitCommandCopyFromBufferToTexture;
        k.src = c->u.bt.buf->buffer; k.src_offset = c->u.bt.off;
        k.bytes_per_row = c->u.bt.row; k.bytes_per_image = c->u.bt.row * c->u.bt.rows;
        k.size.width = c->u.bt.w; k.size.height = c->u.bt.h; k.size.depth = c->u.bt.d;
        k.dst = c->u.bt.tex->texture; k.slice = c->u.bt.slice; k.level = c->u.bt.level;
        k.origin.x = c->u.bt.x; k.origin.y = c->u.bt.y; k.origin.z = c->u.bt.z;
        MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
        return;
    }
    case MC_COPY_T2B: {
        struct wmtcmd_blit_copy_from_texture_to_buffer k;
        if (!c->u.bt.tex->texture || !c->u.bt.buf->buffer) { MAD_SKIP(e); return; }
        memset(&k, 0, sizeof k);
        k.type = WMTBlitCommandCopyFromTextureToBuffer;
        k.src = c->u.bt.tex->texture; k.slice = c->u.bt.slice; k.level = c->u.bt.level;
        k.origin.x = c->u.bt.x; k.origin.y = c->u.bt.y; k.origin.z = c->u.bt.z;
        k.size.width = c->u.bt.w; k.size.height = c->u.bt.h; k.size.depth = c->u.bt.d;
        k.dst = c->u.bt.buf->buffer; k.offset = c->u.bt.off;
        k.bytes_per_row = c->u.bt.row; k.bytes_per_image = c->u.bt.row * c->u.bt.rows;
        MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
        return;
    }
    case MC_COPY_T2T: {
        struct wmtcmd_blit_copy_from_texture_to_texture k;
        if (!c->u.tt.dst->texture || !c->u.tt.src->texture) { MAD_SKIP(e); return; }
        memset(&k, 0, sizeof k);
        k.type = WMTBlitCommandCopyFromTextureToTexture;
        k.src = c->u.tt.src->texture; k.src_slice = c->u.tt.sslice; k.src_level = c->u.tt.slevel;
        k.src_origin.x = c->u.tt.sx; k.src_origin.y = c->u.tt.sy; k.src_origin.z = c->u.tt.sz;
        k.src_size.width = c->u.tt.w; k.src_size.height = c->u.tt.h; k.src_size.depth = c->u.tt.d;
        k.dst = c->u.tt.dst->texture; k.dst_slice = c->u.tt.dslice; k.dst_level = c->u.tt.dlevel;
        k.dst_origin.x = c->u.tt.dx; k.dst_origin.y = c->u.tt.dy; k.dst_origin.z = c->u.tt.dz;
        MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
        return;
    }
    default: return;
    }
}

static int mad_texinfo_from_desc(const D3D12_RESOURCE_DESC *desc, struct WMTTextureInfo *ti, enum WMTPixelFormat *pf, int *is_depth);

/* ResolveSubresource. Metal resolves as the store action of a render pass, so
 * this is a pass of its own with nothing drawn: load the multisampled source,
 * keep it, and resolve into the destination. A clear still pending on either
 * texture has to land first or the pass would load stale contents.
 *
 * Metal only resolves into a texture with render-target usage, which a D3D12
 * resolve destination need not have. Such a destination gets a stand-in of
 * the subresource's size that is resolved into and then copied from.
 *
 * Metal also wants the resolve texture in the source attachment's pixel
 * format, while D3D12 resolves between sRGB/linear and typeless pairs (an
 * sRGB multisampled target into a UNORM back buffer is common). When the
 * formats differ, the destination subresource is resolved (or copied) through
 * a view of it in the source's format; every texture here has PixelFormatView
 * usage. Formats of different sizes cannot be viewed as each other: skipped. */
static obj_handle_t mad_resolve_view(struct mad_resource *r, enum WMTPixelFormat pf, UINT level, UINT slice) {
    struct WMTTextureSwizzleChannels sw;
    uint64_t id = 0;
    sw.r = (enum WMTTextureSwizzle)2; sw.g = (enum WMTTextureSwizzle)3;   /* identity, as MAD_SWZ_IDENTITY */
    sw.b = (enum WMTTextureSwizzle)4; sw.a = (enum WMTTextureSwizzle)5;
    return MTLTexture_newTextureView(r->texture, pf, WMTTextureType2D, (uint16_t)level, 1, (uint16_t)slice, 1, sw, &id);
}

static void exec_resolve(struct mad_exec *e, const struct mad_cmd *c) {
    struct mad_resource *src = c->u.tt.src, *dst = c->u.tt.dst;
    struct WMTRenderPassInfo rpi;
    obj_handle_t enc, target = dst->texture, dview = 0;
    enum WMTPixelFormat spf = src->tex_pf;
    UINT w = src->width >> c->u.tt.slevel, h = src->height >> c->u.tt.slevel;
    UINT dlevel = c->u.tt.dlevel, dslice = c->u.tt.dslice;
    int direct = dst->borrowed || (dst->desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
    static unsigned said_pf;
    if (!w) w = 1;
    if (!h) h = 1;
    if (!src->texture || !dst->texture || src->is_depth || dst->is_depth) { MAD_SKIP(e); return; }
    if (dst->tex_pf != spf) {
        if (mad_pf_bytes((UINT)dst->tex_pf) != mad_pf_bytes((UINT)spf) || !(dview = mad_resolve_view(dst, spf, dlevel, dslice))) {
            if (said_pf++ < 4)
                d3d12_log("[madeira-d3d12] ResolveSubresource skipped: Metal format %u cannot be resolved into %u\n",
                          (unsigned)spf, (unsigned)dst->tex_pf);
            MAD_SKIP(e); return;
        }
        target = dview; dlevel = 0; dslice = 0;
    }
    if (!direct) {
        if (dst->resolve_tmp && (dst->resolve_tmp_w != w || dst->resolve_tmp_h != h || dst->resolve_tmp_pf != (UINT)spf)) {
            NSObject_release(dst->resolve_tmp);
            dst->resolve_tmp = 0;
        }
        if (!dst->resolve_tmp) {
            D3D12_RESOURCE_DESC td = dst->desc;
            struct WMTTextureInfo ti; enum WMTPixelFormat pf; int is_depth = 0;
            td.Width = w; td.Height = h; td.DepthOrArraySize = 1; td.MipLevels = 1;
            td.SampleDesc.Count = 1; td.Flags |= D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
            if (mad_texinfo_from_desc(&td, &ti, &pf, &is_depth)) {
                ti.pixel_format = spf;   /* resolved in the source's format, copied as it */
                dst->resolve_tmp = MTLDevice_newTexture(e->q->device->mtl_device, &ti);
                dst->resolve_tmp_w = w; dst->resolve_tmp_h = h; dst->resolve_tmp_pf = (UINT)spf;
            }
        }
        if (!dst->resolve_tmp) { if (dview) NSObject_release(dview); MAD_SKIP(e); return; }
        target = dst->resolve_tmp;
    }
    exec_end(e);
    while (e->npend) exec_flush_clear(e, 0);
    e->wr_all = 1;
    memset(&rpi, 0, sizeof rpi);
    rpi.colors[0].texture = src->texture;
    rpi.colors[0].level = c->u.tt.slevel; rpi.colors[0].slice = c->u.tt.sslice;
    rpi.colors[0].load_action = WMTLoadActionLoad;
    rpi.colors[0].store_action = WMTStoreActionStoreAndMultisampleResolve;
    rpi.colors[0].resolve_texture = target;
    if (direct) { rpi.colors[0].resolve_level = dlevel; rpi.colors[0].resolve_slice = dslice; }
    rpi.render_target_width = w; rpi.render_target_height = h;
    rpi.default_raster_sample_count = src->samples;
    enc = MTLCommandBuffer_renderCommandEncoder(e->cb, &rpi); if (enc) g_enc_seq++;
    e->f6_att[0] = src; e->f6_att[1] = dst; e->f6_natt = 2;
    if (enc) { exec_fence_render(e, enc, 0); exec_fence_render(e, enc, 1); }
    e->f6_natt = 0;
    if (!enc) { if (dview) NSObject_release(dview); MAD_SKIP(e); return; }
    MTLCommandEncoder_endEncoding(enc);
    if (!direct) {
        struct wmtcmd_blit_copy_from_texture_to_texture k;
        if (!exec_begin_blit(e)) { if (dview) NSObject_release(dview); MAD_SKIP(e); return; }
        memset(&k, 0, sizeof k);
        k.type = WMTBlitCommandCopyFromTextureToTexture;
        k.src = target;
        k.src_size.width = w; k.src_size.height = h; k.src_size.depth = 1;
        k.dst = dview ? dview : dst->texture; k.dst_slice = dslice; k.dst_level = dlevel;
        MTLBlitCommandEncoder_encodeCommands(e->benc, (const struct wmtcmd_base *)&k);
    }
    /* The command buffer keeps the view alive until it has run. */
    if (dview) NSObject_release(dview);
}

static void exec_dispatch(struct mad_exec *e, const struct mad_cmd *c) {
    struct wmtcmd_compute_setpso c_pso;
    e->wr_all = 1;   /* ml1116: a dispatch writes through UAVs we do not enumerate here */
    struct wmtcmd_compute_setbuffer sb[4];   /* ml1008: MSC uses 3; the sm5 path binds cb + arg + both heaps */
    struct wmtcmd_compute_useresource ur[256];
    struct wmtcmd_compute_dispatch c_disp;
    struct wmtcmd_compute_dispatch_indirect c_dispi;
    struct wmtcmd_base *tail;
    obj_handle_t argbuf = 0; UINT64 argoff = 0;
    obj_handle_t air_cb = 0, air_arg = 0; UINT64 air_cboff = 0, air_argoff = 0;   /* ml1008 */
    unsigned nsb = 0, nur = 0, i;
    struct mad_device *dev = e->q->device;
    static unsigned said_nopso;
    if (!e->cpso || !e->cpso->cps) {
        if (!said_nopso++) d3d12_log("[madeira-d3d12] Dispatch without a compute pipeline; skipped\n");
        MAD_SKIP(e);
        return;
    }
    /* ml930: pre-dispatch captures FIRST. exec_capture_cs blits through
     * exec_begin_blit, which ends every open encoder; doing it after the
     * compute encoder was created left e->cenc = 0 and the dispatch encoded
     * into nothing (the host took 0 as nil and did no work). Every compute
     * measurement in a census frame, and the census frames themselves, were
     * wrong because of that (Astra, 2026-09-16). */
    if (g_census_on) exec_capture_cs(e, c);   /* ml920 */
    if (g_capture_on && g_capture_cs[0] && g_capture_cs_shots < g_capture_cs_max && e->cpso->backend != MADEIRA_IR_BACKEND_AIRCONV &&
        (!g_capture_cs_ind || c->kind == MC_DISPATCH_INDIRECT) && !strcmp(e->cpso->vs_name, g_capture_cs)) {   /* ml1141 */
        g_capture_cs_shots++;
        mad_capture_dispatch_inputs(e, c);
    }
    if (!e->cenc) {
        if (e->renc) InterlockedIncrement(&g_pass_end_dispatch);
        exec_end(e);
        e->cenc = MTLCommandBuffer_computeCommandEncoder(e->cb, false); if (e->cenc) g_enc_seq++;
        if (g_enc_labels) mad_label(e->cenc, "C#%u %s", g_enc_seq, e->cpso->vs_name);   /* ml1142 */
        if (!e->cenc) { d3d12_log("[madeira-d3d12] no compute encoder\n"); MAD_SKIP(e); return; }
        exec_fence_compute(e, e->cenc, 0);   /* ml1091 */
    }
    /* ml1008: a pipeline built by the DXBC backend reads two argument buffers of
     * its own at fixed Metal indices, not the converter's top-level layout.
     * Build those instead; a range that cannot be resolved fails the dispatch
     * with a named reason rather than running against a half-filled table. */
    if (e->cpso->backend == MADEIRA_IR_BACKEND_AIRCONV) {
        static unsigned said_air_disp;
        if (!mad_air_build_tables(e, e->crs, e->croot, (const UINT32 (*)[64])e->cconsts,
                                  e->cpso, 0, &air_cb, &air_cboff, &air_arg, &air_argoff)) {
            MAD_SKIP(e); return;
        }
        if (said_air_disp++ < 8)
            d3d12_log("[madeira-d3d12] ml1008 dispatching '%s' through the sm5 tables "
                      "(cb@%u arg@%u, %u qwords, %u ranges)\n", e->cpso->vs_name,
                      e->cpso->cb_bind, e->cpso->arg_bind, e->cpso->arg_qwords, e->cpso->nair);
    } else {
        if (!exec_arg_slot_for(e, e->crs, e->croot, (const UINT32 (*)[64])e->cconsts, &argbuf, &argoff,
                               e->cpso->has_root_off ? e->cpso->root_off : NULL, e->cpso)) { MAD_SKIP(e); return; }
        if (g_census_on) exec_desc_check(e, e->crs, e->croot, e->cpso->vs_name);   /* ml913 */
    }

    if (((g_list_seq >= 12000 && g_list_seq < 12400) || g_census_on) && g_dump_draws < 40000) {   /* ml893 census + ml898 in-game window */
        g_dump_draws++;
        d3d12_log("[dispatch-dump] list#%u '%s' %s %ux%ux%u\n", g_list_seq, e->cpso->vs_name,
                  c->kind == MC_DISPATCH_INDIRECT ? "indirect" : "", c->u.dispatch.x, c->u.dispatch.y, c->u.dispatch.z);
    }
    memset(&c_pso, 0, sizeof c_pso);
    c_pso.type = WMTComputeCommandSetPSO; c_pso.pso = e->cpso->cps;
    c_pso.threadgroup_size.width = e->cpso->tg[0]; c_pso.threadgroup_size.height = e->cpso->tg[1]; c_pso.threadgroup_size.depth = e->cpso->tg[2];
    tail = (struct wmtcmd_base *)&c_pso;
#define MAD_APPEND(node) do { tail->next.ptr = (node); tail = (struct wmtcmd_base *)(node); } while (0)
    memset(sb, 0, sizeof sb);
#define MAD_CSETBUF(buf_, off_, idx_) do { sb[nsb].type = WMTComputeCommandSetBuffer; sb[nsb].buffer = (buf_); \
        sb[nsb].offset = (off_); sb[nsb].index = (idx_); MAD_APPEND(&sb[nsb]); nsb++; } while (0)
    if (e->cpso->backend == MADEIRA_IR_BACKEND_AIRCONV) {   /* ml1008 */
        if (air_cb)  MAD_CSETBUF(air_cb,  air_cboff,  e->cpso->cb_bind);
        if (air_arg) MAD_CSETBUF(air_arg, air_argoff, e->cpso->arg_bind);
        /* The heaps still have to be resident: the tables reference descriptors
         * and resources by raw address and id, not through a bound heap. */
    } else {
        MAD_CSETBUF(argbuf, argoff, 2);
        if (e->srv && e->srv->buffer) MAD_CSETBUF(e->srv->buffer, 0, 0);
        if (e->smp && e->smp->buffer) MAD_CSETBUF(e->smp->buffer, 0, 1);
    }
#undef MAD_CSETBUF
    /* ml1130: no 8 KB clear per dispatch; each entry is zeroed as it is used */
    mad_use_begin(e, e->cenc);   /* one declaration per resource and encoder */
#define MAD_CUSE(h, u) do { if ((h) && nur < 256 && !mad_use_seen(e, e->cenc, (h), (UINT32)(u), 0)) { \
        memset(&ur[nur], 0, sizeof ur[nur]); ur[nur].type = WMTComputeCommandUseResource; ur[nur].resource = (h); \
        ur[nur].usage = (u); MAD_APPEND(&ur[nur]); nur++; } } while (0)
    if (e->srv) MAD_CUSE(e->srv->buffer, WMTResourceUsageRead);
    if (e->smp) MAD_CUSE(e->smp->buffer, WMTResourceUsageRead);
    for (i = e->l->nused > 64 ? e->l->nused - 64 : 0; i < e->l->nused; i++) {
        struct mad_resource *r = e->l->used[i];
        if (r) MAD_CUSE(r->texture ? r->texture : r->buffer, (enum WMTResourceUsage)(WMTResourceUsageRead | WMTResourceUsageWrite));
    }
    const int ml1060_cskip = dev->resset && dev->nsrv > 256;   /* same reasoning as exec_draw */
    if (!ml1060_cskip) AcquireSRWLockShared(&dev->list_lock);
    for (i = 0; !ml1060_cskip && i < dev->nsrv && nur < 256; i++) { struct mad_resource *r = dev->srv_res[i]; if (r) MAD_CUSE(r->texture ? r->texture : r->buffer, WMTResourceUsageRead); }
    for (i = 0; !ml1060_cskip && i < dev->nuav && nur < 256; i++) { struct mad_resource *r = dev->uav_res[i]; if (r) MAD_CUSE(r->texture ? r->texture : r->buffer, (enum WMTResourceUsage)(WMTResourceUsageRead | WMTResourceUsageWrite)); }
    if (!ml1060_cskip) ReleaseSRWLockShared(&dev->list_lock);
#undef MAD_CUSE
    if (c->kind == MC_DISPATCH_INDIRECT) {
        memset(&c_dispi, 0, sizeof c_dispi);
        c_dispi.type = WMTComputeCommandDispatchIndirect;
        c_dispi.indirect_args_buffer = c->u.ind.args->buffer;
        c_dispi.indirect_args_offset = c->u.ind.off;
        MAD_APPEND(&c_dispi);
    } else {
        memset(&c_disp, 0, sizeof c_disp);
        c_disp.type = WMTComputeCommandDispatch;
        c_disp.size.width = c->u.dispatch.x; c_disp.size.height = c->u.dispatch.y; c_disp.size.depth = c->u.dispatch.z;
        MAD_APPEND(&c_disp);
    }
    tail->next.ptr = NULL;
#undef MAD_APPEND
    MTLComputeCommandEncoder_encodeCommands(e->cenc, (const struct wmtcmd_base *)&c_pso);
    mad_use_commit(e);
    e->draws++;
    if (e->ncap_after_buf) {   /* ml922 */
        unsigned j; for (j = 0; j < e->ncap_after_buf; j++) exec_capture_bytes(e, e->cap_after_buf[j].label, e->cap_after_buf[j].r, e->cap_after_buf[j].off, 64, 15);
        e->ncap_after_buf = 0;
    }
    if (e->ncap_after_tex) {   /* ml924 */
        unsigned j; for (j = 0; j < e->ncap_after_tex; j++) exec_capture_texels(e, e->cap_after_tex[j].label, e->cap_after_tex[j].r, e->cap_after_tex[j].slice, 0);
        e->ncap_after_tex = 0;
    }
    if (e->cap_after_cs) {   /* ml920: the texture this dispatch was chosen for, right after it */
        char lab[160]; struct mad_resource *r = e->cap_after_cs; e->cap_after_cs = NULL;
        snprintf(lab, sizeof lab, "K9 OUT after '%s' %s %ux%u pf%u", e->cpso->vs_name, r->name, r->width, r->height, (unsigned)r->tex_pf);
        exec_capture_texels(e, lab, r, 0, 0);
        snprintf(lab, sizeof lab, "K9 OUT after '%s' %s at (100,100)", e->cpso->vs_name, r->name);
        exec_capture_region(e, lab, r, 0, 0, 100, 100, 4, 4, 0);
    }
}

static void mad_exec_list(struct mad_queue *q, struct mad_list *l, obj_handle_t cb) {
    g_list_seq++;
    struct mad_exec e;
    unsigned i;
    memset(&e, 0, sizeof e);
    e.fence_needed = 1;   /* ml1111: the first encoder of a list waits for whatever ran before it */
    e.f6_sync_needed = 1; e.f6_list_start = 1;   /* ml1134: and, in mode 6, for the device fence too */
    e.mode = mad_fence_mode(q->device);          /* ml1136: fixed for the whole list */
    e.f7_reason = 2;                             /* ml1137: list start */
    e.q = q; e.l = l; e.cb = cb;
    e.vis_prev = ~(UINT64)0;   /* ml1088 */
    l->ring_q = q; l->ring_batch = q->batches + 1;   /* ml1061: the batch this replay belongs to */
    e.topo = D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST;
    for (i = 0; i < l->ncmds; i++) {
        const struct mad_cmd *c = &l->cmds[i];
        e.cur = i;   /* ml1137 */
        switch (c->kind) {
        case MC_PSO: if (c->u.pso && c->u.pso->is_compute) e.cpso = c->u.pso; else e.pso = c->u.pso; break;
        case MC_CROOTSIG: e.crs = c->u.rootsig; break;
        case MC_CROOT: if (c->u.root.index < MAD_ROOT_PARAM_MAX) e.croot[c->u.root.index] = c->u.root.value; break;
        case MC_CROOT_CONST:
            if (c->u.rconst.index < MAD_ROOT_PARAM_MAX && c->u.rconst.dst + c->u.rconst.n <= 64)
                memcpy(&e.cconsts[c->u.rconst.index][c->u.rconst.dst], &l->cdata[c->u.rconst.data], c->u.rconst.n * 4);
            break;
        case MC_ROOT:
            if (c->u.root.index < MAD_ROOT_PARAM_MAX) {
                e.root[c->u.root.index] = c->u.root.value;
                if (c->u.root.index + 1 > e.nroot) e.nroot = c->u.root.index + 1;
            }
            break;
        case MC_HEAPS: if (c->u.heaps.srv) e.srv = c->u.heaps.srv; if (c->u.heaps.smp) e.smp = c->u.heaps.smp; break;
        case MC_VP: e.vp = c->u.vp; e.has_vp = 1; break;
        case MC_SCISSOR: e.sc = c->u.scissor; e.has_sc = 1; break;
        case MC_TOPO: e.topo = c->u.topo; break;
        case MC_IB: e.ib = c->u.ib.res; e.ib_off = c->u.ib.off; e.ib_type = c->u.ib.type; break;
        case MC_VB: if (c->u.vb.slot < 16) { e.vb[c->u.vb.slot].res = c->u.vb.res; e.vb[c->u.vb.slot].off = c->u.vb.off; e.vb[c->u.vb.slot].stride = c->u.vb.stride; } break;
        case MC_RTS:
            /* ml934d: D3D12 begins a new render pass at every OMSetRenderTargets.
             * For passes WITH attachments we reuse the encoder when the bindings
             * match, which is a real win. Attachment-less passes have nothing to
             * compare, so consecutive ones were landing in ONE encoder -- and
             * Metal tracks hazards only BETWEEN encoders, never within one. UE's
             * cull chain is exactly "pass writes a list, next pass reads it", so
             * the reader could see a list the writer had not finished. That races
             * differently every frame, which is what made parts of the geometry
             * blink in and out. Close the encoder whenever either side of the
             * boundary is attachment-less. */
            if (e.renc && ((!c->u.rts.n && !c->u.rts.depth) || (!e.enc_nrt && !e.enc_depth))) {
                InterlockedIncrement(&g_pass_end_attachless);
                exec_end(&e);
            }
            memcpy(e.rt, c->u.rts.rt, sizeof e.rt); e.nrt = c->u.rts.n; e.depth = c->u.rts.depth;
            memcpy(e.rtp, c->u.rts.v, sizeof e.rtp); e.dp = c->u.rts.dv;   /* ml925 */
            break;
        case MC_CLEAR_RT: exec_add_clear(&e, c->u.clear.res, &c->u.clear.v, c->u.clear.rgba, 0.0f, 0, 0, 0); break;
        case MC_CLEAR_DS: exec_add_clear(&e, c->u.clear.res, &c->u.clear.v, NULL, c->u.clear.depth, 1, c->u.clear.stencil, c->u.clear.flags); break;
        case MC_ROOTSIG: e.rs = c->u.rootsig; break;
        case MC_ROOT_CONST:
            if (c->u.rconst.index < MAD_ROOT_PARAM_MAX && c->u.rconst.dst + c->u.rconst.n <= 64)
                memcpy(&e.consts[c->u.rconst.index][c->u.rconst.dst], &l->cdata[c->u.rconst.data], c->u.rconst.n * 4);
            break;
        case MC_STENCIL_REF: e.stencil_ref = c->u.stencil_ref; break;
        case MC_BARRIER:   /* ml1091; ml1098: madeira.cfg barrier-render = 1 closes the render pass too (Astra's conservative experiment) */
            if (g_barrier_render < 0) { g_barrier_render = mad_cfg_int_pe("barrier-render", 0) ? 1 : 0;
                                        d3d12_log("[madeira-d3d12] ml1098 barrier-render = %d (render passes %s at ResourceBarrier)\n", g_barrier_render, g_barrier_render ? "CLOSED" : "left open"); }
            InterlockedIncrement(&g_barrier_seen);   /* ml1116 */
            if (e.mode == 6) {   /* ml1134: see f6_begin */
                f7_census_barrier(&e, c);   /* ml1137: counts only */
                if (g_f6_compute_open < 0) g_f6_compute_open = mad_cfg_int_pe("f6-compute-open", 1) ? 1 : 0;
                e.f6_sync_needed = 1;
                if (e.cenc && e.f6_enc_synced && g_f6_compute_open) InterlockedIncrement(&g_f6_kept_open);
                else if (e.cenc || e.benc) exec_end(&e);
                if (e.renc && (!e.f6_enc_synced || g_barrier_render)) {
                    InterlockedIncrement(&g_barrier_renc_closed);
                    if (!e.f6_enc_synced) InterlockedIncrement(&g_f6_rclose);   /* costs a store + reload of its attachments */
                    exec_end(&e);
                }
                break;
            }
            if (e.mode == 3) {   /* ml1116: only if a transitioned resource was written since the last wait */
                unsigned bi, wi; int hit = c->u.barrier.all || e.wr_all;
                for (bi = 0; bi < c->u.barrier.n && !hit; bi++)
                    for (wi = 0; wi < e.nwr; wi++) if (e.wr[wi] == c->u.barrier.res[bi]) { hit = 1; break; }
                if (hit) e.fence_needed = 1;
            } else e.fence_needed = 1;   /* ml1111 */
            if (e.cenc || e.benc || (g_barrier_render && e.renc)) { if (e.renc) InterlockedIncrement(&g_barrier_renc_closed); exec_end(&e); }
            break;
        case MC_QUERY_BEGIN: exec_query_begin(&e, c); break;     /* ml1088 */
        case MC_QUERY_END: exec_query_end(&e, c); break;
        case MC_QUERY_RESOLVE: exec_query_resolve(&e, c); break;
        case MC_DRAW: case MC_DRAW_INDEXED: exec_draw(&e, c); break;
        case MC_DRAW_INDIRECT: case MC_DRAW_INDEXED_INDIRECT: case MC_DISPATCH_INDIRECT: {
            struct mad_cmd t = *c; UINT k;
            if (!c->u.ind.args || !c->u.ind.args->buffer) { e.skipped++; break; }
            for (k = 0; k < c->u.ind.count; k++) {
                t.u.ind.off = c->u.ind.off + (UINT64)k * c->u.ind.stride;
                if (c->kind == MC_DISPATCH_INDIRECT) exec_dispatch(&e, &t); else exec_draw(&e, &t);
            }
            break;
        }
        case MC_COPY_BB: case MC_COPY_B2T: case MC_COPY_T2B: case MC_COPY_T2T: case MC_FILL_BB: exec_copy(&e, c); break;
        case MC_BLEND_FACTOR: memcpy(e.blend, c->u.blend.rgba, sizeof e.blend); e.has_blend = 1; break;
        case MC_DISPATCH: exec_dispatch(&e, c); break;
        case MC_RESOLVE: exec_resolve(&e, c); break;
        }
    }
    if (e.renc) InterlockedIncrement(&g_pass_end_list);
    exec_end(&e);
    while (e.npend) exec_flush_clear(&e, 0);
    /* ml1042: a PERIODIC summary. Every per-list line is rate-limited to the first
     * dozen, which is the menu -- so the first run to reach real 3D (black, ~2 FPS)
     * left nothing in the log about what the scene actually submitted. One line
     * per 600 lists costs nothing and says whether the scene draws at all. */
    {
        static LONG acc_lists, acc_cmds, acc_draws, acc_skipped, acc_max_draws;
        LONG n = InterlockedIncrement(&acc_lists);
        InterlockedExchangeAdd(&acc_cmds, (LONG)l->ncmds);
        InterlockedExchangeAdd(&acc_draws, (LONG)e.draws);
        InterlockedExchangeAdd(&acc_skipped, (LONG)e.skipped);
        if ((LONG)e.draws > acc_max_draws) acc_max_draws = (LONG)e.draws;
        if ((n % 600) == 0) {
            d3d12_log("[madeira-d3d12] ml1042 last 600 lists: %ld commands, %ld draws (%ld skipped), "
                      "largest list %ld draws\n",
                      InterlockedExchange(&acc_cmds, 0), InterlockedExchange(&acc_draws, 0),
                      InterlockedExchange(&acc_skipped, 0), InterlockedExchange(&acc_max_draws, 0));
            d3d12_log("[madeira-d3d12] ml1070 render passes in those lists: %ld begun (%ld reused), ended by: targets %ld, clear %ld, "
                      "dispatch %ld, blit %ld, list-end %ld, attachless %ld; clear-only passes %ld; attachment load+store ~%lld MB\n",
                      InterlockedExchange(&g_pass_begun, 0), InterlockedExchange(&g_pass_reused, 0), InterlockedExchange(&g_pass_end_rts, 0),
                      InterlockedExchange(&g_pass_end_clear, 0), InterlockedExchange(&g_pass_end_dispatch, 0), InterlockedExchange(&g_pass_end_blit, 0),
                      InterlockedExchange(&g_pass_end_list, 0), InterlockedExchange(&g_pass_end_attachless, 0), InterlockedExchange(&g_pass_clear_only, 0),
                      (long long)(InterlockedExchange64(&g_pass_attach_bytes, 0) >> 20));
            if ((n % 3000) == 0) mad_skip_report();   /* ml1049 */
        }
    }
    /* ml1150: the memory census on a clock, not a list count. A title that dies
     * in its loading screen (ph-valley06/07: jetsam with Nanite on) never reaches
     * list 3000, so ml1057 never printed and the GPU share of the footprint was a
     * guess. Every 5 s: our categories, plus Metal's own total, which also covers
     * what the categories do not (placement heaps, libraries, driver objects). */
    {
        static LONG64 last_census; static LARGE_INTEGER qpf;
        LONG64 now = mad_qpc(), prev = last_census;
        if (!qpf.QuadPart) QueryPerformanceFrequency(&qpf);
        if (now - prev > 5 * qpf.QuadPart && InterlockedCompareExchange64(&last_census, now, prev) == prev) {
            mad_acct_report();
            if (e.q && e.q->device)
                d3d12_log("[madeira-d3d12] ml1150 Metal currentAllocatedSize %llu MB\n",
                          (unsigned long long)(MTLDevice_currentAllocatedSize(e.q->device->mtl_device) >> 20));
        }
    }
    {
        static unsigned said;
        if ((said < 12 || (g_list_seq >= 12000 && g_list_seq < 12400) || g_census_on) && (e.draws || e.skipped)) {
            said++;
            d3d12_log("[madeira-d3d12] list executed: %u commands, %u draws, %u skipped\n", l->ncmds, e.draws, e.skipped);
        }
    }
}

/* ml1120: the replay itself; runs on the caller (async-submit = 0) or on the
 * queue's submission worker. */
static void mad_ecl_run(ID3D12CommandQueue *This, UINT count, ID3D12CommandList *const *lists) {
    /* ml1021: hold the queue for the WHOLE replay. A concurrent Present ->
     * flush_all must not commit the buffer we are still encoding into. */
    struct mad_queue *ml1021_q = (struct mad_queue *)This;
    /* ml1049: a Wine thread has no autorelease pool, so every autoreleased
     * object Metal returned here -- the command buffer's +0 reference and EVERY
     * encoder -- lived until the thread exited, i.e. for the whole run. The
     * command buffer keeps the reference taken at open; encoders are all ended
     * by exec_end before a list returns, so nothing in the pool is still in use
     * when it drains. Same thread pushes and pops. */
    obj_handle_t ml1049_pool = NSAutoreleasePool_alloc_init();
    if (ml1021_q) EnterCriticalSection(&ml1021_q->submit_lock);

    struct mad_queue *q = (struct mad_queue *)This;
    for (UINT i = 0; i < count; i++) {
        struct mad_list *l = (struct mad_list *)lists[i];
        if (l && !l->closed) {
            d3d12_log("[madeira-d3d12] ExecuteCommandLists: list %u is still recording\n", i);
            q->rejected++;
            continue;
        }
        if (l && l->alloc && l->recorded_generation != l->alloc->generation) {
            d3d12_log("[madeira-d3d12] ExecuteCommandLists: list %u was recorded against "
                      "allocator generation %ld but the allocator is now at %ld\n",
                      i, (long)l->recorded_generation, (long)l->alloc->generation);
            q->rejected++;
            continue;
        }
        if (!q->open_cb) {
            if (q->device->resset && InterlockedExchange(&q->device->resset_dirty, 0))
                MTLResidencySet_commit(q->device->resset);
            mad_queue_revive(q->device);   /* ml1067 */
            q->open_cb = MTLCommandQueue_commandBuffer(q->device->mtl_queue);
            if (!q->open_cb) { d3d12_log("[madeira-d3d12] no command buffer\n"); q->rejected++; continue; }
            /* commandBuffer returns an AUTORELEASED object locally and an interned
             * one remotely; holding it across calls means taking our own reference. */
            NSObject_retain(q->open_cb);
        }
        if (l) mad_exec_list(q, l, q->open_cb);
        q->open_lists++;
        q->executed++;
        if (q->open_lists >= 48) mad_queue_flush(q);   /* bound the batch */
    }
    if (ml1021_q) LeaveCriticalSection(&ml1021_q->submit_lock);   /* ml1021 */
    if (ml1049_pool) NSObject_release(ml1049_pool);
}
enum { MAD_SUB_ECL = 1, MAD_SUB_SIGNAL, MAD_SUB_WAIT, MAD_SUB_PRESENT };
struct mad_swapchain;
static void mad_present_run(struct mad_swapchain *s, UINT idx);   /* ml1121 */
struct mad_subjob {
    struct mad_subjob *next;
    int kind;
    UINT count; struct mad_list **lists;   /* ECL: validated, AddRef'd, inflight counted */
    ID3D12Fence *fence; UINT64 value;      /* SIGNAL / WAIT: AddRef'd */
    struct mad_swapchain *swap; UINT index;   /* PRESENT (ml1121): no reference held -- swap_Release drains the queue first */
};
static void mad_sub_enqueue(struct mad_queue *q, struct mad_subjob *j) {
    j->next = NULL;
    EnterCriticalSection(&q->sub_lock);
    if (q->sub_tail) q->sub_tail->next = j; else q->sub_head = j;
    q->sub_tail = j;
    WakeConditionVariable(&q->sub_work);
    LeaveCriticalSection(&q->sub_lock);
}
static void STDMETHODCALLTYPE queue_ExecuteCommandLists(ID3D12CommandQueue *This, UINT count,
                                                        ID3D12CommandList *const *lists) {
    struct mad_queue *q = (struct mad_queue *)This;
    LARGE_INTEGER t0, t1;
    QueryPerformanceCounter(&t0);   /* ml1119: caller-thread time in here */
    InterlockedIncrement(&g_perf_ecl);   /* ml1109 */
    mad_xp_role('E'); InterlockedIncrement64(&g_xp.ecl_calls);   /* ml1128 */
    if (q && q->sub_thread) {   /* ml1120: validate here, replay on the worker */
        struct mad_subjob *j = calloc(1, sizeof *j + (count ? count : 1) * sizeof(struct mad_list *));
        if (j) {
            UINT i, n = 0;
            j->kind = MAD_SUB_ECL; j->lists = (struct mad_list **)(j + 1);
            for (i = 0; i < count; i++) {
                struct mad_list *l = (struct mad_list *)lists[i];
                if (!l) continue;
                if (!l->closed) {
                    d3d12_log("[madeira-d3d12] ExecuteCommandLists: list %u is still recording\n", i);
                    q->rejected++;
                    continue;
                }
                if (l->alloc && l->recorded_generation != l->alloc->generation) {
                    d3d12_log("[madeira-d3d12] ExecuteCommandLists: list %u was recorded against "
                              "allocator generation %ld but the allocator is now at %ld\n",
                              i, (long)l->recorded_generation, (long)l->alloc->generation);
                    q->rejected++;
                    continue;
                }
                list_AddRef((ID3D12GraphicsCommandList *)l);
                InterlockedIncrement(&l->inflight);
                j->lists[n++] = l;
            }
            j->count = n;
            mad_sub_enqueue(q, j);
            goto done;
        }
    }
    mad_ecl_run(This, count, lists);
done:
    QueryPerformanceCounter(&t1);
    InterlockedExchangeAdd64(&g_perf_ecl_ticks, t1.QuadPart - t0.QuadPart);
    InterlockedExchangeAdd64(&g_xp.t_ecl_caller, t1.QuadPart - t0.QuadPart);   /* ml1128 */
}
/* Cross-queue synchronisation. Every queue here submits to the one Metal
 * queue in CPU order, and Signal only advances a fence once the GPU has
 * finished the work before it, so "wait until the fence reaches v" is the
 * same as ordering this thread behind the signalling thread. The wait is
 * bounded: a signal that never comes is logged and released rather than
 * parking the render thread forever, because a hang here looks identical to
 * every other hang and says nothing. */
/* ml1049: waiting for a command buffer says nothing about whether the GPU ran
 * it. A buffer that ends in MTLCommandBufferStatusError discards ALL of its
 * work -- a whole batch of up to 48 lists renders nothing -- and nothing here
 * ever looked. Borrowed objects (error, description) are NOT released. */
static void mad_cb_log_error(struct mad_device *d, obj_handle_t cb) {
    static LONG said;
    char text[512] = "";
    obj_handle_t err, desc;
    LONG n = InterlockedIncrement(&said);
    err = MTLCommandBuffer_error(cb);
    desc = err ? NSObject_description(err) : 0;
    if (desc) NSString_getCString(desc, text, sizeof text, WMTUTF8StringEncoding);
    if (n <= 24)
        d3d12_log("[madeira-d3d12] ml1049 COMMAND BUFFER ENDED IN ERROR (#%ld of this run): %s\n",
                  g_cb_errors, text[0] ? text : "(no description)");
    /* ml1067: after a GPU fault the driver starts IGNORING every later submission
     * on the queue ("Ignored (for causing prior/excessive GPU errors)") -- from then
     * on nothing renders and the game looks frozen (ph-rdr34: page fault, hang,
     * then ignored, first story cutscene). The queue is dead; a fresh one is not. */
    if (d && strstr(text, "SubmissionsIgnored")) InterlockedExchange(&d->queue_poisoned, 1);
}
static void mad_vis_retire(struct mad_device *d, obj_handle_t cb);
/* ml1108: where does the frame go? GPU busy (union of command-buffer GPU
 * intervals), CPU time blocked in retire, presents -- logged every 5 s from
 * Present. Off with madeira.cfg perf-log = 0. */
static LONG g_perf_lock; static int g_perf_enabled = -1;
static double g_perf_gpu_sum, g_perf_gpu_union, g_perf_last_end, g_perf_first_start, g_perf_wait_s;
static LONG g_perf_cbs, g_perf_presents; static LONGLONG g_perf_t0;

static void mad_perf_lock(void) { while (InterlockedCompareExchange(&g_perf_lock, 1, 0)) YieldProcessor(); }
static void mad_perf_unlock(void) { InterlockedExchange(&g_perf_lock, 0); }
static void mad_perf_cb(obj_handle_t cb, double wait_s) {
    struct { UINT64 cb; double start, end; } t; struct madeira_ctl_args a;
    if (g_perf_enabled < 0) g_perf_enabled = (int)mad_cfg_int_pe("perf-log", 1);
    if (!g_perf_enabled) return;
    memset(&t, 0, sizeof t); t.cb = (UINT64)cb;
    memset(&a, 0, sizeof a); a.op = 3; a.ptr = (UINT64)(ULONG_PTR)&t; a.len = sizeof t;
    MadeiraCtl(&a);
    mad_perf_lock();
    g_perf_wait_s += wait_s; g_perf_cbs++;
    if (a.ret && t.end > t.start) {
        double s0 = t.start, e0 = t.end;
        g_perf_gpu_sum += e0 - s0;
        if (!g_perf_first_start) g_perf_first_start = s0;
        if (s0 < g_perf_last_end) s0 = g_perf_last_end;
        if (e0 > s0) g_perf_gpu_union += e0 - s0;
        if (t.end > g_perf_last_end) g_perf_last_end = t.end;
    }
    mad_perf_unlock();
}
static void mad_perf_present(void) {
    LARGE_INTEGER now, fq; double wall;
    if (g_perf_enabled <= 0) return;
    QueryPerformanceCounter(&now); QueryPerformanceFrequency(&fq);
    mad_perf_lock();
    g_perf_presents++;
    if (!g_perf_t0) { g_perf_t0 = now.QuadPart; mad_perf_unlock(); return; }
    wall = (double)(now.QuadPart - g_perf_t0) / (double)fq.QuadPart;
    if (wall >= 5.0) {
        d3d12_log("[perf] ml1108 %.1fs: presents=%ld (%.1f fps) cbs=%ld gpu_busy=%.0fms (%.0f%% of wall, sum %.0fms) cpu_blocked_in_retire=%.0fms (%.0f%%) per-frame: gpu %.1fms wait %.1fms\n",
                  wall, g_perf_presents, g_perf_presents / wall, g_perf_cbs, g_perf_gpu_union * 1000, 100.0 * g_perf_gpu_union / wall,
                  g_perf_gpu_sum * 1000, g_perf_wait_s * 1000, 100.0 * g_perf_wait_s / wall,
                  g_perf_presents ? g_perf_gpu_union * 1000 / g_perf_presents : 0.0, g_perf_presents ? g_perf_wait_s * 1000 / g_perf_presents : 0.0);
        {   /* ml1116: encoder fence traffic per frame (mode 2 should cut waits well below updates) */
            static LONG lw, lu, lb; LONG cw = g_fence_waits, cu = g_fence_updates, cb = g_barrier_seen;
            d3d12_log("[perf] ml1119 caller thread per frame: ExecuteCommandLists %.2f ms, Present %.2f ms (frame %.1f ms)\n",
                      g_perf_presents ? 1000.0 * g_perf_ecl_ticks / (double)fq.QuadPart / g_perf_presents : 0.0,
                      g_perf_presents ? 1000.0 * g_perf_present_ticks / (double)fq.QuadPart / g_perf_presents : 0.0,
                      g_perf_presents ? 1000.0 * wall / g_perf_presents : 0.0);
            g_perf_ecl_ticks = 0; g_perf_present_ticks = 0;
            if (g_async_submit > 0)
                d3d12_log("[perf] ml1120 async per frame: worker busy %.2f ms (%.1f jobs), Present drain %.2f ms, list Reset waits %.2f ms (%.1f), queue-Wait jobs blocked %.2f ms\n",
                          g_perf_presents ? 1000.0 * g_perf_worker_ticks / (double)fq.QuadPart / g_perf_presents : 0.0,
                          g_perf_presents ? (double)g_perf_jobs / g_perf_presents : 0.0,
                          g_perf_presents ? 1000.0 * g_perf_drain_ticks / (double)fq.QuadPart / g_perf_presents : 0.0,
                          g_perf_presents ? 1000.0 * g_perf_resetwait_ticks / (double)fq.QuadPart / g_perf_presents : 0.0,
                          g_perf_presents ? (double)g_perf_resetwaits / g_perf_presents : 0.0,
                          g_perf_presents ? 1000.0 * g_perf_waitjob_ticks / (double)fq.QuadPart / g_perf_presents : 0.0);
            g_perf_worker_ticks = g_perf_drain_ticks = g_perf_resetwait_ticks = g_perf_waitjob_ticks = 0; g_perf_jobs = g_perf_resetwaits = 0;
            d3d12_log("[perf] ml1116 encoders per frame: fence waits %.1f, fence updates %.1f, barriers %.1f (fence-chain %d)\n",
                      g_perf_presents ? (double)(cw - lw) / g_perf_presents : 0.0, g_perf_presents ? (double)(cu - lu) / g_perf_presents : 0.0,
                      g_perf_presents ? (double)(cb - lb) / g_perf_presents : 0.0, g_fence_chain);
            lw = cw; lu = cu; lb = cb;
            if (g_f6_used && g_perf_presents) {   /* ml1134 */
                double np = (double)g_perf_presents;
                LONG b = InterlockedExchange(&g_f6_begins, 0), sy = InterlockedExchange(&g_f6_synced, 0), at = InterlockedExchange(&g_f6_att_sync, 0);
                LONG ko = InterlockedExchange(&g_f6_kept_open, 0), jn = InterlockedExchange(&g_f6_joins, 0), rc = InterlockedExchange(&g_f6_rclose, 0);
                d3d12_log("[perf] ml1134 fence-chain 6 per frame: %.1f encoders, %.1f synced (%.1f for a shared attachment), %.1f overlapped; "
                          "%.1f compute encoders kept open at a barrier; %.1f overlapped render passes closed at a barrier; %.1f joins\n",
                          b / np, sy / np, at / np, (b - sy) / np, ko / np, rc / np, jn / np);
            }
            if (g_f6_used && g_perf_presents) {   /* ml1137 */
                double np = (double)g_perf_presents;
                LONG e0 = InterlockedExchange(&g_bc_ent[0], 0), e1 = InterlockedExchange(&g_bc_ent[1], 0), e2 = InterlockedExchange(&g_bc_ent[2], 0);
                LONG e3 = InterlockedExchange(&g_bc_ent[3], 0), e4 = InterlockedExchange(&g_bc_ent[4], 0);
                LONG bs = InterlockedExchange(&g_f7_bsync, 0), bn = InterlockedExchange(&g_f7_none, 0), bu = InterlockedExchange(&g_f7_subset, 0), ba = InterlockedExchange(&g_f7_all, 0);
                LONG64 f6 = InterlockedExchange64(&g_f7_fw6, 0), fr = InterlockedExchange64(&g_f7_fwr, 0);
                d3d12_log("[perf] ml1137 barrier census per frame: entries read->read %.1f, rt/depth->read %.1f, copy->read %.1f, uav %.1f, ->write/common/alias %.1f; "
                          "barrier-caused syncs %.1f, of which a state-aware rule needs none %.1f, a subset %.1f, all %.1f; fences waited at them %.1f -> %.1f\n",
                          e0 / np, e1 / np, e2 / np, e3 / np, e4 / np, bs / np, bn / np, bu / np, ba / np, f6 / np, fr / np);
            }
            if (g_ac_frames) {   /* ml1137 */
                double nf = (double)InterlockedExchange(&g_ac_frames, 0), mb = 1048576.0;
                d3d12_log("[perf] ml1137 attachments per census frame: load %.1f MB, clear %.1f MB, store %.1f MB, of which next in the list: cleared %.1f, read %.1f, "
                          "rebound %.1f, written %.1f, no use %.1f MB; DiscardResource calls %ld (5 s)\n",
                          InterlockedExchange64(&g_ac_load, 0) / mb / nf, InterlockedExchange64(&g_ac_clear, 0) / mb / nf, InterlockedExchange64(&g_ac_store, 0) / mb / nf,
                          InterlockedExchange64(&g_ac_st_cleared, 0) / mb / nf, InterlockedExchange64(&g_ac_st_read, 0) / mb / nf, InterlockedExchange64(&g_ac_st_rebound, 0) / mb / nf,
                          InterlockedExchange64(&g_ac_st_write, 0) / mb / nf, InterlockedExchange64(&g_ac_st_none, 0) / mb / nf, InterlockedExchange(&g_discards, 0));
            }
        }
        d3d12_log("[perf] ml1109 sync per frame: ExecuteCommandLists %.1f, Signal %.1f, fence waits %.1f (game blocked %.1f ms/frame = %.0f%% of wall), "
                  "GetCompletedValue polls %.1f, Queue::Wait sleeps %.1f; GPU-done -> fence advanced %.2f ms avg over %ld\n",
                  g_perf_presents ? (double)g_perf_ecl / g_perf_presents : 0.0, g_perf_presents ? (double)g_perf_signals / g_perf_presents : 0.0,
                  g_perf_presents ? (double)g_perf_waits / g_perf_presents : 0.0,
                  g_perf_presents ? 1000.0 * g_perf_wait_ticks / (double)fq.QuadPart / g_perf_presents : 0.0, 100.0 * g_perf_wait_ticks / (double)fq.QuadPart / wall,
                  g_perf_presents ? (double)g_perf_polls / g_perf_presents : 0.0, g_perf_presents ? (double)g_perf_qwait_sleeps / g_perf_presents : 0.0,
                  g_perf_sig_lat_n ? 1000.0 * g_perf_sig_lat_ticks / (double)fq.QuadPart / g_perf_sig_lat_n : 0.0, g_perf_sig_lat_n);
        g_perf_t0 = now.QuadPart; g_perf_presents = 0; g_perf_cbs = 0; g_perf_gpu_sum = g_perf_gpu_union = g_perf_wait_s = 0; g_perf_first_start = 0;
        g_perf_ecl = g_perf_signals = g_perf_waits = g_perf_polls = g_perf_qwait_sleeps = 0; g_perf_wait_ticks = g_perf_sig_lat_ticks = 0; g_perf_sig_lat_n = 0;
    }
    mad_perf_unlock();
}
static void mad_cb_retire(struct mad_device *d, obj_handle_t cb) {
    LARGE_INTEGER t0, t1, fq;
    QueryPerformanceCounter(&t0);
    MTLCommandBuffer_waitUntilCompleted(cb);
    QueryPerformanceCounter(&t1); QueryPerformanceFrequency(&fq);
    mad_perf_cb(cb, (double)(t1.QuadPart - t0.QuadPart) / (double)fq.QuadPart);
    InterlockedIncrement(&g_cb_retired);
    mad_vis_retire(d, cb);   /* ml1088: query results reach the readback buffers before any fence advances */
    if (MTLCommandBuffer_status(cb) == WMTCommandBufferStatusError) {
        InterlockedIncrement(&g_cb_errors);
        mad_cb_log_error(d, cb);
    }
    NSObject_release(cb);
}
/* ml1067: replace a queue the driver has given up on. Called with submit_lock
 * held, before a new command buffer is opened. The old queue object is leaked on
 * purpose: buffers of the old generation may still be retiring. */
static void mad_queue_revive(struct mad_device *d) {
    obj_handle_t nq;
    if (!InterlockedExchange(&d->queue_poisoned, 0)) return;
    nq = MTLDevice_newCommandQueue(d->mtl_device, 64);
    if (!nq) { d3d12_log("[madeira-d3d12] ml1067 could not create a replacement command queue\n"); return; }
    if (d->resset) { MTLCommandQueue_addResidencySet(nq, d->resset); InterlockedExchange(&d->resset_dirty, 1); }
    d->mtl_queue = nq;
    d3d12_log("[madeira-d3d12] ml1067 driver ignored our submissions after a GPU fault; command queue REPLACED (#%ld)\n",
              InterlockedIncrement(&d->queues_recreated));
}
static void mad_log_nserror(const char *what, obj_handle_t err) {
    /* ml1049: the bridge hands back Metal's AUTORELEASED NSError. Releasing it
     * here was an over-release that only an undrained pool was hiding; and the
     * text, which names the actual defect, was thrown away unread. */
    static LONG said;
    char text[600] = "";
    obj_handle_t desc;
    if (!err || InterlockedIncrement(&said) > 40) return;
    desc = NSObject_description(err);
    if (desc) NSString_getCString(desc, text, sizeof text, WMTUTF8StringEncoding);
    d3d12_log("[madeira-d3d12] ml1049 %s: %s\n", what, text[0] ? text : "(no description)");
}
/* ml884: commit the queue's open command buffer and track it for fencing. */
static void mad_queue_flush(struct mad_queue *q) {
    if (!q) return;
    EnterCriticalSection(&q->submit_lock);   /* ml1021 */
    if (!q->open_cb) { LeaveCriticalSection(&q->submit_lock); return; }
    if (q->npending == 16) {
        for (unsigned k = 0; k < q->npending; k++) mad_cb_retire(q->device, q->pending[k]);
        q->npending = 0;
    }
    f6_join(q);   /* ml1134: mode 6 only; the batch's last encoder waits for all of it and moves the device fence */
    {   /* ml1061: serial assignment, the signal and the commit are ONE step under a
         * device lock, so serials reach the GPU in strictly increasing order no
         * matter which queue or thread commits (a shared event's value is just
         * "last written"; out-of-order commits would make it run backwards). */
        struct mad_device *sd = q->device;
        UINT64 serial = 0;
        /* ml1067: a resource created (or a view made) while this batch was OPEN was
         * added to the residency set but the set was only committed when the NEXT
         * buffer opened -- so this batch ran with it non-resident. With the per-draw
         * useResource lists gone (ml1060) nothing else covered that window. Commit
         * whatever is staged right before the buffer that will use it. */
        if (sd->resset && InterlockedExchange(&sd->resset_dirty, 0)) MTLResidencySet_commit(sd->resset);
        EnterCriticalSection(&sd->fence_lock);
        if (sd->gpu_event) {
            serial = (UINT64)InterlockedIncrement64(&sd->gpu_serial);
            MTLCommandBuffer_encodeSignalEvent(q->open_cb, sd->gpu_event, serial);
        }
        mad_vis_flush(q, q->open_cb);            /* ml1099: under fence_lock, so the pending list is in SERIAL order (Astra) */
        MTLCommandBuffer_commit(q->open_cb);
        if (serial) { q->last_serial = serial; InterlockedExchange64(&sd->gpu_serial_committed, (LONG64)serial); }
        LeaveCriticalSection(&sd->fence_lock);
        q->batch_serial[(q->batches + 1) & 63] = serial;
    }
    q->pending[q->npending++] = q->open_cb;      /* the reference taken at open moves here */
    q->open_cb = 0; q->open_lists = 0; q->batches++;
    if (q->batches <= 3 || (q->batches % 500) == 0)
        d3d12_log("[madeira-d3d12] batch #%llu committed (%llu lists so far)\n",
                  (unsigned long long)q->batches, (unsigned long long)q->executed);
    LeaveCriticalSection(&q->submit_lock);   /* ml1021 */
}
static void mad_device_flush_all(struct mad_device *d) {
    /* ml1021: the queue registry was read with no lock while creation and
     * destruction mutate it under live_lock, so this could flush a queue that
     * was being freed. Snapshot under the lock and hold a reference across the
     * flush, then release -- flushing while holding live_lock would invert the
     * lock order against the creation path. */
    struct mad_queue *snap[16];
    unsigned n = 0, i;
    if (!d) return;
    EnterCriticalSection(&d->live_lock);
    for (i = 0; i < d->nqueues && n < 16; i++)
        if (d->queues[i]) { snap[n] = d->queues[i]; InterlockedIncrement(&snap[n]->refs); n++; }
    LeaveCriticalSection(&d->live_lock);
    for (i = 0; i < n; i++) mad_queue_flush(snap[i]);
    for (i = 0; i < n; i++) queue_Release((ID3D12CommandQueue *)snap[i]);
}

static void mad_list_rings_rewind(struct mad_list *l) {
    struct mad_queue *q = l->ring_q;
    l->ring_used = 0;
    if (!q || !l->nrings || !q->device || !q->device->gpu_event) return;   /* never replayed, or no GPU timeline */
    if (l->ring_batch > q->batches) mad_queue_flush(q);                     /* its batch is still open: commit it so it HAS a serial */
    {
        UINT64 serial = (q->batches - l->ring_batch < 64) ? q->batch_serial[l->ring_batch & 63] : q->last_serial;
        if (!serial) serial = q->last_serial;
        if (serial && mad_gpu_completed(q->device) < serial) mad_ring_retire(q->device, l, serial);
    }
}

/* ml1061: ASYNCHRONOUS FENCES.
 * Signal() used to commit and then BLOCK in waitUntilCompleted on every pending
 * command buffer while holding the queue's submission lock -- i.e. the render
 * thread stood still for the whole GPU frame at every fence, CPU and GPU never
 * overlapped, and in ph-rdr28 one such wait never returned and froze the game
 * with two more threads queued behind that lock. D3D12's Signal is a GPU-timeline
 * operation: it returns at once and the fence advances when the GPU gets there.
 * A worker thread owns that: it waits on the device's shared event for the
 * batch's serial, retires the batch's command buffers (status checked), then
 * advances the fence. Jobs are FIFO, so fence values stay ordered. */
static DWORD WINAPI mad_fence_worker(void *arg) {
    struct mad_device *d = arg;
    for (;;) {
        struct mad_fence_job job; int have = 0; unsigned k, stalled_ms = 0;
        EnterCriticalSection(&d->fence_lock);
        if (d->nfence_jobs) {
            job = d->fence_jobs[0];
            memmove(&d->fence_jobs[0], &d->fence_jobs[1], (d->nfence_jobs - 1) * sizeof job);
            d->nfence_jobs--; have = 1;
        }
        LeaveCriticalSection(&d->fence_lock);
        if (!have) {
            if (d->fence_quit) return 0;   /* ml1064 */
            WaitForSingleObject(d->fence_wake, INFINITE);
            continue;
        }
        while (job.serial && !MTLSharedEvent_waitUntilSignaledValue(d->gpu_event, job.serial, 50)) {
            /* ml1062: a command buffer that ends in ERROR never runs its
             * encodeSignalEvent, so its serial is NEVER reached -- ph-rdr29 froze
             * exactly here with "status of this batch: 5 5". The work is lost
             * either way; what must not happen is the fence waiting for it forever.
             * mad_cb_retire below logs the Metal error text. */
            {
                int failed = (LONG64)job.serial <= d->gpu_serial_failed;   /* a fence with no buffers of its own, behind a dead batch */
                for (k = 0; k < job.ncbs; k++)
                    if (MTLCommandBuffer_status(job.cbs[k]) == WMTCommandBufferStatusError) failed = 1;
                if (failed) {
                    static LONG said;
                    if ((LONG64)job.serial > d->gpu_serial_failed) InterlockedExchange64(&d->gpu_serial_failed, (LONG64)job.serial);
                    if (InterlockedIncrement(&said) <= 12)
                        d3d12_log("[madeira-d3d12] ml1062 batch serial %llu FAILED on the GPU; advancing its fence anyway "
                                  "(the frame's work is lost, the game keeps running)\n", (unsigned long long)job.serial);
                    break;
                }
            }
            stalled_ms += 50;
            if (stalled_ms == 5000 || (stalled_ms % 60000) == 0) {
                char line[300]; int n = 0;
                for (k = 0; k < job.ncbs; k++) n += snprintf(line + n, sizeof line - n, " %u", (unsigned)MTLCommandBuffer_status(job.cbs[k]));
                d3d12_log("[madeira-d3d12] ml1061 GPU STALL: serial %llu not reached after %u ms (event at %llu, committed %lld); "
                          "command-buffer status of this batch:%s (2=committed 3=scheduled 4=completed 5=error)\n",
                          (unsigned long long)job.serial, stalled_ms, (unsigned long long)mad_gpu_completed(d),
                          (long long)d->gpu_serial_committed, n ? line : " (none)");
            }
        }
        {   /* ml1109: from "GPU reached the serial" to "fence advanced" = our retire overhead */
            LARGE_INTEGER t0, t1; QueryPerformanceCounter(&t0);
            for (k = 0; k < job.ncbs; k++) mad_cb_retire(d, job.cbs[k]);
            ID3D12Fence_Signal(job.fence, job.value);
            QueryPerformanceCounter(&t1);
            InterlockedExchangeAdd64(&g_perf_sig_lat_ticks, t1.QuadPart - t0.QuadPart); InterlockedIncrement(&g_perf_sig_lat_n);
        }
        ID3D12Fence_Release(job.fence);
    }
    return 0;
}

static int mad_signal_async(struct mad_queue *q, ID3D12Fence *fence, UINT64 value) {
    struct mad_device *d = q->device;
    struct mad_fence_job *job;
    int ok = 0;
    if (!d->gpu_event || d->ncap) return 0;   /* no timeline, or a capture wants its readback synchronously */
    EnterCriticalSection(&q->submit_lock);   /* lock order everywhere: submit_lock, THEN fence_lock (as in flush) */
    EnterCriticalSection(&d->fence_lock);
    if (!d->fence_thread) {
        d->fence_wake = CreateEventW(NULL, FALSE, FALSE, NULL);
        d->fence_thread = d->fence_wake ? CreateThread(NULL, 0, mad_fence_worker, d, 0, NULL) : NULL;
    }
    if (d->fence_thread && mad_grow((void **)&d->fence_jobs, &d->fence_jobs_cap, d->nfence_jobs + 1, sizeof *d->fence_jobs)) {
        job = &d->fence_jobs[d->nfence_jobs++];
        memset(job, 0, sizeof *job);
        job->serial = q->last_serial; job->fence = fence; job->value = value;
        ID3D12Fence_AddRef(fence);
        job->ncbs = q->npending;
        memcpy(job->cbs, q->pending, q->npending * sizeof q->pending[0]);
        q->npending = 0;
        ok = 1;
    }
    LeaveCriticalSection(&d->fence_lock);
    LeaveCriticalSection(&q->submit_lock);
    if (ok) SetEvent(d->fence_wake);
    return ok;
}

static HRESULT STDMETHODCALLTYPE queue_Wait(ID3D12CommandQueue *This, ID3D12Fence *fence, UINT64 value) {
    struct mad_fence *f = (struct mad_fence *)fence;
    unsigned waited = 0;
    static unsigned said;
    if (!f) return E_INVALIDARG;
    if (((struct mad_queue *)This)->sub_thread) {   /* ml1120: the worker waits for the signal's COMMIT, in FIFO order */
        struct mad_subjob *j = calloc(1, sizeof *j);
        if (j) {
            j->kind = MAD_SUB_WAIT; j->fence = fence; j->value = value;
            ID3D12Fence_AddRef(fence);
            mad_sub_enqueue((struct mad_queue *)This, j);
            return S_OK;
        }
    }
    mad_device_flush_all(((struct mad_queue *)This)->device);   /* ml884: the signal may sit in an open buffer */
    /* ml1061: Wait() is a GPU-timeline dependency, not a CPU wait. Every D3D queue
     * here feeds ONE Metal queue in commit order, so once the signalling batch has
     * been COMMITTED anything submitted afterwards already runs behind it. Only a
     * signal that has not been submitted yet still needs the CPU-side wait. */
    if ((UINT64)f->submitted >= value) return S_OK;
    while (waited < 5000) {
        UINT64 v;
        EnterCriticalSection(&f->lock);
        v = f->value;
        LeaveCriticalSection(&f->lock);
        if (v >= value) return S_OK;
        InterlockedIncrement(&g_perf_qwait_sleeps);   /* ml1109 */
        Sleep(1);
        waited++;
    }
    if (said++ < 4)
        d3d12_log("[madeira-d3d12] Queue::Wait: fence %p never reached %llu in 5 s (at %llu); continuing\n",
                  (void *)f, (unsigned long long)value, (unsigned long long)f->value);
    return S_OK;
}

static HRESULT mad_signal_run(struct mad_queue *q, ID3D12Fence *fence, UINT64 value);
static HRESULT STDMETHODCALLTYPE queue_Signal(ID3D12CommandQueue *This, ID3D12Fence *fence, UINT64 value) {
    struct mad_queue *q = (struct mad_queue *)This;
    if (!fence) return E_INVALIDARG;
    {   /* ml1061 */
        struct mad_fence *sf = (struct mad_fence *)fence; LONG64 cur;
        do { cur = sf->submitted; } while ((UINT64)cur < value && InterlockedCompareExchange64(&sf->submitted, (LONG64)value, cur) != cur);
    }
    if (q->sub_thread) {   /* ml1120 */
        struct mad_subjob *j = calloc(1, sizeof *j);
        if (j) {
            j->kind = MAD_SUB_SIGNAL; j->fence = fence; j->value = value;
            ID3D12Fence_AddRef(fence);
            mad_sub_enqueue(q, j);
            return S_OK;
        }
    }
    return mad_signal_run(q, fence, value);
}
static HRESULT mad_signal_run(struct mad_queue *q, ID3D12Fence *fence, UINT64 value) {
    mad_queue_flush(q);                              /* ml884: commit the batch this signal covers */
    InterlockedIncrement(&g_perf_signals);           /* ml1109 */
    if (mad_signal_async(q, fence, value)) { mad_fence_committed((struct mad_fence *)fence, value); return S_OK; }
    /* The fence must not advance until the work submitted before it has
     * actually finished on the GPU. Signalling at submission time would make
     * the fence a counter, and a readback taken after the waiter woke could
     * legitimately contain nothing.
     *
     * This is the conservative form the design permits: block here rather than
     * completing asynchronously. It costs a stall the real renderer will not
     * want, but it makes the ordering guarantee true, which is the part the
     * readback test is actually checking. */
    /* ml1021: pending[] is queue state; draining it unsynchronised raced a
     * concurrent flush that appends to the same array. */
    EnterCriticalSection(&q->submit_lock);
    for (unsigned i = 0; i < q->npending; i++) mad_cb_retire(q->device, q->pending[i]);   /* ml1049: checks status */
    q->npending = 0;
    LeaveCriticalSection(&q->submit_lock);
    mad_capture_flush(q->device);   /* ml910 */
    return ID3D12Fence_Signal(fence, value);
}

/* ---- ml1120: asynchronous submission ------------------------------------- */
static int g_async_submit = -1;
static CRITICAL_SECTION g_commit_lock; static CONDITION_VARIABLE g_commit_cv; static volatile LONG g_commit_ready;
static int mad_async_on(void) {
    if (g_async_submit < 0) {
        g_async_submit = mad_cfg_int_pe("async-submit", 0) ? 1 : 0;
        if (g_async_submit && !InterlockedExchange(&g_commit_ready, 2)) {
            InitializeCriticalSection(&g_commit_lock); InitializeConditionVariable(&g_commit_cv);
            InterlockedExchange(&g_commit_ready, 1);
        }
        d3d12_log("[madeira-d3d12] ml1120 async-submit = %d (%s)\n", g_async_submit,
                  g_async_submit ? "ExecuteCommandLists/Signal/Wait are replayed by a per-queue worker, in order" : "replay on the calling thread");
    }
    return g_async_submit;
}
/* Signal has reached Metal (its batch is committed): release queue Waits. */
static void mad_fence_committed(struct mad_fence *f, UINT64 value) {
    LONG64 cur;
    do { cur = f->committed; } while ((UINT64)cur < value && InterlockedCompareExchange64(&f->committed, (LONG64)value, cur) != cur);
    if (g_commit_ready == 1) {
        EnterCriticalSection(&g_commit_lock);
        WakeAllConditionVariable(&g_commit_cv);
        LeaveCriticalSection(&g_commit_lock);
    }
}
/* A queue Wait on the worker: every D3D queue feeds one Metal queue in commit
 * order, so once the signalling batch is COMMITTED, anything this queue commits
 * afterwards runs behind it (the ml1061 argument, now per worker). Waiting for
 * the commit -- not for the whole other queue to drain -- is what keeps the
 * common direct<->compute ping-pong from deadlocking two workers. */
static void mad_wait_committed(struct mad_fence *f, UINT64 value) {
    LARGE_INTEGER t0, t1; DWORD waited = 0; static LONG said;
    if ((UINT64)f->committed >= value || f->value >= value) return;
    QueryPerformanceCounter(&t0);
    EnterCriticalSection(&g_commit_lock);
    while ((UINT64)f->committed < value && f->value < value && waited < 5000) {
        SleepConditionVariableCS(&g_commit_cv, &g_commit_lock, 10);
        waited += 10;
    }
    LeaveCriticalSection(&g_commit_lock);
    QueryPerformanceCounter(&t1);
    InterlockedExchangeAdd64(&g_perf_waitjob_ticks, t1.QuadPart - t0.QuadPart);
    if (waited >= 5000 && InterlockedIncrement(&said) <= 4)
        d3d12_log("[madeira-d3d12] ml1120 queue Wait: fence %p value %llu not committed within 5 s (committed %lld, value %llu); continuing\n",
                  (void *)f, (unsigned long long)value, (long long)f->committed, (unsigned long long)f->value);
}
static DWORD WINAPI mad_sub_worker(void *arg) {
    struct mad_queue *q = arg;
    mad_xp_role('W');   /* ml1128 */
    for (;;) {
        struct mad_subjob *j;
        LARGE_INTEGER t0, t1;
        obj_handle_t pool;
        EnterCriticalSection(&q->sub_lock);
        while (!q->sub_head && !q->sub_quit) SleepConditionVariableCS(&q->sub_work, &q->sub_lock, INFINITE);
        if (!q->sub_head) { LeaveCriticalSection(&q->sub_lock); return 0; }
        j = q->sub_head; q->sub_head = j->next; if (!q->sub_head) q->sub_tail = NULL;
        q->sub_busy = 1;
        LeaveCriticalSection(&q->sub_lock);

        QueryPerformanceCounter(&t0);
        pool = NSAutoreleasePool_alloc_init();
        switch (j->kind) {
        case MAD_SUB_ECL: {
            UINT i;
            mad_ecl_run((ID3D12CommandQueue *)q, j->count, (ID3D12CommandList *const *)j->lists);
            for (i = 0; i < j->count; i++) {
                InterlockedDecrement(&j->lists[i]->inflight);
                list_Release((ID3D12GraphicsCommandList *)j->lists[i]);
            }
            break;
        }
        case MAD_SUB_SIGNAL:
            mad_signal_run(q, j->fence, j->value);
            ID3D12Fence_Release(j->fence);
            break;
        case MAD_SUB_WAIT:
            mad_device_flush_all(q->device);   /* as queue_Wait did: a CPU-side or other-path signal may sit in an open buffer */
            mad_wait_committed((struct mad_fence *)j->fence, j->value);
            ID3D12Fence_Release(j->fence);
            break;
        case MAD_SUB_PRESENT:   /* ml1121 */
            mad_present_run(j->swap, j->index);
            EnterCriticalSection(&q->sub_lock);
            q->sub_presents--;
            WakeAllConditionVariable(&q->sub_presented);
            LeaveCriticalSection(&q->sub_lock);
            break;
        }
        {   /* ml1128: per-kind elapsed, and the pool drain on its own */
            LONG64 tk = mad_qpc(), d = tk - t0.QuadPart;
            switch (j->kind) {
            case MAD_SUB_ECL: InterlockedIncrement64(&g_xp.n_ecl); InterlockedExchangeAdd64(&g_xp.t_ecl, d); break;
            case MAD_SUB_SIGNAL: InterlockedIncrement64(&g_xp.n_sig); InterlockedExchangeAdd64(&g_xp.t_sig, d); break;
            case MAD_SUB_WAIT: InterlockedIncrement64(&g_xp.n_wait); InterlockedExchangeAdd64(&g_xp.t_wait, d); break;
            case MAD_SUB_PRESENT: InterlockedIncrement64(&g_xp.pres_done); InterlockedExchangeAdd64(&g_xp.t_prs, d); break;
            }
            if (pool) NSObject_release(pool);
            InterlockedExchangeAdd64(&g_xp.t_pool, mad_qpc() - tk);
        }
        QueryPerformanceCounter(&t1);
        InterlockedExchangeAdd64(&g_perf_worker_ticks, t1.QuadPart - t0.QuadPart);
        InterlockedIncrement(&g_perf_jobs);
        free(j);

        EnterCriticalSection(&q->sub_lock);
        q->sub_busy = 0;
        if (!q->sub_head) WakeAllConditionVariable(&q->sub_idle);
        LeaveCriticalSection(&q->sub_lock);
    }
}
/* Everything enqueued on q so far has been replayed. Called only from API
 * entry points on application threads, never from a worker. */
static void mad_queue_drain(struct mad_queue *q) {
    LARGE_INTEGER t0, t1;
    if (!q || !q->sub_thread) return;
    QueryPerformanceCounter(&t0);
    EnterCriticalSection(&q->sub_lock);
    while (q->sub_head || q->sub_busy) SleepConditionVariableCS(&q->sub_idle, &q->sub_lock, INFINITE);
    LeaveCriticalSection(&q->sub_lock);
    QueryPerformanceCounter(&t1);
    InterlockedExchangeAdd64(&g_perf_drain_ticks, t1.QuadPart - t0.QuadPart);
}
/* ml1121: bounded run-ahead. Present enqueues and returns; the application may
 * start the next frame while the worker encodes this one, but no more than
 * async-present-ahead presents (default 1) may be queued behind it. */
static int g_present_ahead = -1;
static void mad_present_throttle(struct mad_queue *q) {
    LARGE_INTEGER t0, t1;
    if (g_present_ahead < 0) {
        g_present_ahead = (int)mad_cfg_int_pe("async-present-ahead", 1);
        if (g_present_ahead < 0) g_present_ahead = 0; if (g_present_ahead > 3) g_present_ahead = 3;
        d3d12_log("[madeira-d3d12] ml1121 asynchronous Present, run-ahead %d frame(s)\n", g_present_ahead);
    }
    QueryPerformanceCounter(&t0);
    EnterCriticalSection(&q->sub_lock);
    while (q->sub_presents > g_present_ahead) SleepConditionVariableCS(&q->sub_presented, &q->sub_lock, INFINITE);
    LeaveCriticalSection(&q->sub_lock);
    QueryPerformanceCounter(&t1);
    InterlockedExchangeAdd64(&g_xp.t_thr, t1.QuadPart - t0.QuadPart);   /* ml1128 */
    InterlockedExchangeAdd64(&g_perf_drain_ticks, t1.QuadPart - t0.QuadPart);
}
static void mad_list_wait_idle(struct mad_list *l) {
    LARGE_INTEGER t0, t1; unsigned spins = 0;
    QueryPerformanceCounter(&t0);
    while (l->inflight) {
        if (++spins < 256) YieldProcessor();
        else if (spins < 4096) Sleep(0);
        else Sleep(1);
    }
    QueryPerformanceCounter(&t1);
    InterlockedExchangeAdd64(&g_perf_resetwait_ticks, t1.QuadPart - t0.QuadPart);
    InterlockedIncrement(&g_perf_resetwaits);
}

/* ---- device -------------------------------------------------------------- */





static ID3D12Device10Vtbl g_device_vtbl;
static ID3D12CommandQueueVtbl g_queue_vtbl;
static ID3D12CommandAllocatorVtbl g_alloc_vtbl;
static ID3D12GraphicsCommandList7Vtbl g_list_vtbl;
static ID3D12FenceVtbl g_fence_vtbl;

static HRESULT STDMETHODCALLTYPE device_QI(ID3D12Device *This, REFIID riid, void **out) {
    HRESULT hr;
    /* ml877: ID3D12Device1..8 are the same object with a longer vtable. UE 5.4
     * refuses to run without Device1 AND Device2 ("Missing full support for
     * Direct3D 12", D3D12Adapter.cpp:946) and uses Device2::CreatePipelineState,
     * Device4::CreateCommandList1/CreateCommittedResource1 when present.
     * Device9/10 (shader cache sessions, enhanced barriers) stay refused so the
     * log names them if a title asks. */
    if (out && riid && (IsEqualGUID(riid, &IID_ID3D12Device1) || IsEqualGUID(riid, &IID_ID3D12Device2) ||
                        IsEqualGUID(riid, &IID_ID3D12Device3) || IsEqualGUID(riid, &IID_ID3D12Device4) ||
                        IsEqualGUID(riid, &IID_ID3D12Device5) || IsEqualGUID(riid, &IID_ID3D12Device6) ||
                        IsEqualGUID(riid, &IID_ID3D12Device7) || IsEqualGUID(riid, &IID_ID3D12Device8))) {
        InterlockedIncrement(&((struct mad_obj *)This)->refs);
        *out = This;
        return S_OK;
    }
    hr = mad_qi((struct mad_obj *)This, riid, out, 0);
    if (hr == E_NOINTERFACE && riid) {
        /* Name the interface the engine wanted, once each: ID3D12Device1..N,
         * ID3D12InfoQueue and friends are how a title discovers optional
         * capabilities, and a silent E_NOINTERFACE hides which one it was. */
        static GUID seen[16]; static unsigned nseen;
        unsigned i;
        for (i = 0; i < nseen; i++) if (IsEqualGUID(&seen[i], riid)) return hr;
        if (nseen < 16) seen[nseen++] = *riid;
        d3d12_log("[madeira-d3d12] device QueryInterface refused: {%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}\n",
                  (unsigned long)riid->Data1, riid->Data2, riid->Data3, riid->Data4[0], riid->Data4[1],
                  riid->Data4[2], riid->Data4[3], riid->Data4[4], riid->Data4[5], riid->Data4[6], riid->Data4[7]);
    }
    return hr;
}

/* Truthful capability answers. Only what this runtime can actually do is
 * claimed: feature level 11_0, shader model 6.6 (the converter's DXIL ceiling),
 * root signature 1.1, a unified-memory architecture. Every other feature id
 * is refused by name so the engine's next requirement appears in the log
 * instead of being satisfied with a guess. */
/* ml1030: the sample counts this device can actually rasterise.
 *
 * We reported NumQualityLevels=0 for 8x (honestly -- Apple GPUs top out at 4)
 * and then passed the application's SampleDesc.Count straight through to
 * MTLRenderPipelineDescriptor.rasterSampleCount anyway. The host answered:
 *
 *   [rmetald] newRenderPipelineState: rasterSampleCount (8) is not supported
 *
 * 28 times in one run. A rejected pipeline is a NULL pipeline, and every draw
 * that would have used it silently disappears -- which is a large part of why
 * the first-boot screens were black with a single icon visible.
 *
 * D3D12 lets a runtime fail pipeline creation, but a translation layer that
 * cannot do 8x should DEGRADE the anti-aliasing, not drop the geometry. So
 * clamp to the nearest supported count at or below the request, and use this
 * one predicate for both the capability report and the pipeline/texture
 * descriptors so they can never disagree again.
 *
 * Render targets must be clamped identically: a 4x pipeline against an 8x
 * render target is a validation failure of its own. */
static UINT mad_clamp_sample_count(UINT requested)
{
    if (requested <= 1) return 1;
    if (requested >= 4) return 4;
    return 2;                       /* 3 -> 2 */
}

static HRESULT STDMETHODCALLTYPE device_CheckFeatureSupport(ID3D12Device *This,
        D3D12_FEATURE feature, void *data, UINT size) {
    (void)This;
    if (!data) return E_INVALIDARG;
    switch (feature) {
    case D3D12_FEATURE_D3D12_OPTIONS: {
        D3D12_FEATURE_DATA_D3D12_OPTIONS *o = data;
        if (size < sizeof *o) return E_INVALIDARG;
        memset(o, 0, sizeof *o);
        o->ResourceBindingTier = D3D12_RESOURCE_BINDING_TIER_2;
        o->ResourceHeapTier = D3D12_RESOURCE_HEAP_TIER_2;   /* heaps here are descriptions; any mix is fine */
        o->VPAndRTArrayIndexFromAnyShaderFeedingRasterizerSupportedWithoutGSEmulation = TRUE;
        /* ml1970: FORMAT_SUPPORT below already reports UAV_TYPED_LOAD for every
         * uncompressed colour format (Metal read-write textures), but this
         * option stays FALSE by default: reporting it can move an engine that
         * already runs onto different rendering paths. An engine that requires
         * it rejects the device before creating anything, so it is available
         * OPT-IN: madeira.cfg d3d12-typed-uav-load = 1, or
         * MADEIRA_D3D12_TYPED_UAV_LOAD=1 in the environment. */
        {
            static int typed = -1;
            if (typed < 0) {
                char v[4] = {0};
                DWORD n = GetEnvironmentVariableA("MADEIRA_D3D12_TYPED_UAV_LOAD", v, sizeof v);
                typed = ((n == 1 && v[0] == '1') || mad_cfg_int_pe("d3d12-typed-uav-load", 0)) ? 1 : 0;
                d3d12_log("[d3d12-caps] ml1970 typed-uav-load-additional=%d%s\n", typed,
                          typed ? " (opt-in)" : " (default)");
            }
            if (typed) o->TypedUAVLoadAdditionalFormats = TRUE;
        }
        return S_OK;
    }
    case D3D12_FEATURE_ARCHITECTURE: {
        D3D12_FEATURE_DATA_ARCHITECTURE *a = data;
        if (size < sizeof *a) return E_INVALIDARG;
        /* ml1038: DO NOT ADVERTISE UMA UNTIL CPU-VISIBLE TEXTURES EXIST.
         *
         * UMA + CacheCoherentUMA is a promise: resources in CUSTOM heaps with a
         * CPU page property -- TEXTURES INCLUDED -- can be Map()ed and written in
         * place. An engine with a unified-memory path takes us at our word. On
         * the iPhone 18 Pro one title created 625 heaps and every single one was
         * D3D12_HEAP_TYPE_CUSTOM (606 of them texture-only, flags 0x44); it then
         * mapped its textures and wrote pixels straight into them. This runtime
         * makes every texture GPU-private and refuses the Map (39 times in that
         * run). The title ignores the HRESULT, so at first the writes simply
         * vanished -- images composited as solid white -- and eventually it did
         * memset(NULL, 0, 0x80000) in a mip-clear routine and died.
         *
         * Reporting UMA=FALSE is a complete, self-consistent device description:
         * the application falls back to UPLOAD heaps plus CopyTextureRegion, which
         * is the path every discrete GPU exercises and the one this runtime
         * already implements. It costs staging copies. The proper long-term fix
         * is mappable textures (a CPU shadow per subresource, uploaded at Unmap /
         * first GPU use), after which these can go back to TRUE.
         * TileBasedRenderer stays TRUE: it is a hint and promises nothing. */
        a->TileBasedRenderer = TRUE; a->UMA = FALSE; a->CacheCoherentUMA = FALSE;
        return S_OK;
    }
    case D3D12_FEATURE_ARCHITECTURE1: {
        D3D12_FEATURE_DATA_ARCHITECTURE1 *a = data;
        if (size < sizeof *a) return E_INVALIDARG;
        /* ml1038: see D3D12_FEATURE_ARCHITECTURE above. */
        a->TileBasedRenderer = TRUE; a->UMA = FALSE; a->CacheCoherentUMA = FALSE; a->IsolatedMMU = TRUE;
        return S_OK;
    }
    case D3D12_FEATURE_FEATURE_LEVELS: {
        D3D12_FEATURE_DATA_FEATURE_LEVELS *f = data;
        if (size < sizeof *f) return E_INVALIDARG;
        /* The highest of the levels the caller listed that this runtime
         * claims. 12_0 is the ceiling: it is what makes an engine choose its
         * DXIL shaders, and the converter takes nothing older. */
        {
            UINT i;
            f->MaxSupportedFeatureLevel = (D3D_FEATURE_LEVEL)0;
            for (i = 0; f->pFeatureLevelsRequested && i < f->NumFeatureLevels; i++) {
                D3D_FEATURE_LEVEL lv = f->pFeatureLevelsRequested[i];
                if (lv <= D3D_FEATURE_LEVEL_12_0 && lv > f->MaxSupportedFeatureLevel) f->MaxSupportedFeatureLevel = lv;
            }
            if (!f->MaxSupportedFeatureLevel) f->MaxSupportedFeatureLevel = D3D_FEATURE_LEVEL_12_0;
        }
        return S_OK;
    }
    case D3D12_FEATURE_SHADER_MODEL: {
        D3D12_FEATURE_DATA_SHADER_MODEL *m = data;
        if (size < sizeof *m) return E_INVALIDARG;
        if (m->HighestShaderModel > D3D_SHADER_MODEL_6_6) m->HighestShaderModel = D3D_SHADER_MODEL_6_6;
        return S_OK;
    }
    case D3D12_FEATURE_ROOT_SIGNATURE: {
        D3D12_FEATURE_DATA_ROOT_SIGNATURE *r = data;
        if (size < sizeof *r) return E_INVALIDARG;
        r->HighestVersion = D3D_ROOT_SIGNATURE_VERSION_1_1;
        return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS1: {
        /* Shader model 6 needs wave operations; Apple GPUs execute SIMD
         * groups of 32 and the converter maps wave intrinsics onto them. */
        D3D12_FEATURE_DATA_D3D12_OPTIONS1 *o = data;
        if (size < sizeof *o) return E_INVALIDARG;
        memset(o, 0, sizeof *o);
        o->WaveOps = TRUE;
        o->WaveLaneCountMin = 32;
        o->WaveLaneCountMax = 32;
        o->TotalLaneCount = 4096;
        o->ExpandedComputeResourceStates = TRUE;
        o->Int64ShaderOps = TRUE;
        return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS2:
    case D3D12_FEATURE_D3D12_OPTIONS3: case D3D12_FEATURE_D3D12_OPTIONS4:
    case D3D12_FEATURE_D3D12_OPTIONS5: case D3D12_FEATURE_D3D12_OPTIONS6:
    case D3D12_FEATURE_D3D12_OPTIONS7: case D3D12_FEATURE_D3D12_OPTIONS8:
    case D3D12_FEATURE_D3D12_OPTIONS10: case D3D12_FEATURE_D3D12_OPTIONS12:
    case D3D12_FEATURE_D3D12_OPTIONS13: case D3D12_FEATURE_D3D12_OPTIONS14:
    case D3D12_FEATURE_D3D12_OPTIONS15: case D3D12_FEATURE_D3D12_OPTIONS16:
    case D3D12_FEATURE_D3D12_OPTIONS17: case D3D12_FEATURE_D3D12_OPTIONS18:
        /* All-zero is the honest answer: no optional feature in these is
         * implemented, and zero means "not supported" for every field. */
        memset(data, 0, size);
        return S_OK;
    case D3D12_FEATURE_D3D12_OPTIONS9: {
        /* 64-bit atomics: Metal 3.1 on Apple family 9 and Mac2 has them on
         * buffers, and the converter emits them for DXIL 64-bit atomics. An
         * engine with Nanite-style rasterisation refuses shader model 6
         * without this answer (UE 5.4 asked for exactly this, ml869). */
        D3D12_FEATURE_DATA_D3D12_OPTIONS9 *o = data;
        if (size < sizeof *o) return E_INVALIDARG;
        memset(o, 0, sizeof *o);
        o->AtomicInt64OnTypedResourceSupported = TRUE;
        o->AtomicInt64OnGroupSharedSupported = TRUE;
        return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS11: {
        D3D12_FEATURE_DATA_D3D12_OPTIONS11 *o = data;
        if (size < sizeof *o) return E_INVALIDARG;
        o->AtomicInt64OnDescriptorHeapResourceSupported = TRUE;
        return S_OK;
    }
    case D3D12_FEATURE_FORMAT_SUPPORT: {
        /* What a texture of this format can do here. Colour formats: every
         * ordinary use including typed UAV access; depth formats: depth
         * stencil only; anything the format table lacks: nothing. */
        D3D12_FEATURE_DATA_FORMAT_SUPPORT *f = data;
        enum WMTPixelFormat pf; int is_depth;
        if (size < sizeof *f) return E_INVALIDARG;
        f->Support1 = D3D12_FORMAT_SUPPORT1_NONE; f->Support2 = D3D12_FORMAT_SUPPORT2_NONE;
        if (f->Format == DXGI_FORMAT_UNKNOWN) {
            f->Support1 = D3D12_FORMAT_SUPPORT1_BUFFER | D3D12_FORMAT_SUPPORT1_IA_VERTEX_BUFFER | D3D12_FORMAT_SUPPORT1_IA_INDEX_BUFFER;
            return S_OK;
        }
        if (!mad_map_texture_format(f->Format, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, &pf, &is_depth)) return E_FAIL;
        if (is_depth) {
            f->Support1 = D3D12_FORMAT_SUPPORT1_TEXTURE2D | D3D12_FORMAT_SUPPORT1_TEXTURECUBE | D3D12_FORMAT_SUPPORT1_SHADER_LOAD |
                          D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE | D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE_COMPARISON |
                          D3D12_FORMAT_SUPPORT1_DEPTH_STENCIL | D3D12_FORMAT_SUPPORT1_MULTISAMPLE_RENDERTARGET | D3D12_FORMAT_SUPPORT1_MULTISAMPLE_LOAD;
        } else {
            UINT bytes, block;
            mad_format_info(f->Format, &bytes, &block);
            f->Support1 = D3D12_FORMAT_SUPPORT1_BUFFER | D3D12_FORMAT_SUPPORT1_IA_VERTEX_BUFFER | D3D12_FORMAT_SUPPORT1_TEXTURE1D |
                          D3D12_FORMAT_SUPPORT1_TEXTURE2D | D3D12_FORMAT_SUPPORT1_TEXTURE3D | D3D12_FORMAT_SUPPORT1_TEXTURECUBE |
                          D3D12_FORMAT_SUPPORT1_SHADER_LOAD | D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE | D3D12_FORMAT_SUPPORT1_MIP |
                          D3D12_FORMAT_SUPPORT1_SHADER_GATHER | D3D12_FORMAT_SUPPORT1_MULTISAMPLE_LOAD;
            if (block == 1) {   /* uncompressed: render and unordered access too */
                f->Support1 |= D3D12_FORMAT_SUPPORT1_RENDER_TARGET | D3D12_FORMAT_SUPPORT1_BLENDABLE | D3D12_FORMAT_SUPPORT1_DISPLAY |
                               D3D12_FORMAT_SUPPORT1_MULTISAMPLE_RESOLVE | D3D12_FORMAT_SUPPORT1_MULTISAMPLE_RENDERTARGET |
                               D3D12_FORMAT_SUPPORT1_TYPED_UNORDERED_ACCESS_VIEW;
                f->Support2 = D3D12_FORMAT_SUPPORT2_UAV_TYPED_LOAD | D3D12_FORMAT_SUPPORT2_UAV_TYPED_STORE;
                if (f->Format == DXGI_FORMAT_R32_UINT || f->Format == DXGI_FORMAT_R32_SINT)
                    f->Support2 |= D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_ADD | D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_BITWISE_OPS |
                                   D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_COMPARE_STORE_OR_COMPARE_EXCHANGE |
                                   D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_EXCHANGE | D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_SIGNED_MIN_OR_MAX |
                                   D3D12_FORMAT_SUPPORT2_UAV_ATOMIC_UNSIGNED_MIN_OR_MAX;
                if (f->Format == DXGI_FORMAT_R16_UINT || f->Format == DXGI_FORMAT_R32_UINT)
                    f->Support1 |= D3D12_FORMAT_SUPPORT1_IA_INDEX_BUFFER;
            }
        }
        return S_OK;
    }
    case D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS: {
        D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS *m = data;
        if (size < sizeof *m) return E_INVALIDARG;
        /* ml1030: MUST agree with mad_clamp_sample_count(). Reporting a count as
         * unsupported here and then handing that same count to Metal is what
         * cost 28 pipelines. */
        m->NumQualityLevels = (m->SampleCount == mad_clamp_sample_count(m->SampleCount)) ? 1 : 0;
        return S_OK;
    }
    case D3D12_FEATURE_FORMAT_INFO: {
        D3D12_FEATURE_DATA_FORMAT_INFO *fi = data;
        enum WMTPixelFormat pf; int is_depth;
        if (size < sizeof *fi) return E_INVALIDARG;
        if (fi->Format != DXGI_FORMAT_UNKNOWN && !mad_map_texture_format(fi->Format, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, &pf, &is_depth)) return E_INVALIDARG;
        fi->PlaneCount = (fi->Format != DXGI_FORMAT_UNKNOWN && is_depth && pf == WMTPixelFormatDepth32Float_Stencil8) ? 2 : 1;
        return S_OK;
    }
    case D3D12_FEATURE_GPU_VIRTUAL_ADDRESS_SUPPORT: {
        D3D12_FEATURE_DATA_GPU_VIRTUAL_ADDRESS_SUPPORT *g = data;
        if (size < sizeof *g) return E_INVALIDARG;
        g->MaxGPUVirtualAddressBitsPerResource = 40; g->MaxGPUVirtualAddressBitsPerProcess = 40;
        return S_OK;
    }
    case D3D12_FEATURE_SHADER_CACHE: {
        D3D12_FEATURE_DATA_SHADER_CACHE *c = data;
        if (size < sizeof *c) return E_INVALIDARG;
        c->SupportFlags = D3D12_SHADER_CACHE_SUPPORT_SINGLE_PSO;
        return S_OK;
    }
    case D3D12_FEATURE_COMMAND_QUEUE_PRIORITY: {
        D3D12_FEATURE_DATA_COMMAND_QUEUE_PRIORITY *q = data;
        if (size < sizeof *q) return E_INVALIDARG;
        q->PriorityForTypeIsSupported = q->Priority != D3D12_COMMAND_QUEUE_PRIORITY_GLOBAL_REALTIME;
        return S_OK;
    }
    case D3D12_FEATURE_EXISTING_HEAPS: { D3D12_FEATURE_DATA_EXISTING_HEAPS *e = data; if (size < sizeof *e) return E_INVALIDARG; e->Supported = FALSE; return S_OK; }
    case D3D12_FEATURE_SERIALIZATION: { D3D12_FEATURE_DATA_SERIALIZATION *e = data; if (size < sizeof *e) return E_INVALIDARG; e->HeapSerializationTier = D3D12_HEAP_SERIALIZATION_TIER_0; return S_OK; }
    case D3D12_FEATURE_CROSS_NODE: { D3D12_FEATURE_DATA_CROSS_NODE *e = data; if (size < sizeof *e) return E_INVALIDARG; e->SharingTier = D3D12_CROSS_NODE_SHARING_TIER_NOT_SUPPORTED; e->AtomicShaderInstructions = FALSE; return S_OK; }
    case D3D12_FEATURE_DISPLAYABLE: { D3D12_FEATURE_DATA_DISPLAYABLE *e = data; if (size < sizeof *e) return E_INVALIDARG; memset(e, 0, sizeof *e); return S_OK; }
    case D3D12_FEATURE_PROTECTED_RESOURCE_SESSION_SUPPORT: { D3D12_FEATURE_DATA_PROTECTED_RESOURCE_SESSION_SUPPORT *e = data; if (size < sizeof *e) return E_INVALIDARG; e->Support = D3D12_PROTECTED_RESOURCE_SESSION_SUPPORT_FLAG_NONE; return S_OK; }
    case D3D12_FEATURE_PROTECTED_RESOURCE_SESSION_TYPE_COUNT: { D3D12_FEATURE_DATA_PROTECTED_RESOURCE_SESSION_TYPE_COUNT *e = data; if (size < sizeof *e) return E_INVALIDARG; e->Count = 0; return S_OK; }
    default: {
        static UINT seen[32]; static unsigned nseen; unsigned i;
        for (i = 0; i < nseen; i++) if (seen[i] == (UINT)feature) return E_INVALIDARG;
        if (nseen < 32) seen[nseen++] = (UINT)feature;
        d3d12_log("[madeira-d3d12] CheckFeatureSupport(feature %u, %u bytes) refused: not implemented\n",
                  (unsigned)feature, size);
        return E_INVALIDARG;
    }
    }
}
static ULONG STDMETHODCALLTYPE device_AddRef(ID3D12Device *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE device_Release(ID3D12Device *This) {
    struct mad_device *d = (struct mad_device *)This;
    LONG n = InterlockedDecrement(&d->refs);
    if (n == 0) { mad_pd_purge(This);   /* ml1143 */
        /* ml1064: the fence worker holds a raw pointer to this device (ph-rdr31
         * re-created the device on the way back to the menu and destroyed the old
         * one under a live worker). Drain it before anything is freed. */
        if (d->fence_thread) {
            InterlockedExchange(&d->fence_quit, 1);
            SetEvent(d->fence_wake);
            WaitForSingleObject(d->fence_thread, 10000);
            CloseHandle(d->fence_thread); CloseHandle(d->fence_wake);
            d->fence_thread = NULL;
        }
        if (d->gpu_event) NSObject_release(d->gpu_event);
        {   /* ml1072: the runtime's texture heaps die with the device */
            unsigned k;
            if (g_hp_dev == d) g_hp_dev = NULL;
            for (k = 0; k < d->ntheaps; k++) { if (d->theaps[k].heap) NSObject_release(d->theaps[k].heap); free(d->theaps[k].fl); }
            mad_mheap_reclaim(d, 1); free(d->mhret);   /* ml1148 */
            for (k = 0; k < d->nfillpat; k++) if (d->fillpat[k].buf) NSObject_release(d->fillpat[k].buf);   /* ml1151 */
            free(d->theaps); free(d->hret);
            DeleteCriticalSection(&d->heap_lock);
        }
        DeleteCriticalSection(&d->fence_lock); DeleteCriticalSection(&d->ring_lock);
        free(d->fence_jobs); free(d->ring_pool); free(d->ring_retired);
        /* These were retained on creation and were previously leaked. */
        if (d->dsso) NSObject_release(d->dsso);
        if (d->mtl_queue) NSObject_release(d->mtl_queue);
        if (d->mtl_device) NSObject_release(d->mtl_device);
        DeleteCriticalSection(&d->live_lock);
        DeleteCriticalSection(&d->view_lock); free(d->vmap);
        d3d12_log("[madeira-d3d12] destroyed %s\n", d->name);
        free(d);
    }
    return (ULONG)n;
}

static HRESULT STDMETHODCALLTYPE device_CreateCommandQueue(ID3D12Device *This,
        const D3D12_COMMAND_QUEUE_DESC *desc, REFIID riid, void **out) {
    (void)This;
    if (!desc || !out) return E_INVALIDARG;
    if (!mad_list_type_ok(desc->Type)) {
        d3d12_log("[madeira-d3d12] CreateCommandQueue: type %d is not implemented\n", desc->Type);
        return E_NOTIMPL;
    }
    d3d12_log("[madeira-d3d12] command queue: type %d\n", desc->Type);
    struct mad_queue *q = calloc(1, sizeof *q);
    if (!q) return E_OUTOFMEMORY;
    q->type = desc->Type;
    q->vtbl = &g_queue_vtbl; q->refs = 1; q->iid = &IID_ID3D12CommandQueue; q->name = "CommandQueue";
    InitializeCriticalSection(&q->submit_lock);   /* ml1021 */
    if (mad_async_on()) {   /* ml1120 */
        InitializeCriticalSection(&q->sub_lock);
        InitializeConditionVariable(&q->sub_work); InitializeConditionVariable(&q->sub_idle); InitializeConditionVariable(&q->sub_presented);
        q->sub_thread = CreateThread(NULL, 0, mad_sub_worker, q, 0, NULL);
        d3d12_log("[madeira-d3d12] ml1120 queue type %d: submission worker %s\n", desc->Type, q->sub_thread ? "started" : "FAILED to start (replaying on the caller)");
    }
    {   /* ml1021: a pure locking change has no other runtime signature, so it
         * cannot be verified by content on the device without this line. */
        static unsigned said_lock;
        if (!said_lock++)
            d3d12_log("[madeira-d3d12] ml1021 queue submission lock active (Present/Wait flush no longer "
                      "races a list being encoded)\n");
    }
    q->device = (struct mad_device *)This;
    {
        struct mad_device *d = (struct mad_device *)This;
        EnterCriticalSection(&d->live_lock);
        if (d->nqueues < 16) d->queues[d->nqueues++] = q;
        LeaveCriticalSection(&d->live_lock);
    }
    HRESULT hr = queue_QI((ID3D12CommandQueue *)q, riid, out);
    queue_Release((ID3D12CommandQueue *)q);
    return hr;
}

static HRESULT STDMETHODCALLTYPE device_CreateCommandAllocator(ID3D12Device *This,
        D3D12_COMMAND_LIST_TYPE type, REFIID riid, void **out) {
    (void)This;
    if (!out) return E_INVALIDARG;
    if (!mad_list_type_ok(type)) return E_NOTIMPL;
    struct mad_alloc *a = calloc(1, sizeof *a);
    if (!a) return E_OUTOFMEMORY;
    a->type = type;
    a->vtbl = &g_alloc_vtbl; a->refs = 1; a->iid = &IID_ID3D12CommandAllocator; a->name = "CommandAllocator";
    HRESULT hr = alloc_QI((ID3D12CommandAllocator *)a, riid, out);
    alloc_Release((ID3D12CommandAllocator *)a);
    return hr;
}

static HRESULT STDMETHODCALLTYPE device_CreateCommandList(ID3D12Device *This, UINT node,
        D3D12_COMMAND_LIST_TYPE type, ID3D12CommandAllocator *allocator,
        ID3D12PipelineState *pso, REFIID riid, void **out) {
    (void)This; (void)node; (void)pso;
    if (!out || !allocator) return E_INVALIDARG;
    if (!mad_list_type_ok(type)) return E_NOTIMPL;
    if (((struct mad_alloc *)allocator)->type != type) return E_INVALIDARG;
    struct mad_list *l = calloc(1, sizeof *l);
    if (!l) return E_OUTOFMEMORY;
    l->type = type;
    l->vtbl = &g_list_vtbl; l->refs = 1; l->iid = &IID_ID3D12GraphicsCommandList; l->name = "GraphicsCommandList";
    l->device = (struct mad_device *)This;
    l->alloc = (struct mad_alloc *)allocator;
    ID3D12CommandAllocator_AddRef(allocator);
    InterlockedIncrement(&l->alloc->recording);   /* lists are created recording */
    l->recorded_generation = l->alloc->generation;
    HRESULT hr = list_QI((ID3D12GraphicsCommandList *)l, riid, out);
    list_Release((ID3D12GraphicsCommandList *)l);
    return hr;
}

static HRESULT STDMETHODCALLTYPE device_CreateFence(ID3D12Device *This, UINT64 initial,
        D3D12_FENCE_FLAGS flags, REFIID riid, void **out) {
    (void)This;
    if (!out) return E_INVALIDARG;
    if (flags != D3D12_FENCE_FLAG_NONE) return E_NOTIMPL;
    struct mad_fence *f = calloc(1, sizeof *f);
    if (!f) return E_OUTOFMEMORY;
    f->vtbl = &g_fence_vtbl; f->refs = 1; f->iid = &IID_ID3D12Fence; f->name = "Fence";
    f->value = initial;
    InitializeCriticalSection(&f->lock);
    InitializeConditionVariable(&f->cv);
    HRESULT hr = fence_QI((ID3D12Fence *)f, riid, out);
    fence_Release((ID3D12Fence *)f);
    return hr;
}

static UINT STDMETHODCALLTYPE device_GetNodeCount(ID3D12Device *This) { (void)This; return 1; }

/* ---- command signature ---------------------------------------------------
 * The layout of an ExecuteIndirect argument record. The object only has to
 * remember the description faithfully; the interpretation happens when
 * ExecuteIndirect is implemented. UE5 creates these during RHI init, before
 * any draw, so a refusal here ends the run before rendering starts. */
#define MAD_CMDSIG_ARGS_MAX 16
struct mad_cmdsig {
    ID3D12CommandSignatureVtbl *vtbl;
    LONG refs;
    const IID *iid;
    const char *name;
    struct mad_device *device;
    D3D12_COMMAND_SIGNATURE_DESC desc;
    D3D12_INDIRECT_ARGUMENT_DESC args[MAD_CMDSIG_ARGS_MAX];
};
static ID3D12CommandSignatureVtbl g_cmdsig_vtbl;

static HRESULT STDMETHODCALLTYPE cmdsig_QI(ID3D12CommandSignature *This, REFIID riid, void **out) {
    struct mad_obj *o = (struct mad_obj *)This;
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_ID3D12Pageable)) { InterlockedIncrement(&o->refs); *out = This; return S_OK; }
    return mad_qi(o, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE cmdsig_AddRef(ID3D12CommandSignature *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE cmdsig_Release(ID3D12CommandSignature *This) { return mad_release((struct mad_obj *)This); }
static HRESULT STDMETHODCALLTYPE cmdsig_GetPrivateData(ID3D12CommandSignature *This, REFGUID g, UINT *n, void *d) {
    return mad_pd_get(This, g, n, d);   /* ml1143 */
}
static HRESULT STDMETHODCALLTYPE cmdsig_SetPrivateData(ID3D12CommandSignature *This, REFGUID g, UINT n, const void *d) {
    return mad_pd_set(This, g, n, d);   /* ml1143 */
}
static HRESULT STDMETHODCALLTYPE cmdsig_SetPrivateDataInterface(ID3D12CommandSignature *This, REFGUID g, const IUnknown *d) {
    return mad_pd_set_iface(This, g, d);   /* ml1143 */
}
static HRESULT STDMETHODCALLTYPE cmdsig_SetName(ID3D12CommandSignature *This, LPCWSTR name) { (void)This; (void)name; return S_OK; }
static HRESULT STDMETHODCALLTYPE cmdsig_GetDevice(ID3D12CommandSignature *This, REFIID riid, void **out) {
    struct mad_cmdsig *s = (struct mad_cmdsig *)This;
    return s->device->vtbl->QueryInterface((ID3D12Device10 *)s->device, riid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateCommandSignature(ID3D12Device *This,
        const D3D12_COMMAND_SIGNATURE_DESC *desc, ID3D12RootSignature *root_signature,
        REFIID riid, void **out) {
    struct mad_cmdsig *s;
    HRESULT hr;
    UINT i;
    if (!out) return E_INVALIDARG;
    *out = NULL;
    if (!desc || !desc->pArgumentDescs || desc->NumArgumentDescs == 0) return E_INVALIDARG;
    if (desc->NumArgumentDescs > MAD_CMDSIG_ARGS_MAX) {
        d3d12_log("[madeira-d3d12] CreateCommandSignature refused: %u argument descs (limit %u)\n",
                  desc->NumArgumentDescs, (unsigned)MAD_CMDSIG_ARGS_MAX);
        return E_NOTIMPL;
    }
    s = calloc(1, sizeof *s);
    if (!s) return E_OUTOFMEMORY;
    s->vtbl = &g_cmdsig_vtbl; s->refs = 1; s->iid = &IID_ID3D12CommandSignature; s->name = "CommandSignature";
    s->device = (struct mad_device *)This;
    s->desc = *desc;
    memcpy(s->args, desc->pArgumentDescs, desc->NumArgumentDescs * sizeof s->args[0]);
    s->desc.pArgumentDescs = s->args;
    {
        /* One line per signature: argument kinds are what ExecuteIndirect will
         * have to support, so the log lists them in creation order. */
        char kinds[MAD_CMDSIG_ARGS_MAX * 4 + 1];
        int n = 0;
        for (i = 0; i < desc->NumArgumentDescs && n < (int)sizeof kinds - 4; i++)
            n += snprintf(kinds + n, sizeof kinds - n, "%s%u", i ? "," : "", (unsigned)s->args[i].Type);
        d3d12_log("[madeira-d3d12] command signature: stride %u, %u args (types %s), root sig %s\n",
                  desc->ByteStride, desc->NumArgumentDescs, kinds, root_signature ? "given" : "none");
    }
    hr = cmdsig_QI((ID3D12CommandSignature *)s, riid, out);
    cmdsig_Release((ID3D12CommandSignature *)s);
    return hr;
}

/* ---- formats -------------------------------------------------------------
 * Bytes per pixel, or per 4x4 block for the compressed formats. Only the
 * layouts an upload needs; an unknown format is named once and treated as
 * four bytes so the arithmetic stays finite rather than dividing by zero. */
static void mad_format_info(DXGI_FORMAT f, UINT *bytes, UINT *block) {
    *block = 1;
    if (f >= DXGI_FORMAT_R32G32B32A32_TYPELESS && f <= DXGI_FORMAT_R32G32B32A32_SINT) { *bytes = 16; return; }
    if (f >= DXGI_FORMAT_R32G32B32_TYPELESS && f <= DXGI_FORMAT_R32G32B32_SINT) { *bytes = 12; return; }
    if (f >= DXGI_FORMAT_R16G16B16A16_TYPELESS && f <= DXGI_FORMAT_R32G32_SINT) { *bytes = 8; return; }
    if (f >= DXGI_FORMAT_R32G8X24_TYPELESS && f <= DXGI_FORMAT_X32_TYPELESS_G8X24_UINT) { *bytes = 8; return; }
    if (f >= DXGI_FORMAT_R10G10B10A2_TYPELESS && f <= DXGI_FORMAT_X24_TYPELESS_G8_UINT) { *bytes = 4; return; }
    if (f >= DXGI_FORMAT_R8G8_TYPELESS && f <= DXGI_FORMAT_R16_SINT) { *bytes = 2; return; }
    if (f >= DXGI_FORMAT_R8_TYPELESS && f <= DXGI_FORMAT_A8_UNORM) { *bytes = 1; return; }
    if (f == DXGI_FORMAT_R9G9B9E5_SHAREDEXP || f == DXGI_FORMAT_R8G8_B8G8_UNORM || f == DXGI_FORMAT_G8R8_G8B8_UNORM) { *bytes = 4; return; }
    if ((f >= DXGI_FORMAT_BC1_TYPELESS && f <= DXGI_FORMAT_BC1_UNORM_SRGB) ||
        (f >= DXGI_FORMAT_BC4_TYPELESS && f <= DXGI_FORMAT_BC4_SNORM)) { *bytes = 8; *block = 4; return; }
    if ((f >= DXGI_FORMAT_BC2_TYPELESS && f <= DXGI_FORMAT_BC3_UNORM_SRGB) ||
        (f >= DXGI_FORMAT_BC5_TYPELESS && f <= DXGI_FORMAT_BC5_SNORM) ||
        (f >= DXGI_FORMAT_BC6H_TYPELESS && f <= DXGI_FORMAT_BC7_UNORM_SRGB)) { *bytes = 16; *block = 4; return; }
    if (f == DXGI_FORMAT_B5G6R5_UNORM || f == DXGI_FORMAT_B5G5R5A1_UNORM) { *bytes = 2; return; }
    if (f >= DXGI_FORMAT_B8G8R8A8_UNORM && f <= DXGI_FORMAT_B8G8R8X8_UNORM_SRGB) { *bytes = 4; return; }
    if (f == DXGI_FORMAT_UNKNOWN) { *bytes = 1; return; }
    {
        static DXGI_FORMAT seen[16]; static unsigned n; unsigned i;
        for (i = 0; i < n; i++) if (seen[i] == f) { *bytes = 4; return; }
        if (n < 16) seen[n++] = f;
        d3d12_log("[madeira-d3d12] format %u has no size entry; assuming 4 bytes per pixel\n", (unsigned)f);
    }
    *bytes = 4;
}

static UINT64 mad_align(UINT64 v, UINT64 a) { return (v + a - 1) & ~(a - 1); }

/* The standard subresource layout: rows padded to 256 bytes, each subresource
 * starting on a 512-byte boundary. Both constants are the API's own. */
static void STDMETHODCALLTYPE device_GetCopyableFootprints(ID3D12Device *This,
        const D3D12_RESOURCE_DESC *desc, UINT first, UINT count, UINT64 base_offset,
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT *layouts, UINT *row_count, UINT64 *row_size,
        UINT64 *total_bytes) {
    UINT bytes, block, i;
    UINT64 offset = base_offset;
    UINT mips = desc->MipLevels ? desc->MipLevels : 1;
    (void)This;
    mad_format_info(desc->Format, &bytes, &block);
    for (i = 0; i < count; i++) {
        UINT s = first + i, mip = s % mips;
        UINT64 w, h, d, rowbytes, pitch, rows;
        if (desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) {
            w = desc->Width; h = 1; d = 1; rowbytes = desc->Width;
        } else {
            w = desc->Width >> mip; if (!w) w = 1;
            h = desc->Height >> mip; if (!h) h = 1;
            d = 1;
            if (desc->Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) {
                d = desc->DepthOrArraySize >> mip; if (!d) d = 1;
            }
            rowbytes = ((w + block - 1) / block) * bytes;
        }
        rows = (h + block - 1) / block;
        pitch = mad_align(rowbytes, D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
        offset = mad_align(offset, D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT);
        if (layouts) {
            layouts[i].Offset = offset;
            layouts[i].Footprint.Format = desc->Format;
            layouts[i].Footprint.Width = (UINT)w;
            layouts[i].Footprint.Height = (UINT)h;
            layouts[i].Footprint.Depth = (UINT)d;
            layouts[i].Footprint.RowPitch = (UINT)pitch;
        }
        if (row_count) row_count[i] = (UINT)rows;
        if (row_size) row_size[i] = rowbytes;
        offset += pitch * rows * d;
    }
    if (total_bytes) *total_bytes = offset - base_offset;
}

static D3D12_RESOURCE_ALLOCATION_INFO * STDMETHODCALLTYPE device_GetResourceAllocationInfo(
        ID3D12Device *This, D3D12_RESOURCE_ALLOCATION_INFO *ret, UINT visible_mask, UINT n,
        const D3D12_RESOURCE_DESC *descs) {
    UINT64 total = 0, align = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT, i;
    (void)visible_mask;
    for (i = 0; i < n; i++) {
        const D3D12_RESOURCE_DESC *d = &descs[i];
        UINT64 bytes = 0, a = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT, msz = 0, mal = 0;
        struct mad_device *md = (struct mad_device *)This;
        if (d->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) {
            bytes = d->Width;
            MTLDevice_heapBufferSizeAndAlign(md->mtl_device, d->Width ? d->Width : 1, WMTResourceStorageModePrivate, &msz, &mal);   /* ml1145 */
        } else {
            struct WMTTextureInfo ti; enum WMTPixelFormat pf; int isd;
            UINT subs = (d->MipLevels ? d->MipLevels : 1) *
                        (d->Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ? 1 : (d->DepthOrArraySize ? d->DepthOrArraySize : 1));
            device_GetCopyableFootprints(This, d, 0, subs, 0, NULL, NULL, NULL, &bytes);
            if (d->SampleDesc.Count > 1) a = D3D12_DEFAULT_MSAA_RESOURCE_PLACEMENT_ALIGNMENT;
            if (mad_texinfo_from_desc(d, &ti, &pf, &isd)) MTLDevice_heapTextureSizeAndAlign(md->mtl_device, &ti, &msz, &mal);   /* ml1145 */
        }
        /* ml1145: a placed resource is really placed now, so the application must
         * plan its heap with the size and alignment Metal needs, not the linear
         * footprint (tiled textures, compression metadata, page rounding). */
        if (msz > bytes) bytes = msz;
        if (mal > a) a = mal;
        if (a > align) align = a;
        total = mad_align(total, a) + mad_align(bytes, a);
    }
    ret->SizeInBytes = mad_align(total, align);
    ret->Alignment = align;
    if (n == 1 && descs[0].Dimension == D3D12_RESOURCE_DIMENSION_BUFFER && descs[0].Width >= (32u << 20)) {
        static unsigned said;
        if (said++ < 64)
            d3d12_log("[madeira-d3d12] alloc-info: buffer %llu MB flags %#x req-align %llu -> size %llu KB align %llu\n",
                      (unsigned long long)(descs[0].Width >> 20), (unsigned)descs[0].Flags, (unsigned long long)descs[0].Alignment,
                      (unsigned long long)(ret->SizeInBytes >> 10), (unsigned long long)ret->Alignment);
    }
    return ret;
}

static D3D12_RESOURCE_DESC1 * STDMETHODCALLTYPE res_GetDesc1(ID3D12Resource2 *This, D3D12_RESOURCE_DESC1 *ret) {
    memset(ret, 0, sizeof *ret);
    memcpy(ret, &((struct mad_resource *)This)->desc, sizeof(D3D12_RESOURCE_DESC));   /* DESC is a prefix of DESC1 */
    return ret;
}
static D3D12_RESOURCE_DESC * STDMETHODCALLTYPE res_GetDesc(ID3D12Resource *This, D3D12_RESOURCE_DESC *ret) {
    *ret = ((struct mad_resource *)This)->desc;
    return ret;
}

/* ---- descriptors beyond textures ------------------------------------------
 * The converter's buffer entry: address in the first word, byte size in the
 * low half of the third (IRDescriptorTableSetBuffer / GetBufferMetadata);
 * bit 63 marks a typed buffer, which nothing here produces yet. */
static void mad_set_buffer_descriptor(struct mad_descriptor *e, UINT64 va, UINT64 size) {
    e->gpu_va = va;
    e->texture_view_id = 0;
    e->metadata = size & 0xffffffffu;
}

static int mad_map_texture_format(DXGI_FORMAT f, D3D12_RESOURCE_FLAGS flags, enum WMTPixelFormat *out, int *is_depth);
/* ml905: a typed buffer view. Returns 1 and fills the descriptor per the
 * converter's IRDescriptorTableSetBufferView contract: gpuVA = buffer + byte
 * offset, textureViewID = a texture-buffer view whose first element is at an
 * aligned offset, metadata = size | offset-in-elements << 32 | typed bit 63.
 * Without this, UE's manual vertex fetch (positions, tangents, UVs read from
 * Buffer<float>/Buffer<float4> SRVs) sees a raw address the converted shader
 * never dereferences: every scene vertex came out at the origin and nothing
 * rasterised (depth 0.0 % written, GBuffers 0.0 %). */
static void mad_acct(struct mad_resource *r, unsigned cat, UINT64 bytes, int sign) {
    LONG64 now;
    if (cat >= MAD_CAT_N) return;
    if (sign > 0) { r->acct_bytes = bytes; r->acct_cat = cat; InterlockedIncrement(&g_cat_count[cat]); }
    else InterlockedDecrement(&g_cat_count[cat]);
    now = InterlockedExchangeAdd64(&g_cat_bytes[cat], sign > 0 ? (LONG64)bytes : -(LONG64)bytes) + (sign > 0 ? (LONG64)bytes : -(LONG64)bytes);
    if (now > g_cat_peak[cat]) g_cat_peak[cat] = now;
}
#define MAD_HP_HEAP_BYTES (64ull << 20)
#define MAD_HP_MAX_TEX    (2ull << 20)
static UINT64 mad_gpu_completed(struct mad_device *d);
/* lock held: put a block back, keeping the list sorted and coalesced */
static void mad_hp_free_locked(struct mad_texheap *h, UINT64 off, UINT64 size) {
    unsigned i;
    for (i = 0; i < h->nfl && h->fl[i].off < off; i++) ;
    if (i > 0 && h->fl[i - 1].off + h->fl[i - 1].size == off) { h->fl[i - 1].size += size; off = h->fl[i - 1].off; size = h->fl[i - 1].size; i--; }
    else {
        if (!mad_grow((void **)&h->fl, &h->fl_cap, h->nfl + 1, sizeof *h->fl)) return;
        memmove(&h->fl[i + 1], &h->fl[i], (h->nfl - i) * sizeof *h->fl);
        h->fl[i].off = off; h->fl[i].size = size; h->nfl++;
    }
    if (i + 1 < h->nfl && h->fl[i].off + h->fl[i].size == h->fl[i + 1].off) {
        h->fl[i].size += h->fl[i + 1].size;
        memmove(&h->fl[i + 1], &h->fl[i + 2], (h->nfl - i - 2) * sizeof *h->fl); h->nfl--;
    }
}
/* ml1148: a D3D12 heap's Metal heap is released only once the GPU has finished
 * every command buffer committed before the application released it, with two
 * more completed after. ph-valley04/05: twice, a command buffer's own cleanup
 * (IOGPUMetalCommandBufferStorageReset) released an object that was already
 * freed, first during a capture and then while the fence mode was switched;
 * heaps freed with placed resources still held by an in-flight command buffer
 * are the new lifetime in ml1145. */
static void mad_mheap_reclaim(struct mad_device *d, int all) {
    obj_handle_t done_list[64]; void *done_mem[64]; unsigned nd = 0, i = 0;
    UINT64 done;
    if (!d) return;
    done = mad_gpu_completed(d);
    EnterCriticalSection(&d->heap_lock);
    while (i < d->nmhret && nd < 64) {
        if (all || d->mhret[i].serial + 2 <= done) { done_list[nd] = d->mhret[i].heap; done_mem[nd++] = d->mhret[i].mem; d->mhret[i] = d->mhret[--d->nmhret]; }
        else i++;
    }
    LeaveCriticalSection(&d->heap_lock);
    for (i = 0; i < nd; i++) {
        if (done_list[i]) { mad_unresident(d, done_list[i]); NSObject_release(done_list[i]); }
        if (done_mem[i]) VirtualFree(done_mem[i], 0, MEM_RELEASE);   /* ml1154: a file-backed CPU-visible buffer's storage */
    }
}
static void mad_hp_reclaim_locked(struct mad_device *d) {
    UINT64 done = mad_gpu_completed(d); unsigned i = 0;
    while (i < d->nhret) {
        if (d->hret[i].serial <= done) {
            mad_hp_free_locked(&d->theaps[d->hret[i].heap], d->hret[i].off, d->hret[i].size);
            InterlockedExchangeAdd64(&d->hp_live_bytes, -(LONG64)d->hret[i].size);
            d->hret[i] = d->hret[--d->nhret];
        } else i++;
    }
}
/* Returns the heap index or -1; *off is the placed offset. */
static int mad_hp_alloc(struct mad_device *d, UINT64 size, UINT64 align, UINT64 *off) {
    unsigned hi, bi; int found = -1;
    if (!align) align = 1;
    EnterCriticalSection(&d->heap_lock);
    mad_hp_reclaim_locked(d);
    for (hi = 0; hi < d->ntheaps && found < 0; hi++) {
        struct mad_texheap *h = &d->theaps[hi];
        for (bi = 0; bi < h->nfl; bi++) {
            UINT64 a = (h->fl[bi].off + align - 1) & ~(align - 1);
            if (a + size <= h->fl[bi].off + h->fl[bi].size) {
                UINT64 head = a - h->fl[bi].off, tail = (h->fl[bi].off + h->fl[bi].size) - (a + size);
                UINT64 boff = h->fl[bi].off, bsize = h->fl[bi].size;
                memmove(&h->fl[bi], &h->fl[bi + 1], (h->nfl - bi - 1) * sizeof *h->fl); h->nfl--;
                if (head) mad_hp_free_locked(h, boff, head);
                if (tail) mad_hp_free_locked(h, a + size, tail);
                (void)bsize;
                *off = a; found = (int)hi; break;
            }
        }
    }
    if (found < 0) {
        UINT64 hs = size > MAD_HP_HEAP_BYTES ? size : MAD_HP_HEAP_BYTES;
        obj_handle_t heap = MTLDevice_newPlacementHeap(d->mtl_device, hs, WMTResourceStorageModePrivate);
        if (heap && mad_grow((void **)&d->theaps, &d->theaps_cap, d->ntheaps + 1, sizeof *d->theaps)) {
            struct mad_texheap *h = &d->theaps[d->ntheaps];
            memset(h, 0, sizeof *h);
            h->heap = heap; h->size = hs;
            mad_hp_free_locked(h, 0, hs);
            mad_resident(d, heap);   /* residency follows the heap, not its textures */
            InterlockedExchangeAdd64(&d->hp_total_bytes, (LONG64)hs);
            found = (int)d->ntheaps++;
            /* the whole heap is free, so the first block fits by construction */
            memmove(&h->fl[0], &h->fl[1], (h->nfl - 1) * sizeof *h->fl); h->nfl--;
            if (hs > size) mad_hp_free_locked(h, size, hs - size);
            *off = 0;
            d3d12_log("[madeira-d3d12] ml1072 texture heap #%u created (%llu MB; %lld MB in heaps, %ld small textures placed so far)\n",
                      d->ntheaps, (unsigned long long)(hs >> 20), (long long)(d->hp_total_bytes >> 20), d->hp_textures);
        } else if (heap) NSObject_release(heap);
    }
    if (found >= 0) InterlockedExchangeAdd64(&d->hp_live_bytes, (LONG64)size);
    LeaveCriticalSection(&d->heap_lock);
    return found;
}
static void mad_hp_release(struct mad_device *d, struct mad_resource *r) {
    EnterCriticalSection(&d->heap_lock);
    if (mad_grow((void **)&d->hret, &d->hret_cap, d->nhret + 1, sizeof *d->hret)) {
        struct mad_hret *e = &d->hret[d->nhret++];
        e->heap = r->hp_heap; e->off = r->hp_off; e->size = r->hp_size; e->serial = (UINT64)d->gpu_serial;
    }
    LeaveCriticalSection(&d->heap_lock);
}

static int mad_view_grow(struct mad_resource *r, void **arr, unsigned *cap, unsigned need, size_t elem) {
    unsigned ncap; void *n;
    if (need <= *cap) return 1;
    if (r->nview_old >= 24) return 0;
    ncap = *cap ? *cap * 2 : 16;
    while (ncap < need) ncap *= 2;
    n = calloc(ncap, elem);
    if (!n) return 0;
    if (*arr) { memcpy(n, *arr, (size_t)*cap * elem); r->view_old[r->nview_old++] = *arr; }
    *arr = n; *cap = ncap;
    return 1;
}
static void mad_view_census(const char *kind, struct mad_resource *r, unsigned n) {
    /* Unbounded growth would be its own defect (a ring buffer viewed at a new
     * offset every frame); say so at each power of four instead of guessing. */
    if (n == 64 || n == 256 || n == 1024 || n == 4096 || n == 16384)
        d3d12_log("[madeira-d3d12] ml1049 resource '%s' (%llu bytes) now has %u %s views\n",
                  r->name, (unsigned long long)r->size, n, kind);
}

static int mad_typed_buffer_view(struct mad_device *d, struct mad_resource *r, DXGI_FORMAT fmt,
                                 UINT64 first, UINT64 num, int uav, struct mad_descriptor *e) {
    enum WMTPixelFormat pf; int is_depth = 0; UINT bytes, block; unsigned k;
    UINT64 byte_off, aligned, elem_off, width, bpr;
    struct WMTTextureInfo ti;
    obj_handle_t tex;
    static unsigned said_fail, said_ok;
    if (!r->buffer || !mad_map_texture_format(fmt, 0, &pf, &is_depth) || is_depth) return 0;
    mad_format_info(fmt, &bytes, &block);
    if (!bytes || block != 1) return 0;
    byte_off = first * bytes;
    EnterCriticalSection(&d->view_lock);   /* ml1049: creation races creation on another thread */
    for (k = 0; k < r->ntview; k++)
        if (r->tview[k].fmt == (UINT)fmt && r->tview[k].off == byte_off && r->tview[k].num == num && r->tview[k].uav == (UINT8)uav) break;
    if (k == r->ntview) {
        aligned = byte_off & ~(UINT64)63;                   /* linear texture alignment on Apple GPUs is <= 64 */
        elem_off = (byte_off - aligned) / bytes;
        width = num + elem_off;
        if (aligned + width * bytes > r->size) width = (r->size - aligned) / bytes;
        if (!width || width > (1u << 28)) { LeaveCriticalSection(&d->view_lock); return 0; }
        bpr = width * bytes;
        memset(&ti, 0, sizeof ti);
        ti.pixel_format = pf; ti.width = (uint32_t)width; ti.height = 1; ti.depth = 1; ti.array_length = 1;
        ti.type = WMTTextureTypeTextureBuffer; ti.mipmap_level_count = 1; ti.sample_count = 1;
        ti.usage = uav ? (WMTTextureUsageShaderRead | WMTTextureUsageShaderWrite) : WMTTextureUsageShaderRead;
        ti.options = r->cpu ? WMTResourceStorageModeShared : WMTResourceStorageModePrivate;
        tex = MTLBuffer_newTexture(r->buffer, &ti, aligned, bpr);
        if (!tex || !ti.gpu_resource_id) {
            if (said_fail++ < 8)
                d3d12_log("[madeira-d3d12] typed buffer view FAILED: fmt %u first %llu num %llu (buffer %llu bytes)\n",
                          (unsigned)fmt, (unsigned long long)first, (unsigned long long)num, (unsigned long long)r->size);
            LeaveCriticalSection(&d->view_lock);
            return 0;
        }
        if (!mad_view_grow(r, (void **)&r->tview, &r->tview_cap, r->ntview + 1, sizeof *r->tview)) {
            NSObject_release(tex); LeaveCriticalSection(&d->view_lock); return 0;
        }
        /* ml1126: NOT added to the residency set. A texture-buffer view aliases
         * its buffer's storage, and the buffer is already a member (as a placed
         * texture is covered by its heap, ml1072). Views are made per distinct
         * (format, offset, count), so a game sub-allocating typed-buffer ranges
         * out of a long-lived pool adds members at ~170/s forever: ph-rdr78's
         * set reached 216,836 and IOGPU aborted the process ("Unable to add
         * allocation to set", device log 14:06:41), which is the end-of-run
         * "freeze" (game exits with 0x80000101, its threads then fault on
         * reclaimed pool pages). */
        InterlockedIncrement(&g_tview_live); InterlockedIncrement(&g_tview_made);
        k = r->ntview;
        r->tview[k].fmt = (UINT)fmt; r->tview[k].off = byte_off; r->tview[k].num = num; r->tview[k].uav = (UINT8)uav;
        r->tview[k].tex = tex; r->tview[k].id = ti.gpu_resource_id;
        r->ntview = k + 1;   /* published last: a reader never sees a half-written entry */
        mad_vmap_put_locked(d, ti.gpu_resource_id, (UINT32)num, (UINT32)elem_off);
        mad_view_census("typed-buffer", r, r->ntview);
        if (said_ok++ < 12)
            d3d12_log("[madeira-d3d12] typed buffer view: fmt %u first %llu num %llu%s -> %ux1 texture buffer, element offset %llu\n",
                      (unsigned)fmt, (unsigned long long)first, (unsigned long long)num, uav ? " (UAV)" : "",
                      (unsigned)width, (unsigned long long)elem_off);
    }
    aligned = r->tview[k].off & ~(UINT64)63; elem_off = (r->tview[k].off - aligned) / bytes;
    e->gpu_va = r->gpu_address + r->tview[k].off;
    e->texture_view_id = r->tview[k].id;
    e->metadata = ((num * bytes) & 0xffffffffull) | ((elem_off & 0x7fffffffull) << 32) | (1ull << 63);
    LeaveCriticalSection(&d->view_lock);
    return 1;
}

/* ml913: the texture resource id a descriptor should carry for a view of the
 * given D3D dimension and sub-range. The base texture when it already matches;
 * otherwise a (cached) Metal texture view of the right type. */
/* ml918: pf = 0 keeps the texture's own format; swz packs four
 * WMTTextureSwizzle values (r | g<<8 | b<<16 | a<<24), 0 = identity. */
#define MAD_SWZ_IDENTITY (2u | 3u << 8 | 4u << 16 | 5u << 24)
static UINT64 mad_texture_view_id(struct mad_device *d, struct mad_resource *r, enum WMTTextureType want,
                                  UINT lvl0, UINT nlvl, UINT sl0, UINT nsl, enum WMTPixelFormat pf, UINT swz) {
    unsigned k; UINT64 id = 0; obj_handle_t tex;
    struct WMTTextureSwizzleChannels sw;
    static unsigned said, said_fail;
    if (!r->texture) return 0;
    if (!swz) swz = MAD_SWZ_IDENTITY;
    if (!pf || (r->is_depth && pf != WMTPixelFormatX32_Stencil8)) pf = r->tex_pf;   /* depth textures keep their format: sampled as depth; ml1101: unless a stencil view */
    if (nlvl == 0 || nlvl == ~0u || lvl0 + nlvl > r->tex_mips) nlvl = r->tex_mips > lvl0 ? r->tex_mips - lvl0 : 1;
    if (nsl == 0 || nsl == ~0u || sl0 + nsl > r->tex_layers) nsl = r->tex_layers > sl0 ? r->tex_layers - sl0 : 1;
    if (want == r->tex_type && lvl0 == 0 && nlvl == r->tex_mips && sl0 == 0 && nsl == r->tex_layers && pf == r->tex_pf && swz == MAD_SWZ_IDENTITY)
        return r->gpu_resource_id;
    if (want == WMTTextureTypeCube) nsl = 6;
    if (want == WMTTextureTypeCubeArray) nsl = (nsl / 6) * 6 ? (nsl / 6) * 6 : 6;
    EnterCriticalSection(&d->view_lock);   /* ml1049 */
    for (k = 0; k < r->nxview; k++)
        if (r->xview[k].type == (UINT)want && r->xview[k].lvl0 == lvl0 && r->xview[k].nlvl == nlvl && r->xview[k].sl0 == sl0 && r->xview[k].nsl == nsl &&
            r->xview[k].pf == (UINT)pf && r->xview[k].swz == swz) {
            UINT64 hit = r->xview[k].id;
            LeaveCriticalSection(&d->view_lock);
            return hit;
        }
    sw.r = (enum WMTTextureSwizzle)(swz & 0xff); sw.g = (enum WMTTextureSwizzle)((swz >> 8) & 0xff);
    sw.b = (enum WMTTextureSwizzle)((swz >> 16) & 0xff); sw.a = (enum WMTTextureSwizzle)((swz >> 24) & 0xff);
    tex = MTLTexture_newTextureView(r->texture, pf, want, (uint16_t)lvl0, (uint16_t)nlvl, (uint16_t)sl0, (uint16_t)nsl, sw, &id);
    if (!tex || !id) {
        if (said_fail++ < 12)
            d3d12_log("[madeira-d3d12] texture view FAILED: type %u -> %u, levels %u+%u, slices %u+%u of %ux%u (%s)\n",
                      (unsigned)r->tex_type, (unsigned)want, lvl0, nlvl, sl0, nsl, r->width, r->height, r->name);
        if (tex) NSObject_release(tex);
        LeaveCriticalSection(&d->view_lock);
        return r->gpu_resource_id;   /* keep the old behaviour rather than an empty slot */
    }
    /* ml1049: was an 8-entry ring that released views descriptors still named. */
    if (!mad_view_grow(r, (void **)&r->xview, &r->xview_cap, r->nxview + 1, sizeof *r->xview)) {
        NSObject_release(tex); LeaveCriticalSection(&d->view_lock); return r->gpu_resource_id;
    }
    mad_resident(d, tex);
    InterlockedIncrement(&g_xview_live);   /* ml1126 */
    k = r->nxview;
    r->xview[k].type = (UINT)want; r->xview[k].lvl0 = lvl0; r->xview[k].nlvl = nlvl; r->xview[k].sl0 = sl0; r->xview[k].nsl = nsl;
    r->xview[k].pf = (UINT)pf; r->xview[k].swz = swz;
    r->xview[k].tex = tex; r->xview[k].id = id;
    r->nxview = k + 1;
    mad_vmap_put_locked(d, id, nsl ? nsl : 1, 0);
    mad_view_census("texture", r, r->nxview);
    LeaveCriticalSection(&d->view_lock);
    if (said++ < 24)
        d3d12_log("[madeira-d3d12] texture view: type %u -> %u, fmt %u -> %u, swz %08x, levels %u+%u, slices %u+%u of %ux%u x%u (%s)\n",
                  (unsigned)r->tex_type, (unsigned)want, (unsigned)r->tex_pf, (unsigned)pf, swz, lvl0, nlvl, sl0, nsl, r->width, r->height, r->tex_layers, r->name);
    return id;
}

static void STDMETHODCALLTYPE device_CreateConstantBufferView(ID3D12Device *This,
        const D3D12_CONSTANT_BUFFER_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_descriptor *e = (struct mad_descriptor *)h.ptr;
    if (!e) return;
    if (!desc || !desc->BufferLocation) {   /* a null view: defined to read as zeros (ml1049) */
        struct mad_device *nd = (struct mad_device *)This;
        memset(e, 0, sizeof *e);
        if (nd && nd->null_gpu) { e->gpu_va = nd->null_gpu; e->metadata = 65536; }
        return;
    }
    mad_set_buffer_descriptor(e, desc->BufferLocation, desc->SizeInBytes);
}

static void STDMETHODCALLTYPE device_CreateUnorderedAccessView(ID3D12Device *This,
        ID3D12Resource *res, ID3D12Resource *counter, const D3D12_UNORDERED_ACCESS_VIEW_DESC *desc,
        D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_resource *r = (struct mad_resource *)res;
    struct mad_descriptor *e = (struct mad_descriptor *)h.ptr;
    static int said_counter, said_kind;
    if (!e) return;
    if (!r) { memset(e, 0, sizeof *e); return; }                                /* a null view */
    if (counter && !said_counter++)
        d3d12_log("[madeira-d3d12] CreateUnorderedAccessView: counter resources are ignored\n");
    if (r->buffer) {
        UINT64 stride = 4, first = 0, num = r->size / 4;
        if (desc && desc->ViewDimension == D3D12_UAV_DIMENSION_BUFFER) {
            UINT bytes, block;
            first = desc->Buffer.FirstElement; num = desc->Buffer.NumElements;
            if (desc->Buffer.StructureByteStride) stride = desc->Buffer.StructureByteStride;
            else if (desc->Format != DXGI_FORMAT_UNKNOWN) {
                mad_format_info(desc->Format, &bytes, &block); stride = bytes;
                if (!(desc->Buffer.Flags & D3D12_BUFFER_UAV_FLAG_RAW) &&
                    mad_typed_buffer_view((struct mad_device *)This, r, desc->Format, first, num, 1, e)) return;   /* ml905 */
            }
        }
        mad_set_buffer_descriptor(e, r->gpu_address + first * stride, num * stride);
        return;
    }
    mad_view_list_add((struct mad_device *)This, 1, r);
    if (r->texture) {
        UINT64 view_id = r->gpu_resource_id;
        if (desc) {   /* ml913: one mip, the named slices, the named dimension */
            enum WMTTextureType want = r->tex_type; UINT lvl0 = 0, sl0 = 0, nsl = ~0u;
            switch (desc->ViewDimension) {
            case D3D12_UAV_DIMENSION_TEXTURE1D: want = WMTTextureType2DArray; lvl0 = desc->Texture1D.MipSlice; nsl = 1; break;   /* ml932: arrays everywhere */
            case D3D12_UAV_DIMENSION_TEXTURE1DARRAY: want = WMTTextureType2DArray; lvl0 = desc->Texture1DArray.MipSlice; sl0 = desc->Texture1DArray.FirstArraySlice; nsl = desc->Texture1DArray.ArraySize; break;
            case D3D12_UAV_DIMENSION_TEXTURE2D: want = WMTTextureType2DArray; lvl0 = desc->Texture2D.MipSlice; nsl = 1; break;
            case D3D12_UAV_DIMENSION_TEXTURE2DARRAY: want = WMTTextureType2DArray; lvl0 = desc->Texture2DArray.MipSlice; sl0 = desc->Texture2DArray.FirstArraySlice; nsl = desc->Texture2DArray.ArraySize; break;
            case D3D12_UAV_DIMENSION_TEXTURE3D:
                want = WMTTextureType3D; lvl0 = desc->Texture3D.MipSlice;
                /* ml935 probe: a D3D12 UAV on a 3D texture can address a WINDOW
                 * of depth slices, and the shader's z is relative to it. We
                 * ignore FirstWSlice/WSize (the RTV path honours them), and
                 * Metal cannot express a depth window in a texture view at all
                 * -- only array layers. If UE's distance-field brick uploader
                 * uses a non-zero window, every brick lands at the wrong depth,
                 * which would leave the atlas looking unpopulated. Say whether
                 * it actually happens before building machinery for it. */
                {
                    static unsigned said;
                    if ((desc->Texture3D.FirstWSlice || (desc->Texture3D.WSize && desc->Texture3D.WSize != ~0u))
                        && said++ < 16)
                        d3d12_log("[uav3d] %s %ux%ux%u: FirstWSlice=%u WSize=%u mip=%u <- DEPTH WINDOW IGNORED\n",
                                  r->name ? r->name : "?", r->width, r->height, r->tex_layers,
                                  desc->Texture3D.FirstWSlice, desc->Texture3D.WSize, lvl0);
                }
                break;
            default: break;
            }
            /* ml928: a UAV may reinterpret the resource's format (an RG32Float
             * grid written through an RG32Uint view, a typeless resource
             * viewed as a concrete format). Before this every UAV used the
             * resource's own Metal format, so a kernel storing uints into a
             * float texture had its values converted numerically -- UE's
             * local-exposure bilateral grid became garbage and the tonemapper
             * flattened the whole frame to grey. */
            {
                enum WMTPixelFormat pf = 0; int vd = 0;
                if (desc->Format != DXGI_FORMAT_UNKNOWN && !r->is_depth && mad_map_texture_format(desc->Format, 0, &pf, &vd) && !vd && pf != r->tex_pf) {
                    static unsigned said; if (said++ < 8)
                        d3d12_log("[madeira-d3d12] UAV reinterprets %s %ux%u t%u pf%u as format %u -> pf%u\n", r->name, r->width, r->height,
                                  (unsigned)r->tex_type, (unsigned)r->tex_pf, (unsigned)desc->Format, (unsigned)pf);
                } else pf = 0;
                view_id = mad_texture_view_id((struct mad_device *)This, r, want, lvl0, 1, sl0, nsl, pf, MAD_SWZ_IDENTITY);
            }
        }
        e->gpu_va = 0; e->texture_view_id = view_id; e->metadata = 0;
        return;
    }
    if (!said_kind++) d3d12_log("[madeira-d3d12] CreateUnorderedAccessView: resource has no backend object\n");
    memset(e, 0, sizeof *e);
}

/* Descriptors are plain bytes in both heap kinds, so a copy is a copy. The
 * stride is the heap type's, which is why the type is part of the call. */
static void STDMETHODCALLTYPE device_CopyDescriptorsSimple(ID3D12Device *This, UINT n,
        D3D12_CPU_DESCRIPTOR_HANDLE dst, D3D12_CPU_DESCRIPTOR_HANDLE src, D3D12_DESCRIPTOR_HEAP_TYPE type) {
    (void)This;
    if (!n || !dst.ptr || !src.ptr) return;
    memmove((void *)dst.ptr, (const void *)src.ptr, (size_t)n * mad_descriptor_stride(type));
}

static void STDMETHODCALLTYPE device_CopyDescriptors(ID3D12Device *This,
        UINT ndst, const D3D12_CPU_DESCRIPTOR_HANDLE *dsts, const UINT *dst_sizes,
        UINT nsrc, const D3D12_CPU_DESCRIPTOR_HANDLE *srcs, const UINT *src_sizes,
        D3D12_DESCRIPTOR_HEAP_TYPE type) {
    UINT stride = mad_descriptor_stride(type);
    UINT di = 0, si = 0, dpos = 0, spos = 0;
    (void)This;
    /* Sizes may be NULL, meaning every range is one descriptor long. */
    while (di < ndst && si < nsrc) {
        UINT dlen = dst_sizes ? dst_sizes[di] : 1, slen = src_sizes ? src_sizes[si] : 1;
        UINT take = (dlen - dpos < slen - spos) ? dlen - dpos : slen - spos;
        if (take && dsts[di].ptr && srcs[si].ptr)
            memmove((char *)dsts[di].ptr + (size_t)dpos * stride,
                    (const char *)srcs[si].ptr + (size_t)spos * stride, (size_t)take * stride);
        dpos += take; spos += take;
        if (dpos >= dlen) { di++; dpos = 0; }
        if (spos >= slen) { si++; spos = 0; }
    }
}

/* ---- query heap -----------------------------------------------------------
 * Queries are accepted and resolve to zero: no timing, no occlusion counts.
 * That is the honest minimum the engine's startup needs (it creates the heaps
 * and verifies the results). Zero occlusion counts will hide geometry once
 * culling runs, so the first resolve says so in the log. */
struct mad_queryheap {
    ID3D12QueryHeapVtbl *vtbl; LONG refs; const IID *iid; const char *name;
    struct mad_device *device;
    D3D12_QUERY_HEAP_DESC desc;
    UINT64 *results; CRITICAL_SECTION lock;   /* ml1088: the last completed value of every query */
};
static ID3D12QueryHeapVtbl g_qheap_vtbl;
static HRESULT STDMETHODCALLTYPE qheap_QI(ID3D12QueryHeap *This, REFIID riid, void **out) {
    struct mad_obj *o = (struct mad_obj *)This;
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_ID3D12Pageable)) { InterlockedIncrement(&o->refs); *out = This; return S_OK; }
    return mad_qi(o, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE qheap_AddRef(ID3D12QueryHeap *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE qheap_Release(ID3D12QueryHeap *This) {
    struct mad_queryheap *q = (struct mad_queryheap *)This;
    LONG r = InterlockedDecrement(&q->refs);
    if (r == 0) { mad_pd_purge(This);   /* ml1143 */ free(q->results); DeleteCriticalSection(&q->lock); free(q); }   /* ml1088 */
    return (ULONG)r;
}
static HRESULT STDMETHODCALLTYPE qheap_GetPrivateData(ID3D12QueryHeap *This, REFGUID g, UINT *n, void *d) {
    return mad_pd_get(This, g, n, d);   /* ml1143 */
}
static HRESULT STDMETHODCALLTYPE qheap_SetPrivateData(ID3D12QueryHeap *This, REFGUID g, UINT n, const void *d) {
    return mad_pd_set(This, g, n, d);   /* ml1143 */
}
static HRESULT STDMETHODCALLTYPE qheap_SetPrivateDataInterface(ID3D12QueryHeap *This, REFGUID g, const IUnknown *d) {
    return mad_pd_set_iface(This, g, d);   /* ml1143 */
}
static HRESULT STDMETHODCALLTYPE qheap_SetName(ID3D12QueryHeap *This, LPCWSTR name) { (void)This; (void)name; return S_OK; }
static HRESULT STDMETHODCALLTYPE qheap_GetDevice(ID3D12QueryHeap *This, REFIID riid, void **out) {
    struct mad_queryheap *q = (struct mad_queryheap *)This;
    return q->device->vtbl->QueryInterface((ID3D12Device10 *)q->device, riid, out);
}

static HRESULT STDMETHODCALLTYPE device_CreateQueryHeap(ID3D12Device *This,
        const D3D12_QUERY_HEAP_DESC *desc, REFIID riid, void **out) {
    struct mad_queryheap *q;
    HRESULT hr;
    if (!out) return E_INVALIDARG;
    *out = NULL;
    if (!desc) return E_INVALIDARG;
    q = calloc(1, sizeof *q);
    if (!q) return E_OUTOFMEMORY;
    q->vtbl = &g_qheap_vtbl; q->refs = 1; q->iid = &IID_ID3D12QueryHeap; q->name = "QueryHeap";
    q->device = (struct mad_device *)This;
    q->desc = *desc;
    q->results = calloc(desc->Count ? desc->Count : 1, sizeof *q->results);   /* ml1088 */
    if (!q->results) { free(q); return E_OUTOFMEMORY; }
    InitializeCriticalSection(&q->lock);
    InterlockedExchange(&q->device->has_query_heaps, 1);
    d3d12_log("[madeira-d3d12] query heap: type %u, %u queries (%s)\n",
              (unsigned)desc->Type, desc->Count,
              (desc->Type == D3D12_QUERY_HEAP_TYPE_OCCLUSION) ? "ml1088: counted on the GPU" : "results resolve to zero");
    hr = qheap_QI((ID3D12QueryHeap *)q, riid, out);
    qheap_Release((ID3D12QueryHeap *)q);
    return hr;
}

static int mad_query_is_occlusion(D3D12_QUERY_TYPE t) { return t == D3D12_QUERY_TYPE_OCCLUSION || t == D3D12_QUERY_TYPE_BINARY_OCCLUSION; }
static void STDMETHODCALLTYPE list_BeginQuery(ID3D12GraphicsCommandList *This, ID3D12QueryHeap *heap,
        D3D12_QUERY_TYPE type, UINT index) {
    struct mad_cmd *c;
    if (!heap || !mad_query_is_occlusion(type)) return;   /* ml1088: only occlusion is counted; the rest resolve to zero */
    if ((c = mad_list_push((struct mad_list *)This, MC_QUERY_BEGIN))) { c->u.query.heap = (struct mad_queryheap *)heap; c->u.query.type = type; c->u.query.index = index; }
}
static void STDMETHODCALLTYPE list_EndQuery(ID3D12GraphicsCommandList *This, ID3D12QueryHeap *heap,
        D3D12_QUERY_TYPE type, UINT index) {
    struct mad_cmd *c;
    if (!heap || !mad_query_is_occlusion(type)) return;
    if ((c = mad_list_push((struct mad_list *)This, MC_QUERY_END))) { c->u.query.heap = (struct mad_queryheap *)heap; c->u.query.type = type; c->u.query.index = index; }
}
static void STDMETHODCALLTYPE list_ResolveQueryData(ID3D12GraphicsCommandList *This, ID3D12QueryHeap *heap,
        D3D12_QUERY_TYPE type, UINT start, UINT count, ID3D12Resource *dst, UINT64 offset) {
    struct mad_resource *r = (struct mad_resource *)dst;
    static int said;
    UINT64 each = (type == D3D12_QUERY_TYPE_PIPELINE_STATISTICS) ? sizeof(D3D12_QUERY_DATA_PIPELINE_STATISTICS) : 8;
    if (!r || !heap) return;
    if (mad_query_is_occlusion(type)) {   /* ml1088: delivered when the batch completes */
        struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_QUERY_RESOLVE);
        if (c) { c->u.query.heap = (struct mad_queryheap *)heap; c->u.query.type = type; c->u.query.index = start; c->u.query.count = count; c->u.query.dst = r; c->u.query.off = offset; }
        return;
    }
    if (!said++) d3d12_log("[madeira-d3d12] ResolveQueryData: non-occlusion queries resolve to zero (not measured yet)\n");
    /* Written immediately rather than at execution: a constant is the same
     * value whenever it lands, and the destination is a readback buffer the
     * CPU owns. */
    if (r->cpu && offset + (UINT64)count * each <= r->size)
        memset((char *)r->cpu + offset, 0, (size_t)(count * each));
}

/* ml1088: the batch-side machinery. */
static struct mad_vis_batch *mad_vis_get(struct mad_exec *e) {
    struct mad_queue *q = e->q;
    if (!q->vis) q->vis = calloc(1, sizeof *q->vis);
    return q->vis;
}
/* The chunk holding global slot `slot`, allocated (and zeroed) on first use. */
static obj_handle_t mad_vis_chunk(struct mad_exec *e, struct mad_vis_batch *v, UINT64 slot, void **cpu_out) {
    unsigned idx = (unsigned)(slot / MAD_VIS_SLOTS);
    while (idx >= v->nchunks) {
        struct mad_ringchunk c;
        if (!mad_grow((void **)&v->chunks, &v->ccap, v->nchunks + 1, sizeof *v->chunks)) return 0;
        if (!mad_ring_chunk_get(e->q->device, &c)) return 0;
        memset(c.cpu, 0, MAD_ARG_RING_BYTES);   /* the GPU adds to what is there */
        v->chunks[v->nchunks++] = c;
    }
    if (cpu_out) *cpu_out = (unsigned char *)v->chunks[idx].cpu + (size_t)(slot % MAD_VIS_SLOTS) * 8;
    return v->chunks[idx].buf;
}
/* DXMT's getNextReadOffset: a Begin or End inside an encoder that has already
 * counted into the current slot starts a new one, so the sum boundaries fall
 * between draws, never through them. */
static UINT64 mad_vis_read_off(struct mad_exec *e, struct mad_vis_batch *v) {
    if (e->renc && v->dirty) { v->dirty = 0; return ++v->next; }
    return v->next;
}
static void exec_query_begin(struct mad_exec *e, const struct mad_cmd *c) {
    struct mad_vis_batch *v = mad_vis_get(e);
    struct mad_vis_query *rec;
    if (!v || !mad_grow((void **)&v->q, &v->qcap, v->nq + 1, sizeof *v->q)) return;
    rec = &v->q[v->nq++];
    rec->heap = c->u.query.heap; rec->index = c->u.query.index; rec->b = mad_vis_read_off(e, v); rec->e = ~(UINT64)0;
    rec->end_seq = ~(UINT64)0; rec->applied = 0;
    qheap_AddRef((ID3D12QueryHeap *)rec->heap);
    v->active++;
    InterlockedIncrement(&g_vis_begun);
}
static void exec_query_end(struct mad_exec *e, const struct mad_cmd *c) {
    struct mad_vis_batch *v = e->q->vis;
    unsigned k;
    if (!v) return;
    for (k = v->nq; k > 0; k--) {
        struct mad_vis_query *rec = &v->q[k - 1];
        if (rec->heap == c->u.query.heap && rec->index == c->u.query.index && rec->e == ~(UINT64)0) {
            rec->e = mad_vis_read_off(e, v);
            rec->end_seq = ++v->evseq;   /* ml1092 */
            if (v->active) v->active--;
            return;
        }
    }
}
static void exec_query_resolve(struct mad_exec *e, const struct mad_cmd *c) {
    struct mad_vis_batch *v = mad_vis_get(e);
    struct mad_vis_resolve *r;
    if (!v || !mad_grow((void **)&v->r, &v->rcap, v->nr + 1, sizeof *v->r)) return;
    r = &v->r[v->nr++];
    r->heap = c->u.query.heap; r->type = c->u.query.type; r->start = c->u.query.index; r->count = c->u.query.count;
    r->dst = c->u.query.dst; r->off = c->u.query.off;
    r->seq = ++v->evseq;   /* ml1092 */
    qheap_AddRef((ID3D12QueryHeap *)r->heap);
    ID3D12Resource_AddRef((ID3D12Resource *)r->dst);
}
/* At flush: the open batch's slots go to the device's completion queue. */
static void mad_vis_flush(struct mad_queue *q, obj_handle_t cb) {
    struct mad_device *d = q->device;
    struct mad_vis_batch *v = q->vis;
    if (!v) return;
    q->vis = NULL;
    if (v->dirty) { v->next++; v->dirty = 0; }
    v->cb = cb; NSObject_retain(cb);
    EnterCriticalSection(&d->vis_lock);
    if (mad_grow((void **)&d->vis_pending, &d->vis_pending_cap, d->nvis_pending + 1, sizeof *d->vis_pending))
        d->vis_pending[d->nvis_pending++] = v;
    else v = NULL;   /* leaked rather than freed under the GPU */
    LeaveCriticalSection(&d->vis_lock);
    (void)v;
}
static void mad_vis_complete(struct mad_device *d, struct mad_vis_batch *v) {
    unsigned k, j;
    static unsigned said_nocpu;
    MTLCommandBuffer_waitUntilCompleted(v->cb);
    /* ml1092: a query's value is PUBLISHED at its End, in program order with
     * the resolves, so "End Q7 (37) / Resolve / reuse Q7, End (0) / Resolve"
     * delivers 37 then 0 -- the old two-pass form delivered 0 twice (Astra's
     * counterexample, ph-rdr53 review). A record that never ended is applied
     * last, with whatever was counted up to the batch end. */
#define MAD_VIS_APPLY(rec_) do { \
        struct mad_vis_query *rq_ = (rec_); UINT64 sum_ = 0, s_, end_ = rq_->e == ~(UINT64)0 ? v->next : rq_->e; \
        for (s_ = rq_->b; s_ < end_; s_++) { unsigned ix_ = (unsigned)(s_ / MAD_VIS_SLOTS); \
            if (ix_ < v->nchunks) sum_ += ((const UINT64 *)v->chunks[ix_].cpu)[s_ % MAD_VIS_SLOTS]; } \
        if (rq_->index < rq_->heap->desc.Count) { EnterCriticalSection(&rq_->heap->lock); rq_->heap->results[rq_->index] = sum_; LeaveCriticalSection(&rq_->heap->lock); } \
        if (sum_) InterlockedIncrement(&g_vis_nonzero); rq_->applied = 1; } while (0)
    for (k = 0; k < v->nr; k++) {
        struct mad_vis_resolve *r = &v->r[k];
        for (j = 0; j < v->nq; j++)
            if (!v->q[j].applied && v->q[j].end_seq < r->seq) MAD_VIS_APPLY(&v->q[j]);
        if (r->dst->cpu && r->off + (UINT64)r->count * 8 <= r->dst->size && r->start + r->count <= r->heap->desc.Count) {
            UINT64 *out = (UINT64 *)((char *)r->dst->cpu + r->off);
            EnterCriticalSection(&r->heap->lock);
            for (j = 0; j < r->count; j++) {
                UINT64 val = r->heap->results[r->start + j];
                if (g_occlusion_visible > 0) val = (r->type == D3D12_QUERY_TYPE_BINARY_OCCLUSION) ? 1u : (1u << 20);   /* ml1103 */
                out[j] = (r->type == D3D12_QUERY_TYPE_BINARY_OCCLUSION) ? (val ? 1u : 0u) : val;
            }
            LeaveCriticalSection(&r->heap->lock);
            InterlockedExchangeAdd(&g_vis_resolved, (LONG)r->count);
        } else if (said_nocpu++ < 4)
            d3d12_log("[madeira-d3d12] ml1088 ResolveQueryData into a buffer the CPU cannot write (%s, %u queries from %u); not delivered\n",
                      r->dst->cpu ? "range" : "GPU-only", r->count, r->start);
        qheap_Release((ID3D12QueryHeap *)r->heap);
        ID3D12Resource_Release((ID3D12Resource *)r->dst);
    }
    for (k = 0; k < v->nq; k++) {   /* ml1092: ended after the last resolve, or never ended */
        if (!v->q[k].applied) MAD_VIS_APPLY(&v->q[k]);
        qheap_Release((ID3D12QueryHeap *)v->q[k].heap);
    }
#undef MAD_VIS_APPLY
    EnterCriticalSection(&d->ring_lock);
    for (k = 0; k < v->nchunks; k++) {
        if (mad_grow((void **)&d->ring_pool, &d->ring_pool_cap, d->nring_pool + 1, sizeof *d->ring_pool)) {
            v->chunks[k].serial = 0; d->ring_pool[d->nring_pool++] = v->chunks[k];
        } else NSObject_release(v->chunks[k].buf);
    }
    LeaveCriticalSection(&d->ring_lock);
    NSObject_release(v->cb);
    free(v->chunks); free(v->q); free(v->r); free(v);
}
/* At retire: every batch committed up to and including this one has completed
 * (one Metal queue, in order), so deliver all of them, in order. */
static void mad_vis_retire(struct mad_device *d, obj_handle_t cb) {
    struct mad_vis_batch *todo[64]; unsigned n = 0, k, upto = ~0u;
    EnterCriticalSection(&d->vis_pub_lock);   /* ml1092: one retirer at a time, so batches publish in commit order */
    EnterCriticalSection(&d->vis_lock);
    for (k = 0; k < d->nvis_pending; k++) if (d->vis_pending[k]->cb == cb) { upto = k; break; }
    if (upto != ~0u) {
        n = upto + 1 > 64 ? 64 : upto + 1;
        memcpy(todo, d->vis_pending, n * sizeof *todo);
        memmove(d->vis_pending, d->vis_pending + n, (d->nvis_pending - n) * sizeof *todo);
        d->nvis_pending -= n;
    }
    LeaveCriticalSection(&d->vis_lock);
    for (k = 0; k < n; k++) mad_vis_complete(d, todo[k]);
    LeaveCriticalSection(&d->vis_pub_lock);
}

/* ---- queue queries --------------------------------------------------------- */
static HRESULT STDMETHODCALLTYPE queue_GetTimestampFrequency(ID3D12CommandQueue *This, UINT64 *freq) {
    (void)This;
    if (!freq) return E_INVALIDARG;
    *freq = 1000000000ull;   /* nanosecond ticks; the zero timestamps above are in the same unit */
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE queue_GetClockCalibration(ID3D12CommandQueue *This, UINT64 *gpu, UINT64 *cpu) {
    LARGE_INTEGER now;
    (void)This;
    QueryPerformanceCounter(&now);
    if (gpu) *gpu = 0;
    if (cpu) *cpu = (UINT64)now.QuadPart;
    return S_OK;
}
static D3D12_COMMAND_QUEUE_DESC * STDMETHODCALLTYPE queue_GetDesc(ID3D12CommandQueue *This, D3D12_COMMAND_QUEUE_DESC *ret) {
    (void)This;
    memset(ret, 0, sizeof *ret);
    ret->Type = ((struct mad_queue *)This)->type;
    return ret;
}

/* ---- resource ------------------------------------------------------------ */
static ID3D12Resource2Vtbl g_res_vtbl;

/* ml1132: every change to the address index is bracketed by these (live_lock
 * held, so writers are already serialised). The count is odd while the index
 * is being changed; mad_resolve_address reads the index without the lock and
 * discards what it read if the count moved. The fence after the first
 * increment orders it before the index stores; the release on the second
 * orders the index stores before it. */
static void mad_aidx_begin(struct mad_device *d) {
    __atomic_fetch_add(&d->aidx_ver, 1, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
}
static void mad_aidx_end(struct mad_device *d) { __atomic_fetch_add(&d->aidx_ver, 1, __ATOMIC_RELEASE); }
/* ml1132: grow the index WITHOUT freeing the old block: a lock-free reader may
 * still be searching it. Doubling bounds the retired blocks by the final size
 * (~2 MB at 64k entries). The new block is published before any count that
 * needs it (naidx is always stored with release after this). */
static int mad_aidx_grow(struct mad_device *d, unsigned need) {
    struct mad_addr_entry *n;
    unsigned ncap;
    if (need <= d->aidx_cap) return 1;
    ncap = d->aidx_cap ? d->aidx_cap * 2 : 64;
    while (ncap < need) ncap *= 2;
    n = malloc((size_t)ncap * sizeof *n);
    if (!n) return 0;
    if (d->naidx) memcpy(n, d->aidx, (size_t)d->naidx * sizeof *n);
    __atomic_store_n(&d->aidx, n, __ATOMIC_RELEASE);
    d->aidx_cap = ncap;
    return 1;
}

/* ml1113: keep the address index sorted incrementally (a buffer comes and goes
 * every frame; a full qsort per change was itself a hot spot: ml1111 profile
 * mad_resolve_address+0x164 = 12 % of native-callee samples). live_lock held. */
static void mad_addr_index_insert(struct mad_device *d, struct mad_resource *r) {
    unsigned lo = 0, hi = d->naidx;
    if (d->aidx_dirty) return;   /* a full rebuild is pending anyway */
    mad_aidx_begin(d);
    if (!mad_aidx_grow(d, d->naidx + 1)) { d->aidx_dirty = 1; mad_aidx_end(d); return; }
    while (lo < hi) { unsigned m = (lo + hi) / 2; if (d->aidx[m].lo <= r->gpu_address) lo = m + 1; else hi = m; }
    memmove(&d->aidx[lo + 1], &d->aidx[lo], (d->naidx - lo) * sizeof *d->aidx);
    d->aidx[lo].lo = r->gpu_address; d->aidx[lo].hi = r->gpu_address + r->size; d->aidx[lo].r = r; d->aidx[lo].seq = r->track_seq;   /* ml1157 */
    __atomic_store_n(&d->naidx, d->naidx + 1, __ATOMIC_RELEASE);
    if (r->size > d->aidx_maxsize) d->aidx_maxsize = r->size;
    mad_aidx_end(d);
}
static void mad_addr_index_remove(struct mad_device *d, struct mad_resource *r) {
    unsigned i;
    if (d->aidx_dirty) return;
    for (i = 0; i < d->naidx; i++) if (d->aidx[i].r == r) break;
    if (i == d->naidx) return;
    mad_aidx_begin(d);
    memmove(&d->aidx[i], &d->aidx[i + 1], (d->naidx - i - 1) * sizeof *d->aidx);
    __atomic_store_n(&d->naidx, d->naidx - 1, __ATOMIC_RELEASE);
    mad_aidx_end(d);
}
static void mad_track(struct mad_device *d, struct mad_resource *r) {
    if (!d || !r) return;
    EnterCriticalSection(&d->live_lock);
    r->track_seq = ++d->aidx_seq;   /* ml1157 */
    if (mad_grow((void **)&d->live, &d->live_cap, d->nlive + 1, sizeof *d->live)) { d->live[d->nlive++] = r; if (r->gpu_address && r->size) mad_addr_index_insert(d, r); }
    LeaveCriticalSection(&d->live_lock);
}
static void mad_untrack(struct mad_device *d, struct mad_resource *r) {
    if (!d || !r) return;
    EnterCriticalSection(&d->live_lock);
    for (unsigned i = 0; i < d->nlive; i++)
        if (d->live[i] == r) { d->live[i] = d->live[--d->nlive]; if (r->gpu_address) mad_addr_index_remove(d, r); break; }
    LeaveCriticalSection(&d->live_lock);
}
static int mad_addr_cmp(const void *a, const void *b) {
    const struct mad_addr_entry *x = a, *y = b;
    return x->lo < y->lo ? -1 : x->lo > y->lo ? 1 : (int)x->seq - (int)y->seq;
}
static void mad_addr_index_rebuild(struct mad_device *d) {   /* live_lock held */
    unsigned i, n = 0;
    mad_aidx_begin(d);   /* ml1132 */
    d->aidx_maxsize = 0;
    if (!mad_aidx_grow(d, d->nlive ? d->nlive : 1)) { __atomic_store_n(&d->naidx, 0, __ATOMIC_RELEASE); mad_aidx_end(d); return; }
    for (i = 0; i < d->nlive; i++) {
        struct mad_resource *r = d->live[i];
        if (!r->gpu_address || !r->size) continue;
        d->aidx[n].lo = r->gpu_address; d->aidx[n].hi = r->gpu_address + r->size; d->aidx[n].r = r; d->aidx[n].seq = r->track_seq; n++;   /* ml1157: creation order, not live-array slot */
        if (r->size > d->aidx_maxsize) d->aidx_maxsize = r->size;
    }
    qsort(d->aidx, n, sizeof *d->aidx, mad_addr_cmp);
    __atomic_store_n(&d->naidx, n, __ATOMIC_RELEASE);
    d->aidx_dirty = 0;
    mad_aidx_end(d);
}
static struct mad_resource *mad_resolve_address_locked(struct mad_device *d, UINT64 addr, UINT64 *off);
/* ml1132: LOCK-FREE LOOKUP. ph-rdr87 (ml1131b, 8 min of gameplay): 95-170k
 * critical-section entries a second were CONTENDED, and 100 % of the sampled
 * ones were this device's live_lock (device + 0x78). The game's recording
 * threads (IASetVertexBuffers, IASetIndexBuffer, root descriptors) and the
 * submission worker (descriptor-table and root replay) all resolve addresses
 * through it: 190-300 ms/s spent blocked, ~169k wake calls and ~32k thread
 * sleep/wake pairs a second. Readers never change the index, so they now
 * search it under aidx_ver instead of the lock. A reader that sees an odd or
 * moved count, a pending rebuild, an empty index or no match takes the
 * unchanged locked path, so every answer is one the locked search gives. */
#define MAD_LD(x) __atomic_load_n(&(x), __ATOMIC_RELAXED)
static struct mad_resource *mad_resolve_address(struct mad_device *d, UINT64 addr, UINT64 *off) {
    LONG64 v1;
    if (!d || !addr) return NULL;
    v1 = __atomic_load_n(&d->aidx_ver, __ATOMIC_ACQUIRE);
    if (!(v1 & 1) && !MAD_LD(d->aidx_dirty)) {
        /* naidx first (acquire): a count is only ever stored after the block
         * that holds it, and blocks never shrink, so n fits whatever aidx is. */
        unsigned n = __atomic_load_n(&d->naidx, __ATOMIC_ACQUIRE);
        struct mad_addr_entry *ax = __atomic_load_n(&d->aidx, __ATOMIC_ACQUIRE);
        UINT64 maxsz = MAD_LD(d->aidx_maxsize);
        struct mad_resource *found = NULL;
        if (n && ax) {
            unsigned lo = 0, hi = n, best_seq = 0; int i;
            while (lo < hi) { unsigned m = (lo + hi) / 2; if (MAD_LD(ax[m].lo) <= addr) lo = m + 1; else hi = m; }
            /* ml1157: of placed resources aliasing this address, the NEWEST. The
             * oldest (the old rule) is the one the application is about to free:
             * a command recorded against it held a dead resource by the time it
             * ran (ph-valley16: a UAV clear's blit fill on a freed buffer, then
             * objc_release of it when the command buffer completed). */
            for (i = (int)lo - 1; i >= 0 && MAD_LD(ax[i].lo) + maxsz > addr; i--)
                if (addr < MAD_LD(ax[i].hi) && (!found || MAD_LD(ax[i].seq) > best_seq)) { best_seq = MAD_LD(ax[i].seq); found = MAD_LD(ax[i].r); }
        }
        __atomic_thread_fence(__ATOMIC_ACQUIRE);   /* the reads above complete before the re-check */
        if (found && MAD_LD(d->aidx_ver) == v1) {
            if (off) *off = addr - found->gpu_address;
            return found;
        }
    }
    return mad_resolve_address_locked(d, addr, off);
}
static struct mad_resource *mad_resolve_address_locked(struct mad_device *d, UINT64 addr, UINT64 *off) {
    struct mad_resource *found = NULL;
    InterlockedIncrement(&g_resolve_locked);
    EnterCriticalSection(&d->live_lock);
    if (d->aidx_dirty || (!d->naidx && d->nlive)) mad_addr_index_rebuild(d);
    if (d->naidx) {
        /* last entry with lo <= addr, then back over entries that could still
         * contain addr (placed resources may alias); keep the live-order first
         * match, as the linear walk did. */
        unsigned lo = 0, hi = d->naidx, best_seq = 0; int i;
        while (lo < hi) { unsigned m = (lo + hi) / 2; if (d->aidx[m].lo <= addr) lo = m + 1; else hi = m; }
        for (i = (int)lo - 1; i >= 0 && d->aidx[i].lo + d->aidx_maxsize > addr; i--)   /* ml1157: newest alias */
            if (addr < d->aidx[i].hi && (!found || d->aidx[i].seq > best_seq)) { best_seq = d->aidx[i].seq; found = d->aidx[i].r; }
    }
    if (!found) {   /* miss: the slow path keeps the old semantics exactly and re-syncs the index */
        for (unsigned i = 0; i < d->nlive; i++) {
            struct mad_resource *r = d->live[i];
            if (r->gpu_address && addr >= r->gpu_address && addr < r->gpu_address + r->size && (!found || r->track_seq > found->track_seq)) { found = r; __atomic_store_n(&d->aidx_dirty, 1, __ATOMIC_RELAXED); }   /* ml1157: newest alias */
        }
        if (!found) InterlockedIncrement(&g_resolve_miss);   /* ml1132: a true miss always takes this lock */
    }
    if (found && off) *off = addr - found->gpu_address;
    LeaveCriticalSection(&d->live_lock);
    return found;
}

static HRESULT STDMETHODCALLTYPE res_QI(ID3D12Resource *This, REFIID riid, void **out) {
    /* ml886: ID3D12Resource1/2 are the same object with more slots. */
    if (out && riid && (IsEqualGUID(riid, &IID_ID3D12Resource1) || IsEqualGUID(riid, &IID_ID3D12Resource2))) {
        InterlockedIncrement(&((struct mad_obj *)This)->refs);
        *out = This;
        return S_OK;
    }
    return mad_qi((struct mad_obj *)This, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE res_AddRef(ID3D12Resource *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE res_Release(ID3D12Resource *This) {
    struct mad_resource *r = (struct mad_resource *)This;
    LONG n = InterlockedDecrement(&r->refs);
    if (n == 0) { mad_pd_purge(This);   /* ml1143 */
        /* The backend owns the storage, so releasing the buffer is the whole
         * teardown; there is no separate free to order against it. */
        mad_untrack(r->owner, r);
        if (r->owner) {   /* ml920: srv_res / uav_res kept freed resources; the residency
                           * loops read r->texture from them, and a longer walk
                           * (ml918 capture) faulted on a partially unmapped one. */
            struct mad_device *dd = r->owner;
            if (r->srv_slot || r->uav_slot) {
                AcquireSRWLockExclusive(&dd->list_lock);
                if (r->srv_slot) mad_view_list_del(dd, 0, r);
                if (r->uav_slot) mad_view_list_del(dd, 1, r);
                ReleaseSRWLockExclusive(&dd->list_lock);
            }
        }
        if (r->owner) {   /* ml1049: forget the ids before the views die */
            struct mad_device *vd = (struct mad_device *)r->owner; unsigned k;
            EnterCriticalSection(&vd->view_lock);
            for (k = 0; k < r->ntview; k++) mad_vmap_del_locked(vd, r->tview[k].id);
            for (k = 0; k < r->nxview; k++) mad_vmap_del_locked(vd, r->xview[k].id);
            if (r->texture && !r->borrowed) mad_vmap_del_locked(vd, r->gpu_resource_id);   /* ml1053 */
            LeaveCriticalSection(&vd->view_lock);
        }
        { unsigned k; for (k = 0; k < r->ntview; k++) if (r->tview[k].tex) { NSObject_release(r->tview[k].tex); InterlockedDecrement(&g_tview_live); } }   /* ml905; ml1126: never set members */
        { unsigned k; for (k = 0; k < r->nxview; k++) if (r->xview[k].tex) { mad_unresident(r->owner, r->xview[k].tex); NSObject_release(r->xview[k].tex); InterlockedDecrement(&g_xview_live); } }   /* ml913 */
        if (r->acct_bytes) mad_acct(r, r->acct_cat, r->acct_bytes, -1);   /* ml1057 */
        if (r->buffer && !r->placed_heap) mad_unresident(r->owner, r->buffer);
        if (r->texture && !r->borrowed && !r->hp_used && !r->placed_heap) mad_unresident(r->owner, r->texture);
        if (r->hp_used && r->owner) mad_hp_release(r->owner, r);   /* ml1072: block returns after the GPU is done with it */
        { unsigned k; for (k = 0; k < r->nview_old; k++) free(r->view_old[k]); free(r->tview); free(r->xview); }
        if (r->buffer) NSObject_release(r->buffer);
        if (r->texture && !r->borrowed) NSObject_release(r->texture);
        if (r->resolve_tmp) NSObject_release(r->resolve_tmp);
        if (r->placed_heap) ID3D12Heap_Release((ID3D12Heap *)r->placed_heap);   /* ml1145 */
        if (r->own_mem) {   /* ml1154: the GPU may still read it; free after its serial (reclaimed with the ml1148 list) */
            struct mad_device *md = r->owner; int queued = 0;
            InterlockedExchangeAdd64(&g_upload_swap_bytes, -(LONG64)((r->size + 0xffff) & ~(UINT64)0xffff)); InterlockedDecrement(&g_upload_swap_n);
            if (md) {
                EnterCriticalSection(&md->heap_lock);
                if (mad_grow((void **)&md->mhret, &md->mhret_cap, md->nmhret + 1, sizeof *md->mhret)) {
                    md->mhret[md->nmhret].heap = 0; md->mhret[md->nmhret].mem = r->own_mem;
                    md->mhret[md->nmhret].serial = (UINT64)md->gpu_serial; md->nmhret++; queued = 1;
                }
                LeaveCriticalSection(&md->heap_lock);
            }
            if (!queued) { static unsigned said; if (said++ < 4) d3d12_log("[madeira-d3d12] ml1154 could not queue a buffer's storage for release; leaked %p\n", r->own_mem); }
        }
        free(r);
    }
    return (ULONG)n;
}
static HRESULT STDMETHODCALLTYPE res_Map(ID3D12Resource *This, UINT sub,
                                         const D3D12_RANGE *read_range, void **data) {
    struct mad_resource *r = (struct mad_resource *)This;
    (void)read_range;
    /* ml1038: say WHAT was refused. The old message claimed "DEFAULT-heap" for
     * anything without a CPU pointer -- which includes every texture, whatever
     * heap it lives in -- and the sub != 0 refusal was completely silent. Both
     * hid the fact that an application was mapping TEXTURES. Applications
     * routinely ignore this HRESULT and write through the pointer, so null it:
     * a stale stack value is a wild write, NULL is at least an honest fault. */
    if (sub != 0 || !r->cpu) {
        static LONG said;
        if (InterlockedIncrement(&said) <= 24)
            d3d12_log("[madeira-d3d12] ml1038 Map REFUSED: %s sub=%u (%s, %ux%u) -- this runtime has no "
                      "CPU-visible storage for it\n",
                      r->texture ? "TEXTURE" : "buffer", sub, r->name ? r->name : "?",
                      (unsigned)r->width, (unsigned)r->height);
        if (data) *data = NULL;
        return E_INVALIDARG;
    }
    InterlockedIncrement(&r->mapped);
    if (data) *data = r->cpu;
    return S_OK;
}
static void STDMETHODCALLTYPE res_Unmap(ID3D12Resource *This, UINT sub, const D3D12_RANGE *written) {
    struct mad_resource *r = (struct mad_resource *)This;
    (void)sub; (void)written;
    if (r->mapped) InterlockedDecrement(&r->mapped);
}
static D3D12_GPU_VIRTUAL_ADDRESS STDMETHODCALLTYPE res_GetGPUVirtualAddress(ID3D12Resource *This) {
    struct mad_resource *r = (struct mad_resource *)This;
    /* Deliberately the backend's own address. The design warns against putting
     * synthetic guest addresses where the GPU will dereference them. */
    return (D3D12_GPU_VIRTUAL_ADDRESS)r->gpu_address;
}

/* ---- texture formats -------------------------------------------------------
 * DXGI to Metal. Typeless formats take the natural interpretation, and the
 * depth-capable typeless ones become depth when the resource allows a depth
 * stencil view. Metal has no 24-bit depth on Apple GPUs, so D24S8 widens to
 * D32S8, which changes the stored precision and nothing the application can
 * observe through the API. Unknown formats are named once and refused. */
static int mad_map_texture_format(DXGI_FORMAT f, D3D12_RESOURCE_FLAGS flags,
                                  enum WMTPixelFormat *out, int *is_depth) {
    int ds = (flags & D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL) != 0;
    *is_depth = 0;
    switch (f) {
    case DXGI_FORMAT_R8G8B8A8_TYPELESS: case DXGI_FORMAT_R8G8B8A8_UNORM: *out = WMTPixelFormatRGBA8Unorm; return 1;
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: *out = WMTPixelFormatRGBA8Unorm_sRGB; return 1;
    case DXGI_FORMAT_R8G8B8A8_SNORM: *out = WMTPixelFormatRGBA8Snorm; return 1;
    case DXGI_FORMAT_R8G8B8A8_UINT: *out = WMTPixelFormatRGBA8Uint; return 1;
    case DXGI_FORMAT_R8G8B8A8_SINT: *out = WMTPixelFormatRGBA8Sint; return 1;
    case DXGI_FORMAT_B8G8R8A8_TYPELESS: case DXGI_FORMAT_B8G8R8A8_UNORM:
    case DXGI_FORMAT_B8G8R8X8_TYPELESS: case DXGI_FORMAT_B8G8R8X8_UNORM: *out = WMTPixelFormatBGRA8Unorm; return 1;
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB: *out = WMTPixelFormatBGRA8Unorm_sRGB; return 1;
    case DXGI_FORMAT_R16G16B16A16_TYPELESS: case DXGI_FORMAT_R16G16B16A16_FLOAT: *out = WMTPixelFormatRGBA16Float; return 1;
    case DXGI_FORMAT_R16G16B16A16_UNORM: *out = WMTPixelFormatRGBA16Unorm; return 1;
    case DXGI_FORMAT_R16G16B16A16_SNORM: *out = WMTPixelFormatRGBA16Snorm; return 1;
    case DXGI_FORMAT_R16G16B16A16_UINT: *out = WMTPixelFormatRGBA16Uint; return 1;
    case DXGI_FORMAT_R16G16B16A16_SINT: *out = WMTPixelFormatRGBA16Sint; return 1;
    case DXGI_FORMAT_R32G32B32A32_TYPELESS: case DXGI_FORMAT_R32G32B32A32_FLOAT: *out = WMTPixelFormatRGBA32Float; return 1;
    case DXGI_FORMAT_R32G32B32A32_UINT: *out = WMTPixelFormatRGBA32Uint; return 1;
    case DXGI_FORMAT_R32G32B32A32_SINT: *out = WMTPixelFormatRGBA32Sint; return 1;
    case DXGI_FORMAT_R32G32_TYPELESS: case DXGI_FORMAT_R32G32_FLOAT: *out = WMTPixelFormatRG32Float; return 1;
    case DXGI_FORMAT_R32G32_UINT: *out = WMTPixelFormatRG32Uint; return 1;
    case DXGI_FORMAT_R32G32_SINT: *out = WMTPixelFormatRG32Sint; return 1;
    case DXGI_FORMAT_R16G16_TYPELESS: case DXGI_FORMAT_R16G16_FLOAT: *out = WMTPixelFormatRG16Float; return 1;
    case DXGI_FORMAT_R16G16_UNORM: *out = WMTPixelFormatRG16Unorm; return 1;
    case DXGI_FORMAT_R16G16_SNORM: *out = WMTPixelFormatRG16Snorm; return 1;
    case DXGI_FORMAT_R16G16_UINT: *out = WMTPixelFormatRG16Uint; return 1;
    case DXGI_FORMAT_R16G16_SINT: *out = WMTPixelFormatRG16Sint; return 1;
    case DXGI_FORMAT_R32_TYPELESS: if (ds) { *out = WMTPixelFormatDepth32Float; *is_depth = 1; } else *out = WMTPixelFormatR32Float; return 1;
    case DXGI_FORMAT_D32_FLOAT: *out = WMTPixelFormatDepth32Float; *is_depth = 1; return 1;
    case DXGI_FORMAT_R32_FLOAT: *out = WMTPixelFormatR32Float; return 1;
    case DXGI_FORMAT_R32_UINT: *out = WMTPixelFormatR32Uint; return 1;
    case DXGI_FORMAT_R32_SINT: *out = WMTPixelFormatR32Sint; return 1;
    case DXGI_FORMAT_R24G8_TYPELESS: case DXGI_FORMAT_D24_UNORM_S8_UINT:
    case DXGI_FORMAT_R24_UNORM_X8_TYPELESS: case DXGI_FORMAT_X24_TYPELESS_G8_UINT:
    case DXGI_FORMAT_R32G8X24_TYPELESS: case DXGI_FORMAT_D32_FLOAT_S8X24_UINT:
    case DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS: case DXGI_FORMAT_X32_TYPELESS_G8X24_UINT:
        *out = WMTPixelFormatDepth32Float_Stencil8; *is_depth = 1; return 1;
    case DXGI_FORMAT_R16_TYPELESS: if (ds) { *out = WMTPixelFormatDepth16Unorm; *is_depth = 1; } else *out = WMTPixelFormatR16Unorm; return 1;
    case DXGI_FORMAT_D16_UNORM: *out = WMTPixelFormatDepth16Unorm; *is_depth = 1; return 1;
    case DXGI_FORMAT_R16_FLOAT: *out = WMTPixelFormatR16Float; return 1;
    case DXGI_FORMAT_R16_UNORM: *out = WMTPixelFormatR16Unorm; return 1;
    case DXGI_FORMAT_R16_SNORM: *out = WMTPixelFormatR16Snorm; return 1;
    case DXGI_FORMAT_R16_UINT: *out = WMTPixelFormatR16Uint; return 1;
    case DXGI_FORMAT_R16_SINT: *out = WMTPixelFormatR16Sint; return 1;
    case DXGI_FORMAT_R8_TYPELESS: case DXGI_FORMAT_R8_UNORM: *out = WMTPixelFormatR8Unorm; return 1;
    case DXGI_FORMAT_R8_SNORM: *out = WMTPixelFormatR8Snorm; return 1;
    case DXGI_FORMAT_R8_UINT: *out = WMTPixelFormatR8Uint; return 1;
    case DXGI_FORMAT_R8_SINT: *out = WMTPixelFormatR8Sint; return 1;
    case DXGI_FORMAT_A8_UNORM: *out = WMTPixelFormatA8Unorm; return 1;
    case DXGI_FORMAT_R8G8_TYPELESS: case DXGI_FORMAT_R8G8_UNORM: *out = WMTPixelFormatRG8Unorm; return 1;
    case DXGI_FORMAT_R8G8_SNORM: *out = WMTPixelFormatRG8Snorm; return 1;
    case DXGI_FORMAT_R8G8_UINT: *out = WMTPixelFormatRG8Uint; return 1;
    case DXGI_FORMAT_R8G8_SINT: *out = WMTPixelFormatRG8Sint; return 1;
    case DXGI_FORMAT_R10G10B10A2_TYPELESS: case DXGI_FORMAT_R10G10B10A2_UNORM: *out = WMTPixelFormatRGB10A2Unorm; return 1;
    case DXGI_FORMAT_R10G10B10A2_UINT: *out = WMTPixelFormatRGB10A2Uint; return 1;
    case DXGI_FORMAT_R11G11B10_FLOAT: *out = WMTPixelFormatRG11B10Float; return 1;
    case DXGI_FORMAT_R9G9B9E5_SHAREDEXP: *out = WMTPixelFormatRGB9E5Float; return 1;
    case DXGI_FORMAT_B5G6R5_UNORM: *out = WMTPixelFormatB5G6R5Unorm; return 1;
    case DXGI_FORMAT_B5G5R5A1_UNORM: *out = WMTPixelFormatBGR5A1Unorm; return 1;
    case DXGI_FORMAT_BC1_TYPELESS: case DXGI_FORMAT_BC1_UNORM: *out = WMTPixelFormatBC1_RGBA; return 1;
    case DXGI_FORMAT_BC1_UNORM_SRGB: *out = WMTPixelFormatBC1_RGBA_sRGB; return 1;
    case DXGI_FORMAT_BC2_TYPELESS: case DXGI_FORMAT_BC2_UNORM: *out = WMTPixelFormatBC2_RGBA; return 1;
    case DXGI_FORMAT_BC2_UNORM_SRGB: *out = WMTPixelFormatBC2_RGBA_sRGB; return 1;
    case DXGI_FORMAT_BC3_TYPELESS: case DXGI_FORMAT_BC3_UNORM: *out = WMTPixelFormatBC3_RGBA; return 1;
    case DXGI_FORMAT_BC3_UNORM_SRGB: *out = WMTPixelFormatBC3_RGBA_sRGB; return 1;
    case DXGI_FORMAT_BC4_TYPELESS: case DXGI_FORMAT_BC4_UNORM: *out = WMTPixelFormatBC4_RUnorm; return 1;
    case DXGI_FORMAT_BC4_SNORM: *out = WMTPixelFormatBC4_RSnorm; return 1;
    case DXGI_FORMAT_BC5_TYPELESS: case DXGI_FORMAT_BC5_UNORM: *out = WMTPixelFormatBC5_RGUnorm; return 1;
    case DXGI_FORMAT_BC5_SNORM: *out = WMTPixelFormatBC5_RGSnorm; return 1;
    case DXGI_FORMAT_BC6H_TYPELESS: case DXGI_FORMAT_BC6H_UF16: *out = WMTPixelFormatBC6H_RGBUfloat; return 1;
    case DXGI_FORMAT_BC6H_SF16: *out = WMTPixelFormatBC6H_RGBFloat; return 1;
    case DXGI_FORMAT_BC7_TYPELESS: case DXGI_FORMAT_BC7_UNORM: *out = WMTPixelFormatBC7_RGBAUnorm; return 1;
    case DXGI_FORMAT_BC7_UNORM_SRGB: *out = WMTPixelFormatBC7_RGBAUnorm_sRGB; return 1;
    default: {
        static DXGI_FORMAT seen[16]; static unsigned n; unsigned i;
        for (i = 0; i < n; i++) if (seen[i] == f) return 0;
        if (n < 16) seen[n++] = f;
        d3d12_log("[madeira-d3d12] texture format %u has no Metal mapping\n", (unsigned)f);
        return 0;
    }
    }
}

/* Bytes in one row of the top mip, from the resource's own format. */
static UINT64 mad_res_row_bytes(const struct mad_resource *r) {
    UINT bytes, block;
    mad_format_info(r->desc.Format, &bytes, &block);
    return ((UINT64)(r->width + block - 1) / block) * bytes;
}

/* ---- resource creation core ---------------------------------------------
 * Shared by committed and placed resources. A placed resource here is an
 * allocation of its own: the backend exposes no heaps, so the heap offset only
 * says where the application THINKS the memory is. Without aliasing every
 * placed resource keeps its own storage, which costs memory but never
 * corrupts data. */
/* ml886: a refused creation returns an error the engine may not check --
 * UE 5.4 dereferenced the null RHI resource it got back. Name every refusal. */
static void mad_refuse_log(const D3D12_RESOURCE_DESC *desc, D3D12_HEAP_TYPE heap_type, const char *why) {
    static unsigned said;
    if (said++ < 32)
        d3d12_log("[madeira-d3d12] resource creation REFUSED (%s): dim %u fmt %u %llux%ux%u mips %u samples %u flags 0x%x heap-type %u\n",
                  why, (unsigned)desc->Dimension, (unsigned)desc->Format, (unsigned long long)desc->Width, desc->Height,
                  desc->DepthOrArraySize, desc->MipLevels, desc->SampleDesc.Count, (unsigned)desc->Flags, (unsigned)heap_type);
}
/* ml1145: PLACED RESOURCES ALIAS. The heap used to be a description only and
 * every placed resource got its own allocation. UE 5's transient allocator
 * places many short-lived resources at overlapping offsets of a few 128 MB
 * heaps and caches the placements for a while: in D3D12 they share the heap;
 * here each was new memory, ~118 MB a frame, and a UE 5.0 title was killed at
 * the 8 GB line on its first rendered frames (ph-valley02). DEFAULT heaps are
 * now real Metal placement heaps. CUSTOM heaps (a DXBC title's hundreds of
 * small CPU-page texture heaps, ~1.7 GB of mostly empty space) stay
 * description-only. madeira.cfg heap-backing = 0 restores the old behaviour. */
struct mad_memheap {
    ID3D12HeapVtbl *vtbl; LONG refs; const IID *iid; const char *name;
    struct mad_device *device;
    D3D12_HEAP_DESC desc;
    obj_handle_t mtl;   /* ml1145: the Metal placement heap, or 0 */
};
static LONG g_placed_in_heap, g_placed_fallback;
static void mad_placed_fallback(const struct mad_memheap *h, const D3D12_RESOURCE_DESC *desc, UINT64 off, UINT64 msz, UINT64 mal) {
    LONG n = InterlockedIncrement(&g_placed_fallback);
    if (n <= 16)
        d3d12_log("[madeira-d3d12] ml1145 placed %s %llux%u at +%llu could not go into its %llu KB heap (Metal needs %llu bytes, align %llu); standalone\n",
                  desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER ? "buffer" : "texture", (unsigned long long)desc->Width, desc->Height,
                  (unsigned long long)off, (unsigned long long)(h->desc.SizeInBytes >> 10), (unsigned long long)msz, (unsigned long long)mal);
}
/* ml1145: the Metal texture description a D3D12 resource gets. ONE builder for
 * creation and for GetResourceAllocationInfo, so the size the application
 * plans its heap with is the size the placement really takes. */
static int mad_texinfo_from_desc(const D3D12_RESOURCE_DESC *desc, struct WMTTextureInfo *ti, enum WMTPixelFormat *pf, int *is_depth) {
    UINT layers = desc->DepthOrArraySize ? desc->DepthOrArraySize : 1;
    if (!mad_map_texture_format(desc->Format, desc->Flags, pf, is_depth)) return 0;
    memset(ti, 0, sizeof *ti);
    ti->pixel_format = *pf;
    ti->width = (uint32_t)desc->Width;
    ti->height = desc->Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE1D ? 1 : desc->Height;
    ti->depth = 1;
    ti->array_length = 1;
    ti->mipmap_level_count = desc->MipLevels ? desc->MipLevels : 1;
    /* ml1030: same clamp as the PSO, or a 4x pipeline meets an 8x target. */
    ti->sample_count = mad_clamp_sample_count(desc->SampleDesc.Count ? desc->SampleDesc.Count : 1);
    /* ml932: every 1D/2D texture is allocated as an ARRAY (length >= 1),
     * matching shaders converted with IRCompatibilityFlagForceTextureArray
     * (the converter manual's "Texture arrays" table). 3D is unchanged. */
    switch (desc->Dimension) {
    case D3D12_RESOURCE_DIMENSION_TEXTURE1D:
        ti->type = WMTTextureType2DArray; ti->height = 1; ti->array_length = layers; break;
    case D3D12_RESOURCE_DIMENSION_TEXTURE3D:
        ti->type = WMTTextureType3D; ti->depth = layers; break;
    default:
        ti->type = ti->sample_count > 1 ? WMTTextureType2DMultisampleArray : WMTTextureType2DArray;
        ti->array_length = layers;
        break;
    }
    ti->usage = WMTTextureUsageShaderRead;
    if (desc->Flags & (D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET | D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL))
        ti->usage = (enum WMTTextureUsage)(ti->usage | WMTTextureUsageRenderTarget);
    if (desc->Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS) {
        ti->usage = (enum WMTTextureUsage)(ti->usage | WMTTextureUsageShaderWrite);
        /* ml1149: texture atomics (InterlockedMax on R32 UAVs, 64-bit max on
         * RG32Uint visibility buffers) are defined only with ShaderAtomic usage,
         * which Metal allows on exactly these three formats (with PixelFormatView). */
        if (ti->pixel_format == WMTPixelFormatR32Uint || ti->pixel_format == WMTPixelFormatR32Sint ||
            ti->pixel_format == WMTPixelFormatRG32Uint)
            ti->usage = (enum WMTTextureUsage)(ti->usage | WMTTextureUsageShaderAtomic);
    }
    /* Views may reinterpret typeless and sRGB/linear pairs. */
    ti->usage = (enum WMTTextureUsage)(ti->usage | WMTTextureUsagePixelFormatView);
    ti->options = WMTResourceStorageModePrivate;
    return 1;
}
static HRESULT mad_create_resource_at(struct mad_device *d, D3D12_HEAP_TYPE heap_type,
                                      const D3D12_RESOURCE_DESC *desc, REFIID riid, void **out,
                                      struct mad_memheap *ph, UINT64 poff);
static HRESULT mad_create_resource(struct mad_device *d, D3D12_HEAP_TYPE heap_type,
                                   const D3D12_RESOURCE_DESC *desc, REFIID riid, void **out) {
    return mad_create_resource_at(d, heap_type, desc, riid, out, NULL, 0);
}
static HRESULT mad_create_resource_at(struct mad_device *d, D3D12_HEAP_TYPE heap_type,
                                      const D3D12_RESOURCE_DESC *desc, REFIID riid, void **out,
                                      struct mad_memheap *ph, UINT64 poff) {
    struct mad_resource *r;
    HRESULT hr;
    if (desc->Dimension == D3D12_RESOURCE_DIMENSION_UNKNOWN) { mad_refuse_log(desc, heap_type, "dimension UNKNOWN"); return E_INVALIDARG; }

    r = calloc(1, sizeof *r);
    if (!r) return E_OUTOFMEMORY;
    r->vtbl = &g_res_vtbl; r->refs = 1; r->iid = &IID_ID3D12Resource; r->name = "Resource";
    r->size = desc->Width;
    r->heap = heap_type;
    r->desc = *desc;
    r->owner = d;

    if (desc->Dimension != D3D12_RESOURCE_DIMENSION_BUFFER) {
        struct WMTTextureInfo ti;
        enum WMTPixelFormat pf;
        int is_depth;
        if (!mad_texinfo_from_desc(desc, &ti, &pf, &is_depth)) { free(r); mad_refuse_log(desc, heap_type, "texture format has no Metal mapping"); return E_NOTIMPL; }
        if (ph && ph->mtl) {   /* ml1145: inside the application's heap, at its offset */
            UINT64 psz = 0, pal = 0;
            MTLDevice_heapTextureSizeAndAlign(d->mtl_device, &ti, &psz, &pal);
            if (psz && pal && !(poff % pal) && poff + psz <= ph->desc.SizeInBytes)
                r->texture = MTLHeap_newTextureAtOffset(ph->mtl, &ti, poff);
            if (r->texture) { r->placed_heap = ph; ID3D12Heap_AddRef((ID3D12Heap *)ph); InterlockedIncrement(&g_placed_in_heap); }
            else mad_placed_fallback(ph, desc, poff, psz, pal);
        }
        if (!r->texture && !(desc->Flags & (D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET | D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL | D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS))
            && ti.sample_count <= 1) {   /* ml1072 */
            UINT64 hsz = 0, hal = 0, hoff = 0; int hidx;
            MTLDevice_heapTextureSizeAndAlign(d->mtl_device, &ti, &hsz, &hal);
            if (hsz && hsz <= MAD_HP_MAX_TEX && (hidx = mad_hp_alloc(d, hsz, hal, &hoff)) >= 0) {
                r->texture = MTLHeap_newTextureAtOffset(d->theaps[hidx].heap, &ti, hoff);
                if (r->texture) { r->hp_used = 1; r->hp_heap = (unsigned)hidx; r->hp_off = hoff; r->hp_size = hsz; InterlockedIncrement(&d->hp_textures); }
                else { r->hp_used = 1; r->hp_heap = (unsigned)hidx; r->hp_off = hoff; r->hp_size = hsz; mad_hp_release(d, r); r->hp_used = 0; InterlockedIncrement(&d->hp_fallbacks); }
            }
        }
        if (!r->texture) r->texture = MTLDevice_newTexture(d->mtl_device, &ti);
        if (!r->texture) { free(r); return mad_creation_failure(d, "newTexture"); }
        if (!r->hp_used && !r->placed_heap) mad_resident(d, r->texture);   /* ml1145: a placed one is resident through its heap */
        r->width = ti.width; r->height = ti.height;
        r->gpu_resource_id = ti.gpu_resource_id;
        r->tex_type = ti.type; r->tex_pf = pf; r->tex_mips = ti.mipmap_level_count;   /* ml913 */
        r->tex_layers = ti.type == WMTTextureType3D ? 1 : ti.array_length;
        r->tex_depth = ti.type == WMTTextureType3D ? ti.depth : 1;   /* ml924 */
        /* ml1053: BASE textures were not in the view map, so every sm5 texture
         * binding that named one fell back to mad_texture_of_view -- a linear
         * walk of every SRV'd resource and every view of each, per range, per
         * draw. With the JIT no longer thrashing it was 34 of 36 samples taken
         * inside this DLL. */
        EnterCriticalSection(&d->view_lock);
        mad_vmap_put_locked(d, r->gpu_resource_id, r->tex_layers ? r->tex_layers : 1, 0);
        LeaveCriticalSection(&d->view_lock);
        r->name = is_depth ? "DepthTarget" : (desc->Flags & D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET) ? "RenderTarget" : "Texture";
        r->is_depth = is_depth;
        r->has_stencil = (pf == WMTPixelFormatDepth32Float_Stencil8);
        r->samples = ti.sample_count;
        if (!r->placed_heap) {   /* ml1057; ml1145: a placed texture costs nothing beyond its heap */
            UINT fb = 0, blk = 1; UINT64 px, bytes;
            mad_format_info(desc->Format, &fb, &blk);
            if (!blk) blk = 1;
            px = (UINT64)ti.width * ti.height * (ti.type == WMTTextureType3D ? ti.depth : ti.array_length);
            bytes = px * (fb ? fb : 4) / ((UINT64)blk * blk);
            if (ti.mipmap_level_count > 1) bytes += bytes / 3;
            bytes *= ti.sample_count ? ti.sample_count : 1;
            mad_acct(r, ti.sample_count > 1 ? MAD_CAT_TEX_MSAA : is_depth ? MAD_CAT_TEX_DS
                        : (desc->Flags & D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET) ? MAD_CAT_TEX_RT
                        : (desc->Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS) ? MAD_CAT_TEX_UAV : MAD_CAT_TEX_PLAIN, bytes, +1);
        }
        hr = res_QI((ID3D12Resource *)r, riid, out);
        if (FAILED(hr)) mad_refuse_log(desc, heap_type, "interface not answered");
        res_Release((ID3D12Resource *)r);
        return hr;
    }

    {
        struct WMTBufferInfo info;
        memset(&info, 0, sizeof info);
        info.length = desc->Width ? desc->Width : 1;
        /* UPLOAD and READBACK are CPU visible: the backend owns the storage and
         * hands back the mapping (see the alignment trap noted at ml839: caller
         * memory must be page aligned in both pointer and length). */
        info.options = heap_type == D3D12_HEAP_TYPE_DEFAULT ? WMTResourceStorageModePrivate : WMTResourceStorageModeShared;
        info.memory.ptr = NULL;
        if (ph && ph->mtl && heap_type == D3D12_HEAP_TYPE_DEFAULT) {   /* ml1145: inside the application's heap */
            UINT64 psz = 0, pal = 0;
            MTLDevice_heapBufferSizeAndAlign(d->mtl_device, info.length, info.options, &psz, &pal);
            if (psz && pal && !(poff % pal) && poff + psz <= ph->desc.SizeInBytes)
                r->buffer = MTLHeap_newBufferAtOffset(ph->mtl, &info, poff);
            if (r->buffer) { r->placed_heap = ph; ID3D12Heap_AddRef((ID3D12Heap *)ph); InterlockedIncrement(&g_placed_in_heap); }
            else { mad_placed_fallback(ph, desc, poff, psz, pal); info.memory.ptr = NULL; info.gpu_address = 0; }
        }
        /* ml1154: a large CPU-visible buffer gets storage WE allocate, handed to
         * Metal as a no-copy buffer. A fresh >= 8 MB guest commit is backed by
         * the file tier (ml1077), whose dirty pages iOS writes back and never
         * charges to phys_footprint, the number jetsam kills on. UE 5.0 keeps
         * 0.4-0.9 GB of UPLOAD buffers live (ph-valley08-13), and its load-time
         * peak is what kills the Lumen runs. Metal-allocated shared storage is
         * charged in full. madeira.cfg upload-swap = 0 turns it off. */
        if (!r->buffer && heap_type != D3D12_HEAP_TYPE_DEFAULT && info.length >= (8u << 20) && mad_upload_swap_on()) {
            SIZE_T len = (SIZE_T)((info.length + 0xffff) & ~(UINT64)0xffff);
            void *mem = VirtualAlloc(NULL, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            if (mem) {
                UINT64 want = info.length;
                info.length = len; info.memory.ptr = mem;
                r->buffer = MTLDevice_newBuffer(d->mtl_device, &info);
                if (r->buffer) { r->own_mem = mem; InterlockedExchangeAdd64(&g_upload_swap_bytes, (LONG64)len); InterlockedIncrement(&g_upload_swap_n); }
                else { VirtualFree(mem, 0, MEM_RELEASE); info.length = want; info.memory.ptr = NULL; info.gpu_address = 0; }
                {
                    static unsigned said;
                    if (said++ < 8)
                        d3d12_log("[madeira-d3d12] ml1154 CPU-visible buffer %llu MB (heap type %u) on our storage %p: %s; %ld so far, %lld MB\n",
                                  (unsigned long long)(want >> 20), (unsigned)heap_type, mem, r->buffer ? "Metal accepted it" : "Metal REFUSED it, Metal-owned instead",
                                  g_upload_swap_n, (long long)(g_upload_swap_bytes >> 20));
                }
            }
        }
        if (!r->buffer) r->buffer = MTLDevice_newBuffer(d->mtl_device, &info);
        if (!r->buffer) { free(r); return mad_creation_failure(d, "newBuffer"); }
        if (!r->placed_heap) {
            mad_acct(r, heap_type == D3D12_HEAP_TYPE_DEFAULT ? MAD_CAT_BUF_PRIVATE : MAD_CAT_BUF_SHARED, info.length, +1);   /* ml1057 */
            mad_resident(d, r->buffer);
        }
        r->cpu = info.memory.ptr;      /* NULL for GPU-private, which is correct */
        r->gpu_address = info.gpu_address;
        mad_track(d, r);
        if (info.length >= (16u << 20) && !r->placed_heap) {            /* ml885: big buffers, with where they live */
            static unsigned said_big;
            if (said_big++ < 40)
                d3d12_log("[madeira-d3d12] big buffer: %llu MB heap-type %u cpu=%p gpu=0x%llx flags 0x%x\n",
                          (unsigned long long)(info.length >> 20), (unsigned)heap_type, r->cpu,
                          (unsigned long long)r->gpu_address, (unsigned)desc->Flags);
        }
        if (heap_type != D3D12_HEAP_TYPE_DEFAULT && !r->cpu) {
            d3d12_log("[madeira-d3d12] CPU-visible buffer came back without a mapping\n");
            mad_untrack(d, r);
            NSObject_release(r->buffer);
            free(r);
            return E_FAIL;
        }
    }
    hr = res_QI((ID3D12Resource *)r, riid, out);
        if (FAILED(hr)) mad_refuse_log(desc, heap_type, "interface not answered");
    res_Release((ID3D12Resource *)r);
    return hr;
}

static HRESULT STDMETHODCALLTYPE device_CreateCommittedResource(ID3D12Device *This,
        const D3D12_HEAP_PROPERTIES *heap, D3D12_HEAP_FLAGS heap_flags,
        const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES state,
        const D3D12_CLEAR_VALUE *clear, REFIID riid, void **out) {
    (void)heap_flags; (void)state; (void)clear;
    HRESULT hr;
    static unsigned said;
    if (!heap || !desc || !out) { if (said++ < 8) d3d12_log("[madeira-d3d12] CreateCommittedResource: null props/desc/out\n"); return E_INVALIDARG; }
    hr = mad_create_resource((struct mad_device *)This, heap->Type, desc, riid, out);
    if (desc->Width >= (32u << 20) && desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER && said++ < 64)
        d3d12_log("[madeira-d3d12] committed: %llu MB flags %#x heap-type %u -> hr %#lx\n",
                  (unsigned long long)(desc->Width >> 20), (unsigned)desc->Flags, (unsigned)heap->Type, (unsigned long)hr);
    return hr;
}

/* ---- heaps -----------------------------------------------------------------
 * A heap is a promise of memory the application will carve up itself.
 * ml1145: a DEFAULT heap is backed by a Metal placement heap of the same size
 * and its placed resources live INSIDE it at the application's offset, so
 * resources the application aliases share memory as they do in D3D12 (see
 * struct mad_memheap above mad_create_resource). Other heap types keep the
 * description only; their placed resources allocate on their own. */
static ID3D12HeapVtbl g_memheap_vtbl;
static HRESULT STDMETHODCALLTYPE memheap_QI(ID3D12Heap *This, REFIID riid, void **out) {
    struct mad_obj *o = (struct mad_obj *)This;
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_ID3D12Pageable)) { InterlockedIncrement(&o->refs); *out = This; return S_OK; }
    return mad_qi(o, riid, out, 1);
}
static ULONG STDMETHODCALLTYPE memheap_AddRef(ID3D12Heap *This) { return mad_addref((struct mad_obj *)This); }
static ULONG STDMETHODCALLTYPE memheap_Release(ID3D12Heap *This) {
    struct mad_obj *o = (struct mad_obj *)This;
    LONG n = InterlockedDecrement(&o->refs);
    if (n == 0) { mad_pd_purge(This);   /* ml1143 */
        struct mad_memheap *h = (struct mad_memheap *)This;
        static unsigned said;
        if (h->desc.Alignment == 4194304 && (h->desc.Flags & 0x1000) && said++ < 200)
            d3d12_log("[transient] list#%u heap %p DESTROYED (%llu KB)\n", g_list_seq, (void *)h,
                      (unsigned long long)h->desc.SizeInBytes >> 10);   /* ml895 */
        if (h->mtl) {   /* ml1145: every placed resource held a reference, so none is left; ml1148: but the GPU may still hold them */
            struct mad_device *hd = h->device; int queued = 0;
            EnterCriticalSection(&hd->heap_lock);
            if (mad_grow((void **)&hd->mhret, &hd->mhret_cap, hd->nmhret + 1, sizeof *hd->mhret)) {
                hd->mhret[hd->nmhret].heap = h->mtl; hd->mhret[hd->nmhret].serial = (UINT64)hd->gpu_serial; hd->mhret[hd->nmhret].mem = NULL; hd->nmhret++; queued = 1;
            }
            LeaveCriticalSection(&hd->heap_lock);
            if (!queued) { mad_unresident(hd, h->mtl); NSObject_release(h->mtl); }
            mad_mheap_reclaim(hd, 0);
        }
        free(o);
    }
    return (ULONG)n;
}
static HRESULT STDMETHODCALLTYPE memheap_GetPrivateData(ID3D12Heap *This, REFGUID g, UINT *n, void *d) {
    return mad_pd_get(This, g, n, d);   /* ml1143 */
}
static HRESULT STDMETHODCALLTYPE memheap_SetPrivateData(ID3D12Heap *This, REFGUID g, UINT n, const void *d) {
    return mad_pd_set(This, g, n, d);   /* ml1143 */
}
static HRESULT STDMETHODCALLTYPE memheap_SetPrivateDataInterface(ID3D12Heap *This, REFGUID g, const IUnknown *d) {
    return mad_pd_set_iface(This, g, d);   /* ml1143 */
}
static HRESULT STDMETHODCALLTYPE memheap_SetName(ID3D12Heap *This, LPCWSTR name) { (void)This; (void)name; return S_OK; }
static HRESULT STDMETHODCALLTYPE memheap_GetDevice(ID3D12Heap *This, REFIID riid, void **out) {
    struct mad_memheap *h = (struct mad_memheap *)This;
    return h->device->vtbl->QueryInterface((ID3D12Device10 *)h->device, riid, out);
}
static D3D12_HEAP_DESC * STDMETHODCALLTYPE memheap_GetDesc(ID3D12Heap *This, D3D12_HEAP_DESC *ret) {
    *ret = ((struct mad_memheap *)This)->desc;
    return ret;
}

static HRESULT STDMETHODCALLTYPE device_CreateHeap(ID3D12Device *This, const D3D12_HEAP_DESC *desc,
                                                   REFIID riid, void **out) {
    struct mad_memheap *h;
    HRESULT hr;
    static unsigned said;
    if (!desc || !out) return E_INVALIDARG;
    *out = NULL;
    h = calloc(1, sizeof *h);
    if (!h) return E_OUTOFMEMORY;
    h->vtbl = &g_memheap_vtbl; h->refs = 1; h->iid = &IID_ID3D12Heap; h->name = "Heap";
    h->device = (struct mad_device *)This;
    h->desc = *desc;
    {   /* ml1145 */
        static int backing = -1; static unsigned said_b;
        struct mad_device *hd = (struct mad_device *)This;
        if (backing < 0) { backing = (int)mad_cfg_int_pe("heap-backing", 1); d3d12_log("[madeira-d3d12] ml1145 heap-backing = %d (DEFAULT heaps %s)\n", backing, backing ? "are Metal placement heaps; placed resources alias" : "are descriptions only"); }
        if (backing && desc->Properties.Type == D3D12_HEAP_TYPE_DEFAULT && desc->SizeInBytes) {
            h->mtl = MTLDevice_newPlacementHeap(hd->mtl_device, desc->SizeInBytes, WMTResourceStorageModePrivate);
            if (h->mtl) mad_resident(hd, h->mtl);
            if (said_b++ < 32) d3d12_log("[madeira-d3d12] ml1145 heap %llu KB flags %#x %s\n", (unsigned long long)(desc->SizeInBytes >> 10),
                                         (unsigned)desc->Flags, h->mtl ? "backed by a Metal placement heap" : "COULD NOT be backed; its resources stand alone");
        }
    }
    if (said < 4096) {   /* ml891: every heap, with its alignment -- the transient allocator lives here */
        said++;
        d3d12_log("[madeira-d3d12] heap: %llu KB, type %u, flags %#x, align %llu -> %p\n",
                  (unsigned long long)(desc->SizeInBytes / 1024), (unsigned)desc->Properties.Type, (unsigned)desc->Flags,
                  (unsigned long long)desc->Alignment, (void *)h);
    }
    hr = memheap_QI((ID3D12Heap *)h, riid, out);
    memheap_Release((ID3D12Heap *)h);
    return hr;
}

static HRESULT STDMETHODCALLTYPE device_CreatePlacedResource(ID3D12Device *This, ID3D12Heap *heap,
        UINT64 offset, const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES state,
        const D3D12_CLEAR_VALUE *clear, REFIID riid, void **out) {
    struct mad_memheap *h = (struct mad_memheap *)heap;
    HRESULT hr;
    static unsigned said;
    (void)state; (void)clear;
    if (!h || !desc || !out) { if (said++ < 8) d3d12_log("[madeira-d3d12] CreatePlacedResource: null heap/desc/out\n"); return E_INVALIDARG; }
    hr = mad_create_resource_at((struct mad_device *)This, h->desc.Properties.Type, desc, riid, out, h, offset);   /* ml1145 */
    /* ml895: every placement inside a TRANSIENT heap (4 MB aligned, NOT_ZEROED)
     * with the list sequence, so a heap's occupancy can be replayed offline.
     * The RenderThread fault behind every menu crash is UE's transient
     * allocator handing RDG a NULL buffer: its heap cache returned a heap
     * that could not fit the request instead of creating a third heap. */
    if (h->desc.Alignment == 4194304 && (h->desc.Flags & 0x1000)) {
        static unsigned tsaid;
        if (tsaid++ < 3000)
            d3d12_log("[transient] list#%u heap %p +%llu size %llu KB dim %u flags %#x -> hr %#lx\n",
                      g_list_seq, (void *)h, (unsigned long long)offset,
                      (unsigned long long)(desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER ? desc->Width : 0) >> 10,
                      (unsigned)desc->Dimension, (unsigned)desc->Flags, (unsigned long)hr);
    }
    if (desc->Width >= (32u << 20) && said++ < 64)
        d3d12_log("[madeira-d3d12] placed: %llu MB dim %u flags %#x in heap %p (%llu KB, flags %#x) at offset %llu -> hr %#lx\n",
                  (unsigned long long)(desc->Width >> 20), (unsigned)desc->Dimension, (unsigned)desc->Flags, (void *)h,
                  (unsigned long long)(h->desc.SizeInBytes / 1024), (unsigned)h->desc.Flags, (unsigned long long)offset, (unsigned long)hr);
    return hr;
}



/* ---- root signature, pipeline state, descriptor heap --------------------- */
static ID3D12RootSignatureVtbl g_rootsig_vtbl;
static ID3D12PipelineStateVtbl g_pso_vtbl;
static ID3D12DescriptorHeapVtbl g_heap_vtbl;


static HRESULT STDMETHODCALLTYPE rootsig_QI(ID3D12RootSignature *T, REFIID r, void **o) { return mad_qi((struct mad_obj *)T, r, o, 1); }
static ULONG STDMETHODCALLTYPE rootsig_AddRef(ID3D12RootSignature *T) { return mad_addref((struct mad_obj *)T); }
static ULONG STDMETHODCALLTYPE rootsig_Release(ID3D12RootSignature *T) { return mad_release((struct mad_obj *)T); }

static HRESULT STDMETHODCALLTYPE heap_QI(ID3D12DescriptorHeap *T, REFIID r, void **o) { return mad_qi((struct mad_obj *)T, r, o, 1); }
static ULONG STDMETHODCALLTYPE heap_AddRef(ID3D12DescriptorHeap *T) { return mad_addref((struct mad_obj *)T); }
static ULONG STDMETHODCALLTYPE heap_Release(ID3D12DescriptorHeap *T) {
    struct mad_heap *h = (struct mad_heap *)T;
    LONG r = InterlockedDecrement(&h->refs);
    if (r == 0) { mad_pd_purge(T);   /* ml1143 */
        /* The Metal buffer of a shader-visible heap is deliberately kept: a
         * command buffer already submitted may still read it. CPU-only
         * storage has no such reader. */
        free(h->slots);
        if (!h->buffer) free(h->cpu);
        free(h);
    }
    return (ULONG)r;
}
/* The header returns this struct through a hidden out-pointer on this ABI, so
 * the slot signature is not the one the method appears to have. Matching the
 * header exactly is the whole reason the vtables are generated from it. */
static D3D12_DESCRIPTOR_HEAP_DESC * STDMETHODCALLTYPE heap_GetDesc(ID3D12DescriptorHeap *T, D3D12_DESCRIPTOR_HEAP_DESC *ret) {
    *ret = ((struct mad_heap *)T)->desc;
    return ret;
}

/* Unified memory: every heap type lives in the one pool, and the CPU page
 * property is the one the standard heap of that type implies. */
static D3D12_HEAP_PROPERTIES * STDMETHODCALLTYPE device_GetCustomHeapProperties(ID3D12Device *This,
        D3D12_HEAP_PROPERTIES *ret, UINT node_mask, D3D12_HEAP_TYPE type) {
    (void)This; (void)node_mask;
    memset(ret, 0, sizeof *ret);
    ret->Type = D3D12_HEAP_TYPE_CUSTOM;
    ret->MemoryPoolPreference = D3D12_MEMORY_POOL_L0;
    ret->CPUPageProperty = (type == D3D12_HEAP_TYPE_UPLOAD)   ? D3D12_CPU_PAGE_PROPERTY_WRITE_COMBINE
                         : (type == D3D12_HEAP_TYPE_READBACK) ? D3D12_CPU_PAGE_PROPERTY_WRITE_BACK
                         : D3D12_CPU_PAGE_PROPERTY_NOT_AVAILABLE;
    ret->CreationNodeMask = 1; ret->VisibleNodeMask = 1;
    return ret;
}

static D3D12_CPU_DESCRIPTOR_HANDLE * STDMETHODCALLTYPE
heap_GetCPUDescriptorHandleForHeapStart(ID3D12DescriptorHeap *T, D3D12_CPU_DESCRIPTOR_HANDLE *out) {
    /* The address of slot zero, so an application that computes
     * `start + index * increment` lands on the slot it meant. Both kinds of
     * heap answer in their own storage: RTV and DSV heaps in an array of
     * resource pointers that never reaches the GPU, shader-visible heaps in the
     * Metal buffer the shader reads.
     *
     * This is still not a GPU address and is never dereferenced as one. The GPU
     * handle below is the separate namespace, and only shader-visible heaps
     * have one at all. */
    struct mad_heap *h = (struct mad_heap *)T;
    if (out) out->ptr = h->cpu ? (SIZE_T)h->cpu : (SIZE_T)h->slots;
    return out;
}

static D3D12_GPU_DESCRIPTOR_HANDLE * STDMETHODCALLTYPE
heap_GetGPUDescriptorHandleForHeapStart(ID3D12DescriptorHeap *T, D3D12_GPU_DESCRIPTOR_HANDLE *out) {
    /* Measured, not assumed: a descriptor table root argument is the ABSOLUTE
     * GPU address of its first descriptor. A byte offset and a descriptor index
     * were both tried on a real device and rendered nothing
     * (tests/native/table_abi_probe.mm). Returning the heap's base address here
     * means the application's own handle arithmetic produces exactly that. */
    struct mad_heap *h = (struct mad_heap *)T;
    if (out) out->ptr = h->gpu_address;
    return out;
}

static ULONG STDMETHODCALLTYPE pso_AddRef(ID3D12PipelineState *T) { return mad_addref((struct mad_obj *)T); }
static HRESULT STDMETHODCALLTYPE pso_QI(ID3D12PipelineState *T, REFIID r, void **o) { return mad_qi((struct mad_obj *)T, r, o, 1); }
static void mad_tess_free(struct mad_tess *t) {   /* ml1083; ml1147b: shared by the tessellation and geometry records */
    unsigned k;
    if (!t) return;
    for (k = 0; k < 3; k++) {
        if (t->obj[k].rps) NSObject_release(t->obj[k].rps);
        if (t->obj[k].fn) NSObject_release(t->obj[k].fn);
        if (t->obj[k].lib) NSObject_release(t->obj[k].lib);
        free(t->obj[k].vs.air); free(t->obj[k].hs.air);
    }
    if (t->ds_fn) NSObject_release(t->ds_fn);
    if (t->ds_lib) NSObject_release(t->ds_lib);
    free(t->ds.air);
    free(t);
}
static ULONG STDMETHODCALLTYPE pso_Release(ID3D12PipelineState *T) {
    struct mad_pso *p = (struct mad_pso *)T;
    LONG n = InterlockedDecrement(&p->refs);
    if (n == 0) { mad_pd_purge(T);   /* ml1143 */
        if (p->rps) NSObject_release(p->rps);
        { unsigned k; for (k = 0; k < p->nvar; k++) if (p->var[k].rps) NSObject_release(p->var[k].rps); }
        if (p->has_vd) DeleteCriticalSection(&p->var_lock);
        if (p->vs_fn) NSObject_release(p->vs_fn);
        if (p->ps_fn) NSObject_release(p->ps_fn);
        if (p->vs_lib) NSObject_release(p->vs_lib);
        if (p->ps_lib) NSObject_release(p->ps_lib);
        if (p->si_lib) NSObject_release(p->si_lib);   /* ml927 */
        if (p->gs_lib) NSObject_release(p->gs_lib);
        if (p->dsso) NSObject_release(p->dsso);
        if (p->cps) NSObject_release(p->cps);
        free(p->air);   /* ml1010 */
        free(p->ps_air);   /* ml1011 */
        mad_tess_free(p->tess);         /* ml1083 */
        mad_tess_free(p->tess_strip);   /* ml1147b */
        free(p);
    }
    return (ULONG)n;
}

/* ---- serialized root signatures -------------------------------------------
 *
 * The real D3D12 container, not a private encoding: a DXBC wrapper around an
 * RTS0 chunk. Games ship precompiled root signatures in exactly this form, so
 * a runtime that only understood something we invented would stop working the
 * moment it met real content. The layout below was read from a working
 * implementation (wine's vkd3d) rather than recalled.
 *
 *   DXBC header : "DXBC", 16-byte digest, u32 version, u32 total size,
 *                 u32 chunk count, u32 chunk offsets[count]
 *   chunk       : "RTS0", u32 size, payload
 *   payload     : u32 version, u32 param count, u32 param offset,
 *                 u32 sampler count, u32 sampler offset, u32 flags
 *   parameter   : u32 type, u32 visibility, u32 payload offset
 *   constants   : u32 shader register, u32 register space, u32 count
 *   descriptor  : u32 shader register, u32 register space, u32 flags   (1.1)
 *   table       : u32 range count, u32 range offset
 *   range       : u32 type, u32 count, u32 base register, u32 space,
 *                 u32 flags, u32 table offset                          (1.1)
 *
 * Every offset is relative to the start of the chunk payload. */
/* rsdeser-test:begin (tests/windows/rsdeser_test.c compiles the marked regions on their own) */
static UINT32 rs_rd(const unsigned char *b, SIZE_T n, SIZE_T off, int *bad) {
    if (off + 4 > n) { *bad = 1; return 0; }
    return (UINT32)b[off] | ((UINT32)b[off+1] << 8) |
           ((UINT32)b[off+2] << 16) | ((UINT32)b[off+3] << 24);
}
static void rs_wr(unsigned char *b, SIZE_T off, UINT32 v) {
    b[off] = (unsigned char)(v); b[off+1] = (unsigned char)(v >> 8);
    b[off+2] = (unsigned char)(v >> 16); b[off+3] = (unsigned char)(v >> 24);
}

static UINT32 rs_vis(D3D12_SHADER_VISIBILITY v) {
    switch (v) {
    case D3D12_SHADER_VISIBILITY_VERTEX:   return MADEIRA_IR_VIS_VERTEX;
    case D3D12_SHADER_VISIBILITY_HULL:     return MADEIRA_IR_VIS_HULL;
    case D3D12_SHADER_VISIBILITY_DOMAIN:   return MADEIRA_IR_VIS_DOMAIN;
    case D3D12_SHADER_VISIBILITY_GEOMETRY: return MADEIRA_IR_VIS_GEOMETRY;
    case D3D12_SHADER_VISIBILITY_PIXEL:    return MADEIRA_IR_VIS_PIXEL;
    default:                               return MADEIRA_IR_VIS_ALL;
    }
}

/* Find the RTS0 chunk. Returns its payload, or NULL with a named reason. */
static const unsigned char *rs_find_chunk(const unsigned char *b, SIZE_T n,
                                          SIZE_T *out_n, const char **why) {
    int bad = 0;
    if (n < 32 || memcmp(b, "DXBC", 4) != 0) { *why = "not a DXBC container"; return NULL; }
    UINT32 nchunk = rs_rd(b, n, 28, &bad);
    if (bad || nchunk == 0 || nchunk > 32) { *why = "implausible chunk count"; return NULL; }
    for (UINT32 i = 0; i < nchunk; i++) {
        UINT32 off = rs_rd(b, n, 32 + 4 * i, &bad);
        if (bad || (SIZE_T)off + 8 > n) { *why = "chunk offset out of range"; return NULL; }
        UINT32 sz = rs_rd(b, n, off + 4, &bad);
        if (bad || (SIZE_T)off + 8 + sz > n) { *why = "chunk size out of range"; return NULL; }
        if (memcmp(b + off, "RTS0", 4) == 0) { *out_n = sz; return b + off + 8; }
    }
    *why = "no RTS0 chunk";
    return NULL;
}
/* rsdeser-test:end */

static HRESULT STDMETHODCALLTYPE device_CreateRootSignature(ID3D12Device *This, UINT node,
        const void *blob, SIZE_T blob_len, REFIID riid, void **out) {
    (void)This; (void)node;
    if (!out || !blob) return E_INVALIDARG;

    SIZE_T n = 0;
    const char *why = "?";
    const unsigned char *p = rs_find_chunk((const unsigned char *)blob, blob_len, &n, &why);
    if (!p) {
        d3d12_log("[madeira-d3d12] CreateRootSignature: %s -- refusing rather than assuming a layout\n", why);
        return E_INVALIDARG;
    }

    int bad = 0;
    UINT32 version   = rs_rd(p, n, 0,  &bad);
    UINT32 nparam    = rs_rd(p, n, 4,  &bad);
    UINT32 poff      = rs_rd(p, n, 8,  &bad);
    UINT32 nsampler  = rs_rd(p, n, 12, &bad);
    if (bad) { d3d12_log("[madeira-d3d12] CreateRootSignature: truncated RTS0 header\n"); return E_INVALIDARG; }
    if (version != 1 && version != 2) {
        d3d12_log("[madeira-d3d12] CreateRootSignature: root signature version %u is not supported\n", version);
        return E_NOTIMPL;
    }
    UINT32 soff = rs_rd(p, n, 16, &bad);
    if (nsampler > 32) {
        d3d12_log("[madeira-d3d12] CreateRootSignature: %u static samplers exceeds the 32 this build handles\n", nsampler);
        return E_NOTIMPL;
    }
    if (nparam > MAD_ROOT_PARAM_MAX) {
        d3d12_log("[madeira-d3d12] CreateRootSignature: %u parameters exceeds the %u this build handles\n",
                  nparam, (unsigned)MAD_ROOT_PARAM_MAX);
        return E_NOTIMPL;
    }

    /* ml1009: count the descriptor ranges before allocating, so the object is
     * sized to this blob instead of to a guess. Most root signatures need a
     * handful; the large ones get exactly what they ask for. */
    UINT32 total_ranges = 0;
    {
        int bad2 = 0;
        for (UINT32 i = 0; i < nparam; i++) {
            UINT32 type = rs_rd(p, n, poff + 12 * i,     &bad2);
            UINT32 off2 = rs_rd(p, n, poff + 12 * i + 8, &bad2);
            if (bad2) { d3d12_log("[madeira-d3d12] CreateRootSignature: RTS0 chunk is truncated\n"); return E_INVALIDARG; }
            if (type != D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) continue;
            UINT32 nr = rs_rd(p, n, off2, &bad2);
            if (bad2) { d3d12_log("[madeira-d3d12] CreateRootSignature: RTS0 chunk is truncated\n"); return E_INVALIDARG; }
            /* A corrupt blob must not turn into a huge allocation. The bound is
             * generous but finite, and it PRINTS the count it saw so the log
             * says what a real signature needs rather than just that it lost. */
            if (nr > MAD_ROOT_RANGE_SANE || total_ranges + nr > MAD_ROOT_RANGE_SANE) {
                d3d12_log("[madeira-d3d12] CreateRootSignature: implausible descriptor range count "
                          "(parameter %u asks for %u, running total %u, sane bound %u)\n",
                          i, nr, total_ranges, (unsigned)MAD_ROOT_RANGE_SANE);
                return E_NOTIMPL;
            }
            total_ranges += nr;
        }
    }

    struct mad_rootsig *r = calloc(1, sizeof *r + (size_t)total_ranges * sizeof *r->ranges);
    if (!r) return E_OUTOFMEMORY;
    r->vtbl = &g_rootsig_vtbl; r->refs = 1; r->iid = &IID_ID3D12RootSignature; r->name = "RootSignature";
    r->ranges = total_ranges ? (struct madeira_ir_root_range *)((char *)r + sizeof *r) : NULL;
    r->nparams = nparam;
    {   /* ml1009: how big real signatures actually are, so the bound above is
         * evidence-based rather than folklore. */
        static UINT32 seen_max;
        if (total_ranges > seen_max) {
            seen_max = total_ranges;
            if (total_ranges > MAD_ROOT_RANGE_MAX)
                d3d12_log("[madeira-d3d12] ml1009 new high-water descriptor range count: %u "
                          "(the old fixed cap was %u)\n", total_ranges, (unsigned)MAD_ROOT_RANGE_MAX);
        }
    }
    /* Static samplers: 13 dwords each, the D3D12 description verbatim, the
     * same in root signature versions 1.0 and 1.1 (1.2 adds a flags word and
     * is refused above by version). */
    r->nsamplers = nsampler;
    r->stab = 0; r->stab_gpu = 0;
    for (UINT32 i = 0; i < nsampler; i++) {
        struct madeira_ir_static_sampler *ss = &r->samplers[i];
        UINT32 at = soff + 52 * i, w[13], k;
        for (k = 0; k < 13; k++) w[k] = rs_rd(p, n, at + 4 * k, &bad);
        if (bad) goto truncated;
        ss->filter = w[0]; ss->address_u = w[1]; ss->address_v = w[2]; ss->address_w = w[3];
        memcpy(&ss->mip_lod_bias, &w[4], 4);
        ss->max_anisotropy = w[5]; ss->comparison = w[6]; ss->border_color = w[7];
        memcpy(&ss->min_lod, &w[8], 4); memcpy(&ss->max_lod, &w[9], 4);
        ss->shader_register = w[10]; ss->register_space = w[11];
        ss->visibility = w[12] == 1 ? MADEIRA_IR_VIS_VERTEX : w[12] == 2 ? MADEIRA_IR_VIS_HULL : w[12] == 3 ? MADEIRA_IR_VIS_DOMAIN
                       : w[12] == 4 ? MADEIRA_IR_VIS_GEOMETRY : w[12] == 5 ? MADEIRA_IR_VIS_PIXEL : MADEIRA_IR_VIS_ALL;
    }

    if (nsampler) {   /* ml923: the sampler descriptors the converter's implicit table slot points at */
        struct mad_device *dd = (struct mad_device *)This;
        struct WMTBufferInfo bi; memset(&bi, 0, sizeof bi);
        bi.length = (uint64_t)nsampler * sizeof(struct mad_descriptor); bi.options = WMTResourceStorageModeShared;
        r->stab = MTLDevice_newBuffer(dd->mtl_device, &bi);
        if (r->stab && bi.memory.ptr) {
            struct mad_descriptor *tab = (struct mad_descriptor *)bi.memory.ptr; UINT32 i, ok = 0;
            memset(tab, 0, bi.length);
            for (i = 0; i < nsampler; i++) {
                struct madeira_ir_static_sampler *ss = &r->samplers[i]; struct WMTSamplerInfo si; obj_handle_t smp; UINT32 bias_bits;
                mad_sampler_info(&si, ss->filter, ss->address_u, ss->address_v, ss->address_w, ss->max_anisotropy, ss->comparison, ss->border_color, ss->min_lod, ss->max_lod);
                smp = MTLDevice_newSamplerState(dd->mtl_device, &si);
                if (!smp || !si.gpu_resource_id) continue;
                memcpy(&bias_bits, &ss->mip_lod_bias, 4);
                tab[i].gpu_va = si.gpu_resource_id; tab[i].texture_view_id = 0; tab[i].metadata = (UINT64)bias_bits;
                mad_note_sampler(dd, smp); ok++;
            }
            mad_resident(dd, r->stab);
            r->stab_gpu = bi.gpu_address;
            { static unsigned said; if (said++ < 4) d3d12_log("[madeira-d3d12] static sampler table: %u/%u samplers at %llx\n", ok, nsampler, (unsigned long long)r->stab_gpu); }
        } else { if (r->stab) { NSObject_release(r->stab); r->stab = 0; } d3d12_log("[madeira-d3d12] static sampler table: buffer creation failed\n"); }
    }

    for (UINT32 i = 0; i < nparam; i++) {
        UINT32 type = rs_rd(p, n, poff + 12 * i,     &bad);
        UINT32 vis  = rs_rd(p, n, poff + 12 * i + 4, &bad);
        UINT32 off  = rs_rd(p, n, poff + 12 * i + 8, &bad);
        if (bad) goto truncated;
        r->params[i].visibility = rs_vis((D3D12_SHADER_VISIBILITY)vis);
        switch (type) {
        case D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS:
            r->params[i].type = MADEIRA_IR_PARAM_CONSTANTS;
            r->params[i].shader_register = rs_rd(p, n, off,     &bad);
            r->params[i].register_space  = rs_rd(p, n, off + 4, &bad);
            r->params[i].num_constants   = rs_rd(p, n, off + 8, &bad);
            break;
        case D3D12_ROOT_PARAMETER_TYPE_CBV:
        case D3D12_ROOT_PARAMETER_TYPE_SRV:
        case D3D12_ROOT_PARAMETER_TYPE_UAV:
            r->params[i].type = type == D3D12_ROOT_PARAMETER_TYPE_CBV ? MADEIRA_IR_PARAM_CBV
                              : type == D3D12_ROOT_PARAMETER_TYPE_SRV ? MADEIRA_IR_PARAM_SRV
                                                                      : MADEIRA_IR_PARAM_UAV;
            r->params[i].shader_register = rs_rd(p, n, off,     &bad);
            r->params[i].register_space  = rs_rd(p, n, off + 4, &bad);
            break;
        case D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE: {
            UINT32 nr   = rs_rd(p, n, off,     &bad);
            UINT32 roff = rs_rd(p, n, off + 4, &bad);
            if (bad) goto truncated;
            /* ml1009: the pre-pass already sized the array from this same
             * blob, so a mismatch here is our bug, not the application's. */
            if (r->nranges + nr > total_ranges || !r->ranges) {
                d3d12_log("[madeira-d3d12] CreateRootSignature: range count disagrees with the pre-pass "
                          "(%u + %u > %u) -- refusing\n", r->nranges, nr, total_ranges);
                rootsig_Release((ID3D12RootSignature *)r);
                return E_NOTIMPL;
            }
            r->params[i].type = MADEIRA_IR_PARAM_TABLE;
            r->params[i].first_range = r->nranges;
            r->params[i].num_ranges = nr;
            /* 1.0 ranges have five words, 1.1 adds a flags word before the
             * table offset. Reading a 1.0 blob with the 1.1 stride would shift
             * every later range, so the stride follows the declared version. */
            UINT32 stride = (version == 2) ? 24 : 20;
            for (UINT32 j = 0; j < nr; j++) {
                struct madeira_ir_root_range *rg = &r->ranges[r->nranges + j];
                SIZE_T b0 = roff + (SIZE_T)stride * j;
                UINT32 rt = rs_rd(p, n, b0,      &bad);
                rg->num_descriptors = rs_rd(p, n, b0 + 4,  &bad);
                rg->base_register   = rs_rd(p, n, b0 + 8,  &bad);
                rg->register_space  = rs_rd(p, n, b0 + 12, &bad);
                rg->table_offset    = rs_rd(p, n, b0 + (stride == 24 ? 20 : 16), &bad);
                switch (rt) {
                case D3D12_DESCRIPTOR_RANGE_TYPE_SRV:     rg->range_type = MADEIRA_IR_RANGE_SRV; break;
                case D3D12_DESCRIPTOR_RANGE_TYPE_UAV:     rg->range_type = MADEIRA_IR_RANGE_UAV; break;
                case D3D12_DESCRIPTOR_RANGE_TYPE_CBV:     rg->range_type = MADEIRA_IR_RANGE_CBV; break;
                case D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER: rg->range_type = MADEIRA_IR_RANGE_SAMPLER; break;
                default:
                    d3d12_log("[madeira-d3d12] CreateRootSignature: unknown descriptor range type %u\n", rt);
                    rootsig_Release((ID3D12RootSignature *)r);
                    return E_INVALIDARG;
                }
            }
            r->nranges += nr;
            break;
        }
        default:
            d3d12_log("[madeira-d3d12] CreateRootSignature: root parameter type %u is not supported\n", type);
            rootsig_Release((ID3D12RootSignature *)r);
            return E_NOTIMPL;
        }
        if (bad) goto truncated;
    }

    { static LONG said; if (InterlockedIncrement(&said) <= 24)   /* ml1053: was 15,589 lines a run */
    d3d12_log("[madeira-d3d12] root signature parsed from the application blob: "
              "version 1.%u, %u parameter(s), %u descriptor range(s), %u static sampler(s)\n",
              version == 2 ? 1u : 0u, r->nparams, r->nranges, r->nsamplers); }
    HRESULT hr = rootsig_QI((ID3D12RootSignature *)r, riid, out);
    rootsig_Release((ID3D12RootSignature *)r);
    return hr;

truncated:
    d3d12_log("[madeira-d3d12] CreateRootSignature: RTS0 chunk is truncated\n");
    rootsig_Release((ID3D12RootSignature *)r);
    return E_INVALIDARG;
}

/* rsdeser-test:begin */
/* Emits the same container the parser above reads, so a test can build a real
 * root signature instead of the runtime accepting a private shortcut. The DXBC
 * digest is left zero: nothing in this path verifies it, and writing a
 * plausible-looking but wrong checksum would be worse than an obvious zero. */
__declspec(dllexport) HRESULT WINAPI MadeiraD3D12SerializeRootSignature(
        const D3D12_ROOT_SIGNATURE_DESC1 *desc, unsigned char *out, SIZE_T *io_len) {
    if (!desc || !io_len) return E_INVALIDARG;
    if (desc->NumStaticSamplers && !desc->pStaticSamplers) return E_INVALIDARG;

    UINT32 nparam = desc->NumParameters;
    UINT32 nrange = 0;
    for (UINT32 i = 0; i < nparam; i++)
        if (desc->pParameters[i].ParameterType == D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE)
            nrange += desc->pParameters[i].DescriptorTable.NumDescriptorRanges;

    /* payload = header(24) + params(12 each) + per-param payload + ranges(24 each) */
    UINT32 payload_params = 12 * nparam;
    UINT32 payload_bodies = 0;
    for (UINT32 i = 0; i < nparam; i++)
        payload_bodies += (desc->pParameters[i].ParameterType == D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) ? 8 : 12;
    UINT32 sampler_at = 24 + payload_params + payload_bodies + 24 * nrange;
    UINT32 chunk = sampler_at + 52 * desc->NumStaticSamplers;
    UINT32 total = 32 + 4 /*one chunk offset*/ + 8 + chunk;

    if (!out || *io_len < total) { *io_len = total; return out ? E_NOT_SUFFICIENT_BUFFER : S_OK; }
    memset(out, 0, total);
    memcpy(out, "DXBC", 4);
    rs_wr(out, 20, 1);          /* container version */
    rs_wr(out, 24, total);
    rs_wr(out, 28, 1);          /* chunk count */
    rs_wr(out, 32, 36);         /* offset of the one chunk */
    memcpy(out + 36, "RTS0", 4);
    rs_wr(out, 40, chunk);

    unsigned char *p = out + 44;   /* chunk payload; offsets are relative here */
    rs_wr(p, 0, 2);                /* root signature version 1.1 */
    rs_wr(p, 4, nparam);
    rs_wr(p, 8, 24);               /* parameters follow the header */
    rs_wr(p, 12, desc->NumStaticSamplers);
    /* With no samplers the offset still points past the end of the parameter
     * tables, which is what the reference compiler emits (verified against a
     * dxc blob: byte-identical apart from the digest left zero). */
    rs_wr(p, 16, sampler_at);
    for (UINT32 i = 0; i < desc->NumStaticSamplers; i++) {
        /* The D3D12 description is thirteen 32-bit words in declaration order. */
        memcpy(p + sampler_at + 52 * i, &desc->pStaticSamplers[i], 52);
    }
    rs_wr(p, 20, (UINT32)desc->Flags);

    UINT32 body = 24 + payload_params;
    UINT32 range_at = 24 + payload_params + payload_bodies;
    for (UINT32 i = 0; i < nparam; i++) {
        const D3D12_ROOT_PARAMETER1 *rp = &desc->pParameters[i];
        rs_wr(p, 24 + 12 * i,     (UINT32)rp->ParameterType);
        rs_wr(p, 24 + 12 * i + 4, (UINT32)rp->ShaderVisibility);
        rs_wr(p, 24 + 12 * i + 8, body);
        if (rp->ParameterType == D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS) {
            rs_wr(p, body,     rp->Constants.ShaderRegister);
            rs_wr(p, body + 4, rp->Constants.RegisterSpace);
            rs_wr(p, body + 8, rp->Constants.Num32BitValues);
            body += 12;
        } else if (rp->ParameterType == D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) {
            rs_wr(p, body,     rp->DescriptorTable.NumDescriptorRanges);
            rs_wr(p, body + 4, range_at);
            for (UINT32 j = 0; j < rp->DescriptorTable.NumDescriptorRanges; j++) {
                const D3D12_DESCRIPTOR_RANGE1 *dr = &rp->DescriptorTable.pDescriptorRanges[j];
                rs_wr(p, range_at,      (UINT32)dr->RangeType);
                rs_wr(p, range_at + 4,  dr->NumDescriptors);
                rs_wr(p, range_at + 8,  dr->BaseShaderRegister);
                rs_wr(p, range_at + 12, dr->RegisterSpace);
                rs_wr(p, range_at + 16, (UINT32)dr->Flags);
                rs_wr(p, range_at + 20, dr->OffsetInDescriptorsFromTableStart);
                range_at += 24;
            }
            body += 8;
        } else {
            rs_wr(p, body,     rp->Descriptor.ShaderRegister);
            rs_wr(p, body + 4, rp->Descriptor.RegisterSpace);
            rs_wr(p, body + 8, (UINT32)rp->Descriptor.Flags);
            body += 12;
        }
    }
    *io_len = total;
    return S_OK;
}

/* ---- ml1980: root signature deserializers ---------------------------------
 * D3D12CreateRootSignatureDeserializer and its versioned sibling turn a
 * serialized root signature back into a description. An engine may run every
 * blob through one before CreateRootSignature, so the old E_NOTIMPL meant no
 * pipeline was ever created. The reader follows device_CreateRootSignature's
 * rules -- the same chunk lookup, version check, range stride and bounds --
 * but fills the public D3D12 structures instead of the converter's.
 *
 * Both description versions are built once, at creation, each in one heap
 * block the object owns. Every pointer handed out therefore stays valid until
 * the last Release, and no method allocates or races another thread.
 *
 * Converting 1.0 up to 1.1 uses the flags D3D12 defines as 1.0's behaviour:
 * ranges DESCRIPTORS_VOLATILE (plus DATA_VOLATILE unless they hold samplers),
 * root descriptors DATA_VOLATILE. Converting 1.1 down to 1.0 drops the flags.
 * MADEIRA_D3D12_RS_DESERIALIZER=0 restores the old E_NOTIMPL. */
struct mad_rsd {
    union {
        const ID3D12RootSignatureDeserializerVtbl *plain;
        const ID3D12VersionedRootSignatureDeserializerVtbl *versioned;
    } vtbl;
    LONG refs;
    int versioned;                        /* which of the two interfaces this is */
    D3D_ROOT_SIGNATURE_VERSION native;    /* the version the blob declared */
    D3D12_VERSIONED_ROOT_SIGNATURE_DESC *v10, *v11;
    UINT32 nranges;
};

static LONG g_rsd_refusals;
#define RSD_REFUSE(...) do { \
        if (InterlockedIncrement(&g_rsd_refusals) <= 8) d3d12_log(__VA_ARGS__); } while (0)
#define RSD_ALIGN8(x) (((SIZE_T)(x) + 7) & ~(SIZE_T)7)

/* One block per version: the header, then the parameters, ranges and static
 * samplers. Empty arrays get NULL pointers, as the D3D12 runtime hands out. */
static D3D12_VERSIONED_ROOT_SIGNATURE_DESC *rsd_alloc(int v11, UINT32 np, UINT32 nr, UINT32 ns,
        void **params, void **ranges, D3D12_STATIC_SAMPLER_DESC **samplers) {
    SIZE_T psz = v11 ? sizeof(D3D12_ROOT_PARAMETER1) : sizeof(D3D12_ROOT_PARAMETER);
    SIZE_T rsz = v11 ? sizeof(D3D12_DESCRIPTOR_RANGE1) : sizeof(D3D12_DESCRIPTOR_RANGE);
    SIZE_T at_p = RSD_ALIGN8(sizeof(D3D12_VERSIONED_ROOT_SIGNATURE_DESC));
    SIZE_T at_r = RSD_ALIGN8(at_p + psz * np);
    SIZE_T at_s = RSD_ALIGN8(at_r + rsz * nr);
    char *b = calloc(1, at_s + sizeof(D3D12_STATIC_SAMPLER_DESC) * ns);
    D3D12_VERSIONED_ROOT_SIGNATURE_DESC *v = (D3D12_VERSIONED_ROOT_SIGNATURE_DESC *)b;
    if (!b) return NULL;
    *params = np ? (void *)(b + at_p) : NULL;
    *ranges = nr ? (void *)(b + at_r) : NULL;
    *samplers = ns ? (D3D12_STATIC_SAMPLER_DESC *)(b + at_s) : NULL;
    if (v11) {
        v->Version = D3D_ROOT_SIGNATURE_VERSION_1_1;
        v->Desc_1_1.NumParameters = np;
        v->Desc_1_1.pParameters = *params;
        v->Desc_1_1.NumStaticSamplers = ns;
        v->Desc_1_1.pStaticSamplers = *samplers;
    } else {
        v->Version = D3D_ROOT_SIGNATURE_VERSION_1_0;
        v->Desc_1_0.NumParameters = np;
        v->Desc_1_0.pParameters = *params;
        v->Desc_1_0.NumStaticSamplers = ns;
        v->Desc_1_0.pStaticSamplers = *samplers;
    }
    return v;
}

/* Parses the blob into o->v11 (1.0 blobs get 1.0's flags), then derives
 * o->v10 from it. On failure the caller frees whatever was allocated. */
static HRESULT rsd_parse(const void *blob, SIZE_T blob_len, struct mad_rsd *o) {
    SIZE_T n = 0;
    const char *why = "?";
    const unsigned char *p = rs_find_chunk((const unsigned char *)blob, blob_len, &n, &why);
    UINT32 version, nparam, poff, nsampler, soff, flags, total_ranges = 0, used = 0, i, j;
    D3D12_ROOT_PARAMETER1 *p11; D3D12_DESCRIPTOR_RANGE1 *r11; D3D12_STATIC_SAMPLER_DESC *s11;
    D3D12_ROOT_PARAMETER *p10;  D3D12_DESCRIPTOR_RANGE *r10;  D3D12_STATIC_SAMPLER_DESC *s10;
    void *vp, *vr;
    int bad = 0;

    if (!p) { RSD_REFUSE("[d3d12-rsdeser] %s -- refusing\n", why); return E_INVALIDARG; }
    version  = rs_rd(p, n, 0,  &bad);
    nparam   = rs_rd(p, n, 4,  &bad);
    poff     = rs_rd(p, n, 8,  &bad);
    nsampler = rs_rd(p, n, 12, &bad);
    soff     = rs_rd(p, n, 16, &bad);
    flags    = rs_rd(p, n, 20, &bad);
    if (bad) { RSD_REFUSE("[d3d12-rsdeser] truncated RTS0 header\n"); return E_INVALIDARG; }
    if (version == 3) {   /* 1.2 adds a flags word per static sampler; not read here */
        RSD_REFUSE("[d3d12-rsdeser] root signature version 1.2 is not supported\n");
        return E_NOTIMPL;
    }
    if (version != 1 && version != 2) {
        RSD_REFUSE("[d3d12-rsdeser] unknown root signature version %u\n", version);
        return E_INVALIDARG;
    }
    if (nsampler > 32) {
        RSD_REFUSE("[d3d12-rsdeser] %u static samplers exceeds the 32 this build handles\n", nsampler);
        return E_NOTIMPL;
    }
    if (nparam > MAD_ROOT_PARAM_MAX) {
        RSD_REFUSE("[d3d12-rsdeser] %u parameters exceeds the %u this build handles\n",
                   nparam, (unsigned)MAD_ROOT_PARAM_MAX);
        return E_NOTIMPL;
    }
    /* Pre-pass: validate the parameter headers and count the ranges, so the
     * blocks are sized to this blob and a corrupt count cannot become a huge
     * allocation. */
    for (i = 0; i < nparam; i++) {
        UINT32 type = rs_rd(p, n, (SIZE_T)poff + 12 * i,     &bad);
        UINT32 off  = rs_rd(p, n, (SIZE_T)poff + 12 * i + 8, &bad);
        UINT32 nr;
        if (bad) { RSD_REFUSE("[d3d12-rsdeser] RTS0 chunk is truncated\n"); return E_INVALIDARG; }
        if (type > D3D12_ROOT_PARAMETER_TYPE_UAV) {
            RSD_REFUSE("[d3d12-rsdeser] unknown root parameter type %u\n", type);
            return E_INVALIDARG;
        }
        if (type != D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) continue;
        nr = rs_rd(p, n, off, &bad);
        if (bad) { RSD_REFUSE("[d3d12-rsdeser] RTS0 chunk is truncated\n"); return E_INVALIDARG; }
        if (nr > MAD_ROOT_RANGE_SANE || total_ranges + nr > MAD_ROOT_RANGE_SANE) {
            RSD_REFUSE("[d3d12-rsdeser] implausible descriptor range count "
                       "(parameter %u asks for %u, running total %u, sane bound %u)\n",
                       i, nr, total_ranges, (unsigned)MAD_ROOT_RANGE_SANE);
            return E_NOTIMPL;
        }
        total_ranges += nr;
    }

    o->v11 = rsd_alloc(1, nparam, total_ranges, nsampler, &vp, &vr, &s11);
    if (!o->v11) return E_OUTOFMEMORY;
    p11 = vp; r11 = vr;
    o->v11->Desc_1_1.Flags = (D3D12_ROOT_SIGNATURE_FLAGS)flags;
    for (i = 0; i < nparam; i++) {
        UINT32 type = rs_rd(p, n, (SIZE_T)poff + 12 * i,     &bad);
        UINT32 vis  = rs_rd(p, n, (SIZE_T)poff + 12 * i + 4, &bad);
        UINT32 off  = rs_rd(p, n, (SIZE_T)poff + 12 * i + 8, &bad);
        D3D12_ROOT_PARAMETER1 *q = &p11[i];
        if (bad) goto truncated;
        if (vis > D3D12_SHADER_VISIBILITY_MESH) {
            RSD_REFUSE("[d3d12-rsdeser] unknown shader visibility %u\n", vis);
            return E_INVALIDARG;
        }
        q->ParameterType = (D3D12_ROOT_PARAMETER_TYPE)type;
        q->ShaderVisibility = (D3D12_SHADER_VISIBILITY)vis;
        switch (type) {
        case D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS:
            q->Constants.ShaderRegister = rs_rd(p, n, off,     &bad);
            q->Constants.RegisterSpace  = rs_rd(p, n, off + (SIZE_T)4, &bad);
            q->Constants.Num32BitValues = rs_rd(p, n, off + (SIZE_T)8, &bad);
            break;
        case D3D12_ROOT_PARAMETER_TYPE_CBV:
        case D3D12_ROOT_PARAMETER_TYPE_SRV:
        case D3D12_ROOT_PARAMETER_TYPE_UAV:
            /* 1.0 root descriptors are two words; 1.1 adds the flags word. */
            q->Descriptor.ShaderRegister = rs_rd(p, n, off,     &bad);
            q->Descriptor.RegisterSpace  = rs_rd(p, n, off + (SIZE_T)4, &bad);
            q->Descriptor.Flags = version == 2
                ? (D3D12_ROOT_DESCRIPTOR_FLAGS)rs_rd(p, n, off + (SIZE_T)8, &bad)
                : D3D12_ROOT_DESCRIPTOR_FLAG_DATA_VOLATILE;
            break;
        default: {   /* descriptor table; the pre-pass refused anything else */
            UINT32 nr   = rs_rd(p, n, off,     &bad);
            UINT32 roff = rs_rd(p, n, off + (SIZE_T)4, &bad);
            UINT32 stride = (version == 2) ? 24 : 20;   /* same rule as CreateRootSignature */
            if (bad) goto truncated;
            if (used + nr > total_ranges) {   /* our bug if it trips: the pre-pass read the same words */
                RSD_REFUSE("[d3d12-rsdeser] range count disagrees with the pre-pass (%u + %u > %u)\n",
                           used, nr, total_ranges);
                return E_INVALIDARG;
            }
            q->DescriptorTable.NumDescriptorRanges = nr;
            q->DescriptorTable.pDescriptorRanges = nr ? r11 + used : NULL;
            for (j = 0; j < nr; j++) {
                D3D12_DESCRIPTOR_RANGE1 *rg = &r11[used + j];
                SIZE_T b0 = (SIZE_T)roff + (SIZE_T)stride * j;
                UINT32 rt = rs_rd(p, n, b0, &bad);
                if (bad) goto truncated;
                if (rt > D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER) {
                    RSD_REFUSE("[d3d12-rsdeser] unknown descriptor range type %u\n", rt);
                    return E_INVALIDARG;
                }
                rg->RangeType          = (D3D12_DESCRIPTOR_RANGE_TYPE)rt;
                rg->NumDescriptors     = rs_rd(p, n, b0 + 4,  &bad);
                rg->BaseShaderRegister = rs_rd(p, n, b0 + 8,  &bad);
                rg->RegisterSpace      = rs_rd(p, n, b0 + 12, &bad);
                if (stride == 24) {
                    rg->Flags = (D3D12_DESCRIPTOR_RANGE_FLAGS)rs_rd(p, n, b0 + 16, &bad);
                    rg->OffsetInDescriptorsFromTableStart = rs_rd(p, n, b0 + 20, &bad);
                } else {
                    rg->Flags = rt == D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER
                        ? D3D12_DESCRIPTOR_RANGE_FLAG_DESCRIPTORS_VOLATILE
                        : (D3D12_DESCRIPTOR_RANGE_FLAGS)(D3D12_DESCRIPTOR_RANGE_FLAG_DESCRIPTORS_VOLATILE |
                                                         D3D12_DESCRIPTOR_RANGE_FLAG_DATA_VOLATILE);
                    rg->OffsetInDescriptorsFromTableStart = rs_rd(p, n, b0 + 16, &bad);
                }
            }
            used += nr;
            break;
        }
        }
        if (bad) goto truncated;
    }
    /* Static samplers: thirteen words, the same in 1.0 and 1.1. */
    for (i = 0; i < nsampler; i++) {
        D3D12_STATIC_SAMPLER_DESC *ss = &s11[i];
        SIZE_T at = (SIZE_T)soff + 52 * (SIZE_T)i;
        UINT32 w[13], k;
        for (k = 0; k < 13; k++) w[k] = rs_rd(p, n, at + 4 * k, &bad);
        if (bad) goto truncated;
        ss->Filter = (D3D12_FILTER)w[0];
        ss->AddressU = (D3D12_TEXTURE_ADDRESS_MODE)w[1];
        ss->AddressV = (D3D12_TEXTURE_ADDRESS_MODE)w[2];
        ss->AddressW = (D3D12_TEXTURE_ADDRESS_MODE)w[3];
        memcpy(&ss->MipLODBias, &w[4], 4);
        ss->MaxAnisotropy = w[5];
        ss->ComparisonFunc = (D3D12_COMPARISON_FUNC)w[6];
        ss->BorderColor = (D3D12_STATIC_BORDER_COLOR)w[7];
        memcpy(&ss->MinLOD, &w[8], 4);
        memcpy(&ss->MaxLOD, &w[9], 4);
        ss->ShaderRegister = w[10];
        ss->RegisterSpace = w[11];
        ss->ShaderVisibility = (D3D12_SHADER_VISIBILITY)w[12];
    }

    /* The 1.0 view: the same description without the flags. */
    o->v10 = rsd_alloc(0, nparam, total_ranges, nsampler, &vp, &vr, &s10);
    if (!o->v10) return E_OUTOFMEMORY;
    p10 = vp; r10 = vr;
    o->v10->Desc_1_0.Flags = (D3D12_ROOT_SIGNATURE_FLAGS)flags;
    for (i = 0; i < nparam; i++) {
        const D3D12_ROOT_PARAMETER1 *q = &p11[i];
        D3D12_ROOT_PARAMETER *d = &p10[i];
        d->ParameterType = q->ParameterType;
        d->ShaderVisibility = q->ShaderVisibility;
        switch (q->ParameterType) {
        case D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS:
            d->Constants = q->Constants;
            break;
        case D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE: {
            UINT32 nr = q->DescriptorTable.NumDescriptorRanges;
            SIZE_T at = nr ? (SIZE_T)(q->DescriptorTable.pDescriptorRanges - r11) : 0;
            d->DescriptorTable.NumDescriptorRanges = nr;
            d->DescriptorTable.pDescriptorRanges = nr ? r10 + at : NULL;
            for (j = 0; j < nr; j++) {
                const D3D12_DESCRIPTOR_RANGE1 *a = &r11[at + j];
                D3D12_DESCRIPTOR_RANGE *b = &r10[at + j];
                b->RangeType = a->RangeType;
                b->NumDescriptors = a->NumDescriptors;
                b->BaseShaderRegister = a->BaseShaderRegister;
                b->RegisterSpace = a->RegisterSpace;
                b->OffsetInDescriptorsFromTableStart = a->OffsetInDescriptorsFromTableStart;
            }
            break;
        }
        default:
            d->Descriptor.ShaderRegister = q->Descriptor.ShaderRegister;
            d->Descriptor.RegisterSpace = q->Descriptor.RegisterSpace;
            break;
        }
    }
    if (nsampler) memcpy(s10, s11, sizeof *s10 * nsampler);

    o->native = version == 2 ? D3D_ROOT_SIGNATURE_VERSION_1_1 : D3D_ROOT_SIGNATURE_VERSION_1_0;
    o->nranges = total_ranges;
    return S_OK;

truncated:
    RSD_REFUSE("[d3d12-rsdeser] RTS0 chunk is truncated\n");
    return E_INVALIDARG;
}

static ULONG rsd_addref(struct mad_rsd *o) { return (ULONG)InterlockedIncrement(&o->refs); }
static ULONG rsd_release(struct mad_rsd *o) {
    LONG n = InterlockedDecrement(&o->refs);
    if (n == 0) { free(o->v10); free(o->v11); free(o); }
    return (ULONG)n;
}
static HRESULT rsd_qi(struct mad_rsd *o, REFIID riid, void **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (!riid) return E_INVALIDARG;
    if (IsEqualGUID(riid, &IID_IUnknown) ||
        IsEqualGUID(riid, o->versioned ? &IID_ID3D12VersionedRootSignatureDeserializer
                                       : &IID_ID3D12RootSignatureDeserializer)) {
        rsd_addref(o); *out = o; return S_OK;
    }
    return E_NOINTERFACE;
}

static HRESULT STDMETHODCALLTYPE rsd0_QI(ID3D12RootSignatureDeserializer *T, REFIID riid, void **out) {
    return rsd_qi((struct mad_rsd *)T, riid, out);
}
static ULONG STDMETHODCALLTYPE rsd0_AddRef(ID3D12RootSignatureDeserializer *T) { return rsd_addref((struct mad_rsd *)T); }
static ULONG STDMETHODCALLTYPE rsd0_Release(ID3D12RootSignatureDeserializer *T) { return rsd_release((struct mad_rsd *)T); }
static const D3D12_ROOT_SIGNATURE_DESC * STDMETHODCALLTYPE rsd0_GetRootSignatureDesc(ID3D12RootSignatureDeserializer *T) {
    return &((struct mad_rsd *)T)->v10->Desc_1_0;
}
static const ID3D12RootSignatureDeserializerVtbl g_rsd0_vtbl = {
    rsd0_QI, rsd0_AddRef, rsd0_Release, rsd0_GetRootSignatureDesc,
};

static HRESULT STDMETHODCALLTYPE rsdv_QI(ID3D12VersionedRootSignatureDeserializer *T, REFIID riid, void **out) {
    return rsd_qi((struct mad_rsd *)T, riid, out);
}
static ULONG STDMETHODCALLTYPE rsdv_AddRef(ID3D12VersionedRootSignatureDeserializer *T) { return rsd_addref((struct mad_rsd *)T); }
static ULONG STDMETHODCALLTYPE rsdv_Release(ID3D12VersionedRootSignatureDeserializer *T) { return rsd_release((struct mad_rsd *)T); }
static HRESULT STDMETHODCALLTYPE rsdv_GetRootSignatureDescAtVersion(ID3D12VersionedRootSignatureDeserializer *T,
        D3D_ROOT_SIGNATURE_VERSION version, const D3D12_VERSIONED_ROOT_SIGNATURE_DESC **desc) {
    struct mad_rsd *o = (struct mad_rsd *)T;
    if (!desc) return E_INVALIDARG;
    if (version == D3D_ROOT_SIGNATURE_VERSION_1_0) { *desc = o->v10; return S_OK; }
    if (version == D3D_ROOT_SIGNATURE_VERSION_1_1) { *desc = o->v11; return S_OK; }
    *desc = NULL;
    RSD_REFUSE("[d3d12-rsdeser] conversion to root signature version %#x is not supported\n", (unsigned)version);
    return E_INVALIDARG;
}
static const D3D12_VERSIONED_ROOT_SIGNATURE_DESC * STDMETHODCALLTYPE rsdv_GetUnconvertedRootSignatureDesc(
        ID3D12VersionedRootSignatureDeserializer *T) {
    struct mad_rsd *o = (struct mad_rsd *)T;
    return o->native == D3D_ROOT_SIGNATURE_VERSION_1_1 ? o->v11 : o->v10;
}
static const ID3D12VersionedRootSignatureDeserializerVtbl g_rsdv_vtbl = {
    rsdv_QI, rsdv_AddRef, rsdv_Release, rsdv_GetRootSignatureDescAtVersion, rsdv_GetUnconvertedRootSignatureDesc,
};

/* Read once. The switch exists so a device regression can be separated from
 * this path without a rebuild. */
static int mad_rsd_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        char v[4] = {0};
        DWORD n = GetEnvironmentVariableA("MADEIRA_D3D12_RS_DESERIALIZER", v, sizeof v);
        enabled = !(n == 1 && v[0] == '0');
        if (!enabled) d3d12_log("[d3d12-rsdeser] ml1980 deserializer disabled (rollback)\n");
    }
    return enabled;
}

/* Shared body of both exports. */
static HRESULT mad_rsd_create(const void *blob, SIZE_T n, REFIID riid, void **out, int versioned) {
    struct mad_rsd *o;
    HRESULT hr;
    if (!mad_rsd_enabled()) {
        if (out) *out = NULL;
        d3d12_log(versioned ? "[madeira-d3d12] D3D12CreateVersionedRootSignatureDeserializer: not implemented\n"
                            : "[madeira-d3d12] D3D12CreateRootSignatureDeserializer: not implemented\n");
        return E_NOTIMPL;
    }
    if (!out) return E_POINTER;
    *out = NULL;
    if (!riid || !blob || !n) return E_INVALIDARG;
    o = calloc(1, sizeof *o);
    if (!o) return E_OUTOFMEMORY;
    o->refs = 1;
    o->versioned = versioned;
    if (versioned) o->vtbl.versioned = &g_rsdv_vtbl;
    else           o->vtbl.plain = &g_rsd0_vtbl;
    hr = rsd_parse(blob, n, o);
    if (FAILED(hr)) { rsd_release(o); return hr; }
    {
        static LONG said;
        const D3D12_ROOT_SIGNATURE_DESC1 *d = &o->v11->Desc_1_1;
        if (InterlockedIncrement(&said) <= 8)
            d3d12_log("[d3d12-rsdeser] ml1980 version=1.%u params=%u ranges=%u samplers=%u\n",
                      o->native == D3D_ROOT_SIGNATURE_VERSION_1_1 ? 1u : 0u,
                      d->NumParameters, o->nranges, d->NumStaticSamplers);
    }
    hr = rsd_qi(o, riid, out);
    rsd_release(o);
    return hr;
}
/* rsdeser-test:end */

static HRESULT STDMETHODCALLTYPE device_CreateDescriptorHeap(ID3D12Device *This,
        const D3D12_DESCRIPTOR_HEAP_DESC *desc, REFIID riid, void **out) {
    if (!desc || !out) return E_INVALIDARG;
    struct mad_device *d = (struct mad_device *)This;
    int shader_visible = (desc->Type == D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV ||
                          desc->Type == D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
    if (!shader_visible &&
        desc->Type != D3D12_DESCRIPTOR_HEAP_TYPE_RTV &&
        desc->Type != D3D12_DESCRIPTOR_HEAP_TYPE_DSV) {
        d3d12_log("[madeira-d3d12] CreateDescriptorHeap: type %u is not supported\n", desc->Type);
        return E_NOTIMPL;
    }
    struct mad_heap *h = calloc(1, sizeof *h);
    if (!h) return E_OUTOFMEMORY;
    h->vtbl = &g_heap_vtbl; h->refs = 1; h->iid = &IID_ID3D12DescriptorHeap; h->name = "DescriptorHeap";
    h->type = desc->Type; h->count = desc->NumDescriptors; h->owner = d;
    h->desc = *desc;
    h->shader_visible = shader_visible && (desc->Flags & D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE);
    {
        static unsigned said;
        if (said < 24) {
            said++;
            d3d12_log("[madeira-d3d12] descriptor heap: type %u, %u descriptors, %s\n",
                      (unsigned)desc->Type, desc->NumDescriptors, h->shader_visible ? "shader-visible" : "CPU only");
        }
    }
    if (!shader_visible) {
        h->slots = calloc(desc->NumDescriptors ? desc->NumDescriptors : 1, sizeof *h->slots);
        if (!h->slots) { free(h); return E_OUTOFMEMORY; }
    } else if (!h->shader_visible) {
        /* A staging heap: the application writes views here and copies them
         * into a shader-visible heap. Plain memory, same 24-byte entries. */
        h->cpu = calloc(desc->NumDescriptors ? desc->NumDescriptors : 1, sizeof *h->cpu);
        if (!h->cpu) { free(h); return E_OUTOFMEMORY; }
    } else {
        /* A shader-visible heap IS a Metal buffer: the shader indexes it
         * directly, and a descriptor table root argument is the address of one
         * of its entries. Shared storage so views can be written from the CPU
         * without a staging copy. */
        struct WMTBufferInfo bi;
        memset(&bi, 0, sizeof bi);
        bi.length = (uint64_t)sizeof(struct mad_descriptor) * (desc->NumDescriptors ? desc->NumDescriptors : 1);
        bi.options = WMTResourceStorageModeShared;
        h->buffer = MTLDevice_newBuffer(d->mtl_device, &bi);
        if (!h->buffer) { free(h); return mad_creation_failure(d, "descriptor heap buffer"); }
        h->cpu = (struct mad_descriptor *)bi.memory.ptr;
        h->gpu_address = bi.gpu_address;
        if (h->cpu) memset(h->cpu, 0, (size_t)bi.length);
    }
    HRESULT hr = heap_QI((ID3D12DescriptorHeap *)h, riid, out);
    heap_Release((ID3D12DescriptorHeap *)h);
    return hr;
}

static void STDMETHODCALLTYPE device_CreateDepthStencilView(ID3D12Device *This,
        ID3D12Resource *res, const D3D12_DEPTH_STENCIL_VIEW_DESC *desc,
        D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_rtv *v = (struct mad_rtv *)h.ptr; struct mad_resource *r = (struct mad_resource *)res;
    static unsigned said;
    (void)This;
    if (!v) return;
    v->res = r; v->p.level = 0; v->p.slice = 0; v->p.plane = 0; v->p.layers = 1;
    if (!r) return;
    if (!desc) { mad_view_all(r, &v->p, 0, (UINT)-1, 0); }
    else switch (desc->ViewDimension) {   /* ml925 */
    case D3D12_DSV_DIMENSION_TEXTURE1D: v->p.level = (UINT16)desc->Texture1D.MipSlice; break;
    case D3D12_DSV_DIMENSION_TEXTURE2D: v->p.level = (UINT16)desc->Texture2D.MipSlice; break;
    case D3D12_DSV_DIMENSION_TEXTURE1DARRAY: v->p.level = (UINT16)desc->Texture1DArray.MipSlice; mad_view_all(r, &v->p, desc->Texture1DArray.FirstArraySlice, desc->Texture1DArray.ArraySize, 0); break;
    case D3D12_DSV_DIMENSION_TEXTURE2DARRAY: v->p.level = (UINT16)desc->Texture2DArray.MipSlice; mad_view_all(r, &v->p, desc->Texture2DArray.FirstArraySlice, desc->Texture2DArray.ArraySize, 0); break;
    case D3D12_DSV_DIMENSION_TEXTURE2DMSARRAY: mad_view_all(r, &v->p, desc->Texture2DMSArray.FirstArraySlice, desc->Texture2DMSArray.ArraySize, 0); break;
    default: break;
    }
    if (v->p.layers > 1 && said++ < 6)
        d3d12_log("[madeira-d3d12] layered DSV: %s %ux%u level %u first %u layers %u\n", r->name, r->width, r->height, v->p.level, v->p.slice, v->p.layers);
}

static void mad_view_all(struct mad_resource *r, struct mad_rtvp *p, UINT first, UINT count, int is3d) {
    UINT total = r ? (is3d ? (r->tex_depth >> p->level) : r->tex_layers) : 1;
    if (!total) total = 1;
    if (count == (UINT)-1 || first + count > total) count = total > first ? total - first : 1;
    if (!count) count = 1;
    if (is3d) p->plane = (UINT16)first; else p->slice = (UINT16)first;
    p->layers = (UINT16)count;
}
static void STDMETHODCALLTYPE device_CreateRenderTargetView(ID3D12Device *This,
        ID3D12Resource *res, const D3D12_RENDER_TARGET_VIEW_DESC *desc,
        D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_rtv *v = (struct mad_rtv *)h.ptr; struct mad_resource *r = (struct mad_resource *)res;
    static unsigned said;
    (void)This;
    if (!v) return;
    v->res = r; v->p.level = 0; v->p.slice = 0; v->p.plane = 0; v->p.layers = 1;
    if (!r) return;
    if (!desc) { mad_view_all(r, &v->p, 0, (UINT)-1, r->tex_type == WMTTextureType3D); }
    else switch (desc->ViewDimension) {   /* ml925 */
    case D3D12_RTV_DIMENSION_TEXTURE1D: v->p.level = (UINT16)desc->Texture1D.MipSlice; break;
    case D3D12_RTV_DIMENSION_TEXTURE2D: v->p.level = (UINT16)desc->Texture2D.MipSlice; break;
    case D3D12_RTV_DIMENSION_TEXTURE1DARRAY: v->p.level = (UINT16)desc->Texture1DArray.MipSlice; mad_view_all(r, &v->p, desc->Texture1DArray.FirstArraySlice, desc->Texture1DArray.ArraySize, 0); break;
    case D3D12_RTV_DIMENSION_TEXTURE2DARRAY: v->p.level = (UINT16)desc->Texture2DArray.MipSlice; mad_view_all(r, &v->p, desc->Texture2DArray.FirstArraySlice, desc->Texture2DArray.ArraySize, 0); break;
    case D3D12_RTV_DIMENSION_TEXTURE2DMSARRAY: mad_view_all(r, &v->p, desc->Texture2DMSArray.FirstArraySlice, desc->Texture2DMSArray.ArraySize, 0); break;
    case D3D12_RTV_DIMENSION_TEXTURE3D: v->p.level = (UINT16)desc->Texture3D.MipSlice; mad_view_all(r, &v->p, desc->Texture3D.FirstWSlice, desc->Texture3D.WSize, 1); break;
    default: break;
    }
    if (v->p.layers > 1 && said++ < 6)
        d3d12_log("[madeira-d3d12] layered RTV: %s %ux%u t%u level %u first %u layers %u\n", r->name, r->width, r->height, (unsigned)r->tex_type,
                  v->p.level, r->tex_type == WMTTextureType3D ? v->p.plane : v->p.slice, v->p.layers);
}

static UINT STDMETHODCALLTYPE device_GetDescriptorHandleIncrementSize(ID3D12Device *This,
        D3D12_DESCRIPTOR_HEAP_TYPE type) {
    (void)This;
    return mad_descriptor_stride(type);
}

/* A texture descriptor. The encoding is the converter's
 * IRDescriptorTableSetTexture: the resource id in the second word, the min LOD
 * clamp in the low half of the third. */
static void STDMETHODCALLTYPE device_CreateShaderResourceView(ID3D12Device *This,
        ID3D12Resource *res, const D3D12_SHADER_RESOURCE_VIEW_DESC *desc,
        D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_resource *r = (struct mad_resource *)res;
    struct mad_descriptor *e = (struct mad_descriptor *)h.ptr;
    if (!e) return;
    if (!r) { memset(e, 0, sizeof *e); return; }                                /* a null view */
    if (r->buffer) {
        UINT64 stride = 4, first = 0, num = r->size / 4;
        if (desc && desc->ViewDimension == D3D12_SRV_DIMENSION_BUFFER) {
            UINT bytes, block;
            first = desc->Buffer.FirstElement; num = desc->Buffer.NumElements;
            if (desc->Buffer.StructureByteStride) stride = desc->Buffer.StructureByteStride;
            else if (desc->Format != DXGI_FORMAT_UNKNOWN) {
                mad_format_info(desc->Format, &bytes, &block); stride = bytes;
                if (!(desc->Buffer.Flags & D3D12_BUFFER_SRV_FLAG_RAW) &&
                    mad_typed_buffer_view((struct mad_device *)This, r, desc->Format, first, num, 0, e)) return;   /* ml905 */
            }
        }
        mad_set_buffer_descriptor(e, r->gpu_address + first * stride, num * stride);
        return;
    }
    if (!r->texture) {
        static int said;
        if (!said++) d3d12_log("[madeira-d3d12] CreateShaderResourceView: resource has no backend object; descriptor left empty\n");
        memset(e, 0, sizeof *e);
        return;
    }
    float min_lod = 0.0f;
    UINT32 lod_bits;
    UINT64 view_id = r->gpu_resource_id;
    enum WMTPixelFormat pf_used = 0; UINT swz_used = 0;   /* ml1089 */
    if (desc) {   /* ml913: honour the view dimension and sub-range */
        enum WMTTextureType want = r->tex_type; UINT lvl0 = 0, nlvl = ~0u, sl0 = 0, nsl = ~0u;
        switch (desc->ViewDimension) {
        case D3D12_SRV_DIMENSION_TEXTURE1D: want = WMTTextureType2DArray; lvl0 = desc->Texture1D.MostDetailedMip; nlvl = desc->Texture1D.MipLevels; nsl = 1; break;   /* ml932: arrays everywhere */
        case D3D12_SRV_DIMENSION_TEXTURE1DARRAY: want = WMTTextureType2DArray; lvl0 = desc->Texture1DArray.MostDetailedMip; nlvl = desc->Texture1DArray.MipLevels; sl0 = desc->Texture1DArray.FirstArraySlice; nsl = desc->Texture1DArray.ArraySize; break;
        case D3D12_SRV_DIMENSION_TEXTURE2D: want = WMTTextureType2DArray; lvl0 = desc->Texture2D.MostDetailedMip; nlvl = desc->Texture2D.MipLevels; nsl = 1; break;
        case D3D12_SRV_DIMENSION_TEXTURE2DARRAY: want = WMTTextureType2DArray; lvl0 = desc->Texture2DArray.MostDetailedMip; nlvl = desc->Texture2DArray.MipLevels; sl0 = desc->Texture2DArray.FirstArraySlice; nsl = desc->Texture2DArray.ArraySize; break;
        case D3D12_SRV_DIMENSION_TEXTURE2DMS: want = WMTTextureType2DMultisampleArray; nsl = 1; break;
        case D3D12_SRV_DIMENSION_TEXTURE2DMSARRAY: want = WMTTextureType2DMultisampleArray; sl0 = desc->Texture2DMSArray.FirstArraySlice; nsl = desc->Texture2DMSArray.ArraySize; break;
        case D3D12_SRV_DIMENSION_TEXTURE3D: want = WMTTextureType3D; lvl0 = desc->Texture3D.MostDetailedMip; nlvl = desc->Texture3D.MipLevels; break;
        case D3D12_SRV_DIMENSION_TEXTURECUBE: want = WMTTextureTypeCubeArray; lvl0 = desc->TextureCube.MostDetailedMip; nlvl = desc->TextureCube.MipLevels; nsl = 6; break;
        case D3D12_SRV_DIMENSION_TEXTURECUBEARRAY: want = WMTTextureTypeCubeArray; lvl0 = desc->TextureCubeArray.MostDetailedMip; nlvl = desc->TextureCubeArray.MipLevels; sl0 = desc->TextureCubeArray.First2DArrayFace; nsl = desc->TextureCubeArray.NumCubes * 6; break;
        default: break;
        }
        if (r->tex_type == WMTTextureType2DMultisample || r->tex_type == WMTTextureType2DMultisampleArray) { lvl0 = 0; nlvl = 1; }
        {   /* ml918: the view's format (typeless -> typed, sRGB/linear) and Shader4ComponentMapping */
            enum WMTPixelFormat pf = 0; int vd = 0, stencil_view = 0; UINT swz = 0, c, m = desc->Shader4ComponentMapping;
            if (desc->Format != DXGI_FORMAT_UNKNOWN && !r->is_depth && mad_map_texture_format(desc->Format, 0, &pf, &vd) && !vd && pf != r->tex_pf) { /* keep pf */ } else pf = 0;
            /* ml1101: a STENCIL shader view (X24_TYPELESS_G8 / X32_TYPELESS_G8X24) of a
             * depth-stencil texture. It used to stay a depth view, so a shader
             * sampling a stencil mask read depth. Metal returns the stencil in R;
             * D3D returns it in G, hence the swizzle (Astra, ph-rdr54 review). */
            if (r->is_depth && r->has_stencil &&
                (desc->Format == DXGI_FORMAT_X32_TYPELESS_G8X24_UINT || desc->Format == DXGI_FORMAT_X24_TYPELESS_G8_UINT)) {
                pf = WMTPixelFormatX32_Stencil8; stencil_view = 1;
                if (InterlockedIncrement(&g_stencil_srv) <= 4) d3d12_log("[madeira-d3d12] ml1101 stencil SRV on %s %ux%u (X32_Stencil8 view, stencil in G)\n", r->name, r->width, r->height);
            }
            for (c = 0; c < 4; c++) {
                UINT sel = (m >> (3 * c)) & 7, v;   /* 0-3 = component, 4 = force 0, 5 = force 1 */
                v = sel <= 3 ? 2 + sel : sel == 4 ? 0 : 1;
                if (stencil_view) v = sel == 1 ? 2 : (sel == 3 || sel == 5) ? 1 : 0;   /* G <- Metal's R; the rest 0, A = 1 */
                swz |= v << (8 * c);
            }
            view_id = mad_texture_view_id((struct mad_device *)This, r, want, lvl0, nlvl, sl0, nsl, pf, swz);
            pf_used = pf; swz_used = swz;   /* ml1089 */
        }
        switch (desc->ViewDimension) {   /* ml1089: every dimension carries the clamp */
        case D3D12_SRV_DIMENSION_TEXTURE1D: min_lod = desc->Texture1D.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURE1DARRAY: min_lod = desc->Texture1DArray.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURE2D: min_lod = desc->Texture2D.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURE2DARRAY: min_lod = desc->Texture2DArray.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURE3D: min_lod = desc->Texture3D.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURECUBE: min_lod = desc->TextureCube.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURECUBEARRAY: min_lod = desc->TextureCubeArray.ResourceMinLODClamp; break;
        default: break;
        }
        /* ml1089: ResourceMinLODClamp is how a D3D12 engine samples a texture
         * whose most detailed mips have NOT been streamed in yet: the SRV says
         * "never go below mip N", and is re-created with a smaller N as mips
         * arrive. Our descriptor carried the clamp in its metadata word, but the
         * DXBC backend never reads that word for sampling (DXMT's own D3D11 layer
         * always passes 0), so every streamed texture was sampled from mips the
         * game never filled: uninitialised heap memory (white / stale garbage) in
         * placed textures, zeros (alpha 0 -> cut out) in committed ones, changing
         * with the camera as the sampled mip changed. Folded into the VIEW instead:
         * the view's first mip becomes ceil(clamp). Implicit-LOD sampling is then
         * exactly the clamped result (LOD is computed against the view's base
         * level); only explicit mip indices see a shifted numbering. */
        if (min_lod > 0.0f) {
            UINT c = (UINT)(min_lod + 0.9999f);
            if (nlvl != ~0u && c >= nlvl) c = nlvl ? nlvl - 1 : 0;
            if (r->tex_mips && lvl0 + c >= r->tex_mips) c = r->tex_mips > lvl0 ? r->tex_mips - 1 - lvl0 : 0;
            if (c) {
                lvl0 += c;
                if (nlvl != ~0u) nlvl -= c;
                view_id = mad_texture_view_id((struct mad_device *)This, r, want, lvl0, nlvl, sl0, nsl, pf_used, swz_used);
                InterlockedIncrement(&g_srv_clamped);
                if (min_lod > g_srv_clamp_max) g_srv_clamp_max = min_lod;
            }
            min_lod = 0.0f;   /* absorbed by the view */
        }
    }
    memcpy(&lod_bits, &min_lod, sizeof lod_bits);
    e->gpu_va = 0;
    e->texture_view_id = view_id;
    e->metadata = (UINT64)lod_bits;

    mad_view_list_add((struct mad_device *)This, 0, r);
}

/* ml923: the full D3D12 sampler description -> Metal. D3D12_FILTER packs
 * mip (bit 0), mag (bit 2), min (bit 4), anisotropic (0x40) and comparison
 * (0x80). The previous mapping had no mipmapping, clamp-only addressing and
 * never a comparison function, which breaks tiling, shadow PCF and LOD. */
static void mad_sampler_info(struct WMTSamplerInfo *si, UINT filter, UINT au, UINT av, UINT aw, UINT aniso, UINT cmp, UINT border, float minlod, float maxlod) {
    /* D3D12_TEXTURE_ADDRESS_MODE: 1 wrap, 2 mirror, 3 clamp, 4 border, 5 mirror-once */
    static const enum WMTSamplerAddressMode am[6] = { WMTSamplerAddressModeClampToEdge, WMTSamplerAddressModeRepeat, WMTSamplerAddressModeMirrorRepeat,
                                                      WMTSamplerAddressModeClampToEdge, WMTSamplerAddressModeClampToBorderColor, WMTSamplerAddressModeMirrorClampToEdge };
    memset(si, 0, sizeof *si);
    si->min_filter = (filter & 0x10) ? WMTSamplerMinMagFilterLinear : WMTSamplerMinMagFilterNearest;
    si->mag_filter = (filter & 0x04) ? WMTSamplerMinMagFilterLinear : WMTSamplerMinMagFilterNearest;
    si->mip_filter = (filter & 0x01) ? WMTSamplerMipFilterLinear : WMTSamplerMipFilterNearest;
    if (filter & 0x40) { si->min_filter = si->mag_filter = WMTSamplerMinMagFilterLinear; si->mip_filter = WMTSamplerMipFilterLinear; }
    /* ml1093: Metal's s/t/r are D3D's U/V/W (x, y, z). This had U on r and W on t,
     * inert with symmetric modes, wrong for every sampler that wraps one axis and
     * clamps another (Astra; DXMT's D3D11 layer has it right). */
    si->s_address_mode = am[au < 6 ? au : 3]; si->t_address_mode = am[av < 6 ? av : 3]; si->r_address_mode = am[aw < 6 ? aw : 3];
    si->border_color = border == 2 ? WMTSamplerBorderColorOpaqueWhite : border == 1 ? WMTSamplerBorderColorOpaqueBlack : WMTSamplerBorderColorTransparentBlack;
    si->compare_function = (filter & 0x80) ? mad_compare((D3D12_COMPARISON_FUNC)cmp) : WMTCompareFunctionNever;
    si->lod_min_clamp = minlod; si->lod_max_clamp = maxlod > 1000.0f ? 1000.0f : maxlod;
    si->max_anisotroy = (filter & 0x40) ? (aniso ? aniso : 16) : 1;
    si->normalized_coords = true;
    si->support_argument_buffers = true;
}

static void STDMETHODCALLTYPE device_CreateSampler(ID3D12Device *This,
        const D3D12_SAMPLER_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE h) {
    struct mad_device *d = (struct mad_device *)This;
    struct mad_descriptor *e = (struct mad_descriptor *)h.ptr;
    if (!e) return;

    struct WMTSamplerInfo si;
    if (desc) {
        UINT border = (desc->BorderColor[0] > 0.5f) ? 2u : (desc->BorderColor[3] > 0.5f) ? 1u : 0u;
        mad_sampler_info(&si, desc->Filter, desc->AddressU, desc->AddressV, desc->AddressW, desc->MaxAnisotropy, desc->ComparisonFunc, border, desc->MinLOD, desc->MaxLOD);
    } else mad_sampler_info(&si, D3D12_FILTER_MIN_MAG_MIP_LINEAR, 3, 3, 3, 1, 0, 0, 0.0f, 1000.0f);

    obj_handle_t smp = MTLDevice_newSamplerState(d->mtl_device, &si);
    if (!smp || !si.gpu_resource_id) {
        d3d12_log("[madeira-d3d12] CreateSampler: the backend gave no argument-buffer sampler\n");
        memset(e, 0, sizeof *e);
        return;
    }
    /* IRDescriptorTableSetSampler: resource id first, LOD bias in the metadata. */
    float bias = desc ? desc->MipLODBias : 0.0f;
    UINT32 bias_bits;
    memcpy(&bias_bits, &bias, sizeof bias_bits);
    e->gpu_va = si.gpu_resource_id;
    e->texture_view_id = 0;
    e->metadata = (UINT64)bias_bits;
    /* The sampler object itself is kept alive by the device for the process's
     * life. Samplers are few and immutable, and tying one to a descriptor slot
     * that the application may overwrite would need a lifetime story that this
     * milestone does not have. */
    mad_note_sampler(d, smp);
}

/* ---- pipeline state -------------------------------------------------------
 *
 * RUNTIME CONVERSION. The DXIL the application supplied is converted here, on
 * this machine, by Apple's Metal Shader Converter, using the root signature the
 * application actually created. No shader is embedded in this DLL and no
 * bytecode is recognised by hash.
 *
 * The previous build matched supplied DXIL against preconverted libraries and
 * refused anything else. That proved the plumbing but could never run a shader
 * it had not been built with, so removing it -- not passing another test with
 * it in place -- is what makes this a translation layer.
 *
 * Conversion runs on the guest even when rendering is remote, because it is a
 * byte transform that touches no Metal object. What must follow the rendering
 * backend is the TARGET, and that is chosen from the real device below. */

/* The converter's own family values, from its header. Written out rather than
 * included because this side must not depend on the converter's headers. */
/* Read from metal_irconverter.h, not inferred. The first version of this block
 * was off by two on every entry, so asking for Apple9 actually asked for
 * Apple7. Nothing failed: every wrong value was still a valid enum member, so
 * the build simply targeted a lower family than intended. */
#define MAD_IR_FAMILY_APPLE6  1006
#define MAD_IR_FAMILY_APPLE7  1007
#define MAD_IR_FAMILY_APPLE8  1008
#define MAD_IR_FAMILY_APPLE9  1009
#define MAD_IR_FAMILY_METAL3  5001

/* Read from winemetal.h's WMTGPUFamily. These are a DIFFERENT numbering from
 * the converter's above, which is exactly why both are written out here. */
#define MAD_MTL_FAMILY_APPLE7 1007
#define MAD_MTL_FAMILY_APPLE8 1008
#define MAD_MTL_FAMILY_APPLE9 1009
#define MAD_MTL_FAMILY_MAC2   2002

/* One conversion target, decided ONCE from the device that will actually run
 * the shaders, then reused. The previous build compiled for both platforms and
 * kept whichever library the backend happened to accept; that hid which target
 * was live and would silently pick the wrong one the moment both loaded. */
struct mad_target {
    int resolved;
    uint32_t os;          /* madeira_ir_os */
    uint32_t family;      /* IRGPUFamily */
    char os_version[16];
};
static struct mad_target g_target;

static void mad_resolve_target(struct mad_device *d) {
    if (g_target.resolved) return;

    /* Everything here returns a plain integer. The first version asked the
     * device for its NAME, which is the documented ownership trap: winemetal's
     * LOCAL implementation returns `[device name]`, an autoreleased string we
     * do not own, while the REMOTE one returns a freshly allocated +1 string.
     * Releasing it was correct remotely and an over-release locally, and it
     * killed the A15 at teardown when the autorelease pool popped and released
     * an object that had already gone. The remote backend never showed it.
     *
     * So the platform is decided by a capability instead. Mac2 is reported by
     * Apple silicon Macs and by no iPhone, supportsFamily is routed to the host
     * in remote mode, and it hands back a bool rather than an object. */
    int is_mac = MTLDevice_supportsFamily(d->mtl_device, MAD_MTL_FAMILY_MAC2);
    int apple9 = MTLDevice_supportsFamily(d->mtl_device, MAD_MTL_FAMILY_APPLE9);
    int apple8 = MTLDevice_supportsFamily(d->mtl_device, MAD_MTL_FAMILY_APPLE8);
    int apple7 = MTLDevice_supportsFamily(d->mtl_device, MAD_MTL_FAMILY_APPLE7);

    if (is_mac) {
        g_target.os = MADEIRA_IR_OS_MACOS;
        g_target.family = MAD_IR_FAMILY_METAL3;
        snprintf(g_target.os_version, sizeof g_target.os_version, "15.0");
    } else {
        g_target.os = MADEIRA_IR_OS_IOS;
        g_target.family = apple9 ? MAD_IR_FAMILY_APPLE9
                        : apple8 ? MAD_IR_FAMILY_APPLE8
                        : apple7 ? MAD_IR_FAMILY_APPLE7
                                 : MAD_IR_FAMILY_APPLE6;
        /* ml1140: 18.0, not 17.0. The converter refuses atomics on
         * globallycoherent textures below iOS 18 ("IR contains unsupported
         * instruction: dx.op.atomicBinOp.i32 ... requires targeting macOS 15,
         * iOS 18, or later", IRErrorCodeUnsupportedInstruction = 7): a UE5 Lumen/
         * Nanite compute shader failed on the device and UE treated the failed
         * PSO as fatal. Every device this runtime targets runs iOS 26+. */
        snprintf(g_target.os_version, sizeof g_target.os_version, "18.0");
    }
    g_target.resolved = 1;
    d3d12_log("[madeira-d3d12] conversion target: %s, family %u, min %s "
              "(device reports mac2=%d apple9=%d apple8=%d apple7=%d)\n",
              g_target.os == MADEIRA_IR_OS_MACOS ? "macOS" : "iOS",
              g_target.family, g_target.os_version, is_mac, apple9, apple8, apple7);
}

static const char *mad_ir_status_name(uint32_t st) {
    switch (st) {
    case MADEIRA_IR_OK:               return "ok";
    case MADEIRA_IR_NO_DYLIB:         return "the shader converter could not be loaded";
    case MADEIRA_IR_NO_SYMBOL:        return "the shader converter is missing an entry point";
    case MADEIRA_IR_BAD_DXIL:         return "the converter rejected the bytecode";
    case MADEIRA_IR_BAD_ROOTSIG:      return "the converter rejected the root signature";
    case MADEIRA_IR_COMPILE_FAILED:   return "compile/link failed";
    case MADEIRA_IR_NO_METALLIB:      return "compiled but produced no library";
    case MADEIRA_IR_BUFFER_TOO_SMALL: return "output buffer too small";
    case MADEIRA_IR_EMPTY_ENTRY:      return "no such entry point (reflection returned an empty name)";
    case MADEIRA_IR_UNSUPPORTED:      return "a root parameter this build does not model";
    case MADEIRA_IR_NO_MEMORY:        return "out of memory";
    default:                          return "unknown";
    }
}

/* Convert one stage and build its MTLFunction. The metallib buffer is sized by
 * asking first, so a shader larger than any fixed guess still works. */
#define MAD_LOC_MAX 64
/* ml927: what a geometry-shader pipeline needs from the converter beyond the
 * plain conversion: emulation mode, the input topology, the input layout the
 * stage-in function is synthesized from (vertex stage), and the numbers
 * reflection reports back. */
struct mad_convert_opts {
    int gs_emulation; UINT topology;
    const struct madeira_ir_input_layout *layout;
    obj_handle_t *lib2_out;            /* the stage-in library (vertex stage with a layout) */
    UINT *vs_output_size, *gs_max_prims;
    char *name_out; size_t name_cap;   /* the converter's entry name, per call (g_last_entry is a shared global and
                                        * the engine creates pipelines from several threads at once) */
    struct mad_air_out *air;           /* ml1008: filled when the DXBC backend ran */
    /* ml1023: pixel-stage PSO facts, forwarded to the DXBC backend. */
    int ps_valid; UINT ps_sample_mask, ps_flags, ps_unorm_mask;
    /* ml1031: the vertex stage this pixel shader is paired with, so the backend
     * can zero-fill interpolants the vertex stage never writes. */
    const void *vs_bc; SIZE_T vs_bc_len;
    /* ml1083: tessellation. tess_stage 1 = object (dxil is the VS; hs+ds given),
     * 2 = mesh (dxil is the DS; hs given). air2 receives the hull's tables. */
    UINT tess_stage, tess_index_format;
    const void *hs_bc, *ds_bc; SIZE_T hs_bc_len, ds_bc_len;
    struct mad_air_out *air2;
    UINT *threads_per_patch, *max_potential, *out_prim;
    /* ml1147: DXBC geometry shaders. gs_stage 1 = object (dxil is the VS, gs_bc
     * the GS; tess_index_format carries the index format), 2 = mesh (dxil is the
     * GS, gs_bc the VS). */
    UINT gs_stage, gs_strip;
    const void *gs_bc; SIZE_T gs_bc_len;
};
static obj_handle_t mad_convert_stage_opts(struct mad_device *d, struct mad_rootsig *rs,
                                      const void *dxil, SIZE_T dxil_len, const char *entry,
                                      obj_handle_t *lib_out, const char *tag,
                                      struct madeira_ir_vs_input *vsin, unsigned vsin_cap, unsigned *vsin_n,
                                      UINT *tg_out, struct madeira_ir_loc *locs, unsigned *nlocs,
                                      const struct mad_convert_opts *o);
/* ml1990: the inputs of one conversion request, shared by the first call and
 * any retry so the two can never disagree about what is being converted. */
static void mad_fill_convert_inputs(struct madeira_ir_convert_args *a, struct mad_rootsig *rs,
                                    const void *dxil, SIZE_T dxil_len, const char *entry,
                                    const struct mad_convert_opts *o) {
    memset(a, 0, sizeof *a);
    a->dxil = (uint64_t)(uintptr_t)dxil;
    a->dxil_len = (uint64_t)dxil_len;
    a->entry_point = (uint64_t)(uintptr_t)entry;
    a->params = (uint64_t)(uintptr_t)(rs ? rs->params : NULL);
    a->num_params = rs ? rs->nparams : 0;
    a->ranges = (uint64_t)(uintptr_t)(rs ? rs->ranges : NULL);
    a->num_ranges = rs ? rs->nranges : 0;
    a->target_os = g_target.os;
    a->gpu_family = g_target.family;
    a->os_version = (uint64_t)(uintptr_t)g_target.os_version;
    a->samplers = (uint64_t)(uintptr_t)(rs ? rs->samplers : NULL);
    a->num_samplers = rs ? rs->nsamplers : 0;
    if (o) { a->gs_emulation = o->gs_emulation ? 1u : 0u; a->input_topology = o->topology; a->layout = (uint64_t)(uintptr_t)o->layout; }   /* ml927 */
    if (o && o->vs_bc && o->vs_bc_len) {   /* ml1031 */
        a->vs_bytecode = (uint64_t)(ULONG_PTR)o->vs_bc;
        a->vs_bytecode_len = (uint64_t)o->vs_bc_len;
    }
    if (o && o->ps_valid) {   /* ml1023 */
        a->ps_valid = 1; a->ps_sample_mask = o->ps_sample_mask;
        a->ps_flags = o->ps_flags; a->ps_unorm_output_mask = o->ps_unorm_mask;
    }
    if (o && o->air) {   /* ml1008 */
        a->out_air_ranges = (uint64_t)(uintptr_t)o->air->ranges;
        a->air_range_cap = MADEIRA_IR_AIR_RANGE_MAX;
    }
    if (o && o->tess_stage) {   /* ml1083 */
        a->tess_stage = o->tess_stage; a->tess_index_format = o->tess_index_format;
        a->hs_bytecode = (uint64_t)(ULONG_PTR)o->hs_bc; a->hs_bytecode_len = (uint64_t)o->hs_bc_len;
        a->ds_bytecode = (uint64_t)(ULONG_PTR)o->ds_bc; a->ds_bytecode_len = (uint64_t)o->ds_bc_len;
        if (o->air2) { a->out_air_ranges2 = (uint64_t)(uintptr_t)o->air2->ranges; a->air_range_cap2 = MADEIRA_IR_AIR_RANGE_MAX; }
    }
    if (o && o->gs_stage) {   /* ml1147 */
        a->gs_stage = o->gs_stage; a->gs_strip = o->gs_strip; a->tess_index_format = o->tess_index_format;
        a->gs_bytecode = (uint64_t)(ULONG_PTR)o->gs_bc; a->gs_bytecode_len = (uint64_t)o->gs_bc_len;
    }
}

/* ml1990: one conversion call instead of two. The size-then-fill protocol ran
 * the whole compiler for the size query and again for the fill (the DXIL path
 * had no cache to catch the second). A first buffer of four times the input
 * plus 64 KB holds nearly every metallib; a larger one reports its size and is
 * retried once, and the service keeps the finished result for that retry.
 * MADEIRA_D3D12_ONEPASS=0 restores size-then-fill (the service reads it too). */
static int mad_onepass_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        char v[4] = {0};
        DWORD n = GetEnvironmentVariableA("MADEIRA_D3D12_ONEPASS", v, sizeof v);
        enabled = !(n == 1 && v[0] == '0');
        d3d12_log(enabled ? "[d3d12-onepass] ml1990 single-call shader conversion enabled\n"
                          : "[d3d12-onepass] ml1990 single-call shader conversion disabled (rollback)\n");
    }
    return enabled;
}
static volatile LONG g_conv_calls, g_conv_retries; static volatile LONG64 g_conv_ticks;
static void mad_convert_note_time(LONG64 t0, int retried) {
    LONG n = InterlockedIncrement(&g_conv_calls);
    LONG r = retried ? InterlockedIncrement(&g_conv_retries) : g_conv_retries;
    LONG64 dt = mad_qpc() - t0;
    LONG64 ticks = InterlockedExchangeAdd64(&g_conv_ticks, dt) + dt;
    if (n == 1 || n == 16 || n == 64 || !(n % 128)) {
        static LONG64 qpf;
        if (!qpf) { LARGE_INTEGER f; QueryPerformanceFrequency(&f); qpf = f.QuadPart ? f.QuadPart : 1; }
        d3d12_log("[d3d12-onepass] ml1990 conversions=%ld retries=%ld convert-ms=%lld\n",
                  (long)n, (long)r, (long long)(ticks * 1000 / qpf));
    }
}

/* ml1011: mad_convert_stage (the no-options wrapper) was removed -- every
 * caller now passes options, because the DXBC backend needs them. */
static obj_handle_t mad_convert_stage_opts(struct mad_device *d, struct mad_rootsig *rs,
                                      const void *dxil, SIZE_T dxil_len, const char *entry,
                                      obj_handle_t *lib_out, const char *tag,
                                      struct madeira_ir_vs_input *vsin, unsigned vsin_cap, unsigned *vsin_n,
                                      UINT *tg_out, struct madeira_ir_loc *locs, unsigned *nlocs,
                                      const struct mad_convert_opts *o) {
    struct madeira_ir_convert_args a;
    char name[MADEIRA_IR_ENTRY_MAX];
    unsigned char *buf2 = NULL; const SIZE_T cap2 = 256u * 1024u;
    unsigned char *buf = NULL;
    SIZE_T need = 0;
    const int onepass = mad_onepass_enabled();
    int retried = 0;
    LONG64 t0 = mad_qpc();

    if (o && o->air) memset(o->air, 0, sizeof *o->air);   /* ml1008 */
    if (o && o->tess_stage && o->air2) memset(o->air2, 0, sizeof *o->air2);   /* ml1083 */
    name[0] = 0;
    if (onepass) {
        need = dxil_len * 4 + 64u * 1024u;
        buf = malloc(need);
        if (!buf) return 0;
        if (o && o->layout) { buf2 = malloc(cap2); if (!buf2) { free(buf); return 0; } }   /* ml927: the stage-in metallib */
    }

    /* Size-then-fill (rollback) asks with no buffer; one-pass converts
     * straight into the first buffer and only comes back if it was too small. */
    mad_fill_convert_inputs(&a, rs, dxil, dxil_len, entry, o);
    a.out_entry = (uint64_t)(uintptr_t)name;
    if (onepass) {
        a.out_buf = (uint64_t)(uintptr_t)buf; a.out_cap = (uint64_t)need;
        a.out_vs_inputs = (uint64_t)(uintptr_t)vsin; a.vs_input_cap = vsin ? vsin_cap : 0;
        a.out_locs = (uint64_t)(uintptr_t)locs; a.loc_cap = locs ? MAD_LOC_MAX : 0;
        if (buf2) { a.out_buf2 = (uint64_t)(uintptr_t)buf2; a.out_cap2 = cap2; }
    }
    MadeiraIRConvert(&a);
    if (a.ret_status != MADEIRA_IR_BUFFER_TOO_SMALL && a.ret_status != MADEIRA_IR_OK) {
        const unsigned char *b = (const unsigned char *)dxil;
        d3d12_log("[madeira-d3d12] %s conversion failed: %s (%s backend, code %u); %llu bytes, head "
                  "%02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x\n",
                  tag, mad_ir_status_name(a.ret_status),
                  a.ret_backend == MADEIRA_IR_BACKEND_AIRCONV ? "sm5/dxbc" : "dxil",
                  a.ret_error_code, (unsigned long long)dxil_len,
                  b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
        if (a.ret_note[0]) d3d12_log("[madeira-d3d12] converter service: %s\n", a.ret_note);
        /* A small container fits in the log whole; that is worth more than a
         * file that may never be written. */
        if (dxil_len <= 1024) {
            SIZE_T off;
            for (off = 0; off < dxil_len; off += 32) {
                char line[32 * 2 + 8], *w = line;
                SIZE_T k;
                for (k = 0; k < 32 && off + k < dxil_len; k++) w += sprintf(w, "%02x", b[off + k]);
                *w = 0;
                d3d12_log("[madeira-d3d12]   %04x: %s\n", (unsigned)off, line);
            }
        }
        free(buf); free(buf2);
        return 0;
    }
    if (a.ret_status == MADEIRA_IR_BUFFER_TOO_SMALL || !buf) {
        need = (SIZE_T)a.ret_len;
        if (!need) {
            d3d12_log("[madeira-d3d12] %s conversion produced no bytes\n", tag);
            free(buf); free(buf2);
            return 0;
        }
        free(buf);
        buf = malloc(need);
        if (!buf) { free(buf2); return 0; }
        if (!buf2 && o && o->layout) { buf2 = malloc(cap2); if (!buf2) { free(buf); return 0; } }   /* ml927 */
        retried = onepass;

        mad_fill_convert_inputs(&a, rs, dxil, dxil_len, entry, o);
        a.out_buf = (uint64_t)(uintptr_t)buf;
        a.out_cap = (uint64_t)need;
        a.out_vs_inputs = (uint64_t)(uintptr_t)vsin;
        a.vs_input_cap = vsin ? vsin_cap : 0;
        a.out_locs = (uint64_t)(uintptr_t)locs;
        a.loc_cap = locs ? MAD_LOC_MAX : 0;
        a.out_entry = (uint64_t)(uintptr_t)name;
        if (buf2) { a.out_buf2 = (uint64_t)(uintptr_t)buf2; a.out_cap2 = cap2; }
        MadeiraIRConvert(&a);
        if (a.ret_status != MADEIRA_IR_OK) {
            d3d12_log("[madeira-d3d12] %s conversion failed: %s (converter code %u)\n",
                      tag, mad_ir_status_name(a.ret_status), a.ret_error_code);
            free(buf); free(buf2);
            return 0;
        }
    }
    mad_convert_note_time(t0, retried);
    if (o && o->air) {   /* ml1008 */
        o->air->backend    = a.ret_backend;
        o->air->cb_bind    = a.ret_cb_table_bind;
        o->air->arg_bind   = a.ret_arg_table_bind;
        o->air->arg_qwords = a.ret_arg_qwords;
        o->air->nranges    = a.ret_air_nranges > MADEIRA_IR_AIR_RANGE_MAX
                           ? MADEIRA_IR_AIR_RANGE_MAX : a.ret_air_nranges;
        o->air->slot_mask  = a.ret_air_slot_mask;   /* ml1011 */
    }
    if (o && o->tess_stage) {   /* ml1083 */
        if (o->air2) {
            o->air2->backend = a.ret_backend; o->air2->cb_bind = a.ret_cb_table_bind2; o->air2->arg_bind = a.ret_arg_table_bind2;
            o->air2->arg_qwords = a.ret_arg_qwords2;
            o->air2->nranges = a.ret_air_nranges2 > MADEIRA_IR_AIR_RANGE_MAX ? MADEIRA_IR_AIR_RANGE_MAX : a.ret_air_nranges2;
        }
        if (o->threads_per_patch) *o->threads_per_patch = a.ret_threads_per_patch;
        if (o->max_potential) *o->max_potential = a.ret_max_potential_factor;
        if (o->out_prim) *o->out_prim = a.ret_tess_out_prim;
    }
    if (o) {   /* ml927 */
        if (o->vs_output_size) *o->vs_output_size = a.ret_vs_output_size;
        if (o->gs_max_prims) *o->gs_max_prims = a.ret_gs_max_prims;
        if (o->lib2_out) {
            *o->lib2_out = 0;
            if (a.ret_len2 && a.ret_len2 <= cap2 && buf2) {
                obj_handle_t dd2 = DispatchData_alloc_init((uint64_t)(uintptr_t)buf2, (uint64_t)a.ret_len2), err2 = 0;
                if (dd2) { *o->lib2_out = MTLDevice_newLibrary(d->mtl_device, dd2, &err2); NSObject_release(dd2); }
                if (err2) mad_log_nserror("second library", err2);
            }
            if (!*o->lib2_out) d3d12_log("[madeira-d3d12] %s: no stage-in library (%llu bytes reported; %s)\n", tag,
                                         (unsigned long long)a.ret_len2, a.ret_note[0] ? a.ret_note : "no note");
        }
        if (o->gs_emulation)
            d3d12_log("[madeira-d3d12] %s converted with geometry emulation: vertex output %u B, gs max prims %u, payload %u, passthrough %u, stage-in %llu B\n",
                      tag, a.ret_vs_output_size, a.ret_gs_max_prims, a.ret_gs_payload, a.ret_gs_passthrough, (unsigned long long)a.ret_len2);
    }
    free(buf2);

    if (vsin_n) *vsin_n = a.ret_vs_input_count < vsin_cap ? a.ret_vs_input_count : vsin_cap;
    if (nlocs) *nlocs = a.ret_loc_count < MAD_LOC_MAX ? a.ret_loc_count : MAD_LOC_MAX;
    if (tg_out) { tg_out[0] = a.ret_tg_size[0]; tg_out[1] = a.ret_tg_size[1]; tg_out[2] = a.ret_tg_size[2]; }
    obj_handle_t dd = DispatchData_alloc_init((uint64_t)(uintptr_t)buf, (uint64_t)a.ret_len);
    obj_handle_t fn = 0, err = 0, lib = 0;
    if (dd) {
        lib = MTLDevice_newLibrary(d->mtl_device, dd, &err);
        NSObject_release(dd);
        if (lib) { InterlockedExchangeAdd64(&g_lib_bytes, (LONG64)a.ret_len); InterlockedIncrement(&g_lib_count); }   /* ml1060 */
    }
    if (err) mad_log_nserror("library", err);
    if (!lib) {
        d3d12_log("[madeira-d3d12] %s: the backend rejected the converted library (%u bytes)\n",
                  tag, (unsigned)a.ret_len);
        free(buf);
        return 0;
    }
    /* The converter RENAMES entry points, so the function is looked up by the
     * name reflection reported, never by the D3D-side name. */
    fn = MTLLibrary_newFunction(lib, name);
    if (!fn) {
        d3d12_log("[madeira-d3d12] %s: converted library has no function '%s'\n", tag, name);
        NSObject_release(lib);
        free(buf);
        return 0;
    }
    d3d12_log("[madeira-d3d12] %s converted at runtime: %u bytes of DXIL -> %u bytes of metallib, "
              "entry '%s' (taken from the bytecode)\n", tag, (unsigned)dxil_len,
              (unsigned)a.ret_len, name);
    snprintf(g_last_entry, sizeof g_last_entry, "%s", name);
    if (o && o->name_out && o->name_cap) snprintf(o->name_out, o->name_cap, "%s", name);   /* ml927b */
    if (!strcmp(name, "WriteToSliceMainVS") || !strcmp(name, "WriteToSliceMainGS")) {   /* ml926: bytes for offline disassembly */
        static unsigned said; if (said++ < 2) {
            const unsigned char *b = (const unsigned char *)dxil; unsigned i, j; char line[200];
            d3d12_log("[dxil-hex] %s '%s' %u bytes begin\n", tag, name, (unsigned)dxil_len);
            for (i = 0; i < dxil_len; i += 64) {
                int n = snprintf(line, sizeof line, "[dxil-hex] %05x ", i);
                for (j = 0; j < 64 && i + j < dxil_len; j++) n += snprintf(line + n, sizeof line - n, "%02x", b[i + j]);
                d3d12_log("%s\n", line);
            }
            d3d12_log("[dxil-hex] end\n");
        }
    }
    *lib_out = lib;
    free(buf);
    return fn;
}

/* Colour formats this build can present. Anything else is refused by name
 * rather than quietly replaced with the one the cube happens to use. */
static int mad_map_rtv_format(DXGI_FORMAT f, enum WMTPixelFormat *out) {
    switch (f) {
    case DXGI_FORMAT_R8G8B8A8_UNORM:      *out = WMTPixelFormatRGBA8Unorm;     return 1;
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: *out = WMTPixelFormatRGBA8Unorm_sRGB;return 1;
    case DXGI_FORMAT_B8G8R8A8_UNORM:      *out = WMTPixelFormatBGRA8Unorm;     return 1;
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: *out = WMTPixelFormatBGRA8Unorm_sRGB;return 1;
    case DXGI_FORMAT_R16G16B16A16_FLOAT:  *out = WMTPixelFormatRGBA16Float;    return 1;
    default: return 0;
    }
}

/* ---- pipeline state (ml859) --------------------------------------------- */
static enum WMTBlendFactor mad_blend_factor(D3D12_BLEND b) {
    switch (b) {
    case D3D12_BLEND_ZERO: return WMTBlendFactorZero;
    case D3D12_BLEND_ONE: return WMTBlendFactorOne;
    case D3D12_BLEND_SRC_COLOR: return WMTBlendFactorSourceColor;
    case D3D12_BLEND_INV_SRC_COLOR: return WMTBlendFactorOneMinusSourceColor;
    case D3D12_BLEND_SRC_ALPHA: return WMTBlendFactorSourceAlpha;
    case D3D12_BLEND_INV_SRC_ALPHA: return WMTBlendFactorOneMinusSourceAlpha;
    case D3D12_BLEND_DEST_ALPHA: return WMTBlendFactorDestinationAlpha;
    case D3D12_BLEND_INV_DEST_ALPHA: return WMTBlendFactorOneMinusDestinationAlpha;
    case D3D12_BLEND_DEST_COLOR: return WMTBlendFactorDestinationColor;
    case D3D12_BLEND_INV_DEST_COLOR: return WMTBlendFactorOneMinusDestinationColor;
    case D3D12_BLEND_SRC_ALPHA_SAT: return WMTBlendFactorSourceAlphaSaturated;
    case D3D12_BLEND_BLEND_FACTOR: return WMTBlendFactorBlendColor;
    case D3D12_BLEND_INV_BLEND_FACTOR: return WMTBlendFactorOneMinusBlendColor;
    case D3D12_BLEND_SRC1_COLOR: return WMTBlendFactorSource1Color;
    case D3D12_BLEND_INV_SRC1_COLOR: return WMTBlendFactorOneMinusSource1Color;
    case D3D12_BLEND_SRC1_ALPHA: return WMTBlendFactorSource1Alpha;
    case D3D12_BLEND_INV_SRC1_ALPHA: return WMTBlendFactorOneMinusSource1Alpha;
    default: return WMTBlendFactorOne;
    }
}
static enum WMTBlendOperation mad_blend_op(D3D12_BLEND_OP o) {
    switch (o) {
    case D3D12_BLEND_OP_SUBTRACT: return WMTBlendOperationSubtract;
    case D3D12_BLEND_OP_REV_SUBTRACT: return WMTBlendOperationReverseSubtract;
    case D3D12_BLEND_OP_MIN: return WMTBlendOperationMin;
    case D3D12_BLEND_OP_MAX: return WMTBlendOperationMax;
    default: return WMTBlendOperationAdd;
    }
}
static uint8_t mad_write_mask(UINT8 m) {
    return (uint8_t)(((m & D3D12_COLOR_WRITE_ENABLE_RED) ? WMTColorWriteMaskRed : 0) |
                     ((m & D3D12_COLOR_WRITE_ENABLE_GREEN) ? WMTColorWriteMaskGreen : 0) |
                     ((m & D3D12_COLOR_WRITE_ENABLE_BLUE) ? WMTColorWriteMaskBlue : 0) |
                     ((m & D3D12_COLOR_WRITE_ENABLE_ALPHA) ? WMTColorWriteMaskAlpha : 0));
}
static enum WMTCompareFunction mad_compare(D3D12_COMPARISON_FUNC f) {
    return (f >= D3D12_COMPARISON_FUNC_NEVER && f <= D3D12_COMPARISON_FUNC_ALWAYS)
         ? (enum WMTCompareFunction)(f - D3D12_COMPARISON_FUNC_NEVER) : WMTCompareFunctionAlways;
}
static enum WMTStencilOperation mad_stencil_op(D3D12_STENCIL_OP o) {
    return (o >= D3D12_STENCIL_OP_KEEP && o <= D3D12_STENCIL_OP_DECR)
         ? (enum WMTStencilOperation)(o - D3D12_STENCIL_OP_KEEP) : WMTStencilOperationKeep;
}
static void mad_stencil_face(struct WMTStencilInfo *s, const D3D12_DEPTH_STENCILOP_DESC *d, BOOL enabled,
                             UINT8 read_mask, UINT8 write_mask) {
    s->enabled = enabled != 0;
    s->depth_stencil_pass_op = mad_stencil_op(d->StencilPassOp);
    s->stencil_fail_op = mad_stencil_op(d->StencilFailOp);
    s->depth_fail_op = mad_stencil_op(d->StencilDepthFailOp);
    s->stencil_compare_function = mad_compare(d->StencilFunc);
    s->read_mask = read_mask; s->write_mask = write_mask;
}

/* MTLVertexFormat, by value: the descriptor carries the raw number. */
static uint32_t mad_vertex_format(DXGI_FORMAT f) {
    switch (f) {
    case DXGI_FORMAT_R32G32B32A32_FLOAT: return 31; case DXGI_FORMAT_R32G32B32_FLOAT: return 30;
    case DXGI_FORMAT_R32G32_FLOAT: return 29; case DXGI_FORMAT_R32_FLOAT: return 28;
    case DXGI_FORMAT_R32G32B32A32_UINT: return 39; case DXGI_FORMAT_R32G32B32_UINT: return 38;
    case DXGI_FORMAT_R32G32_UINT: return 37; case DXGI_FORMAT_R32_UINT: return 36;
    case DXGI_FORMAT_R32G32B32A32_SINT: return 35; case DXGI_FORMAT_R32G32B32_SINT: return 34;
    case DXGI_FORMAT_R32G32_SINT: return 33; case DXGI_FORMAT_R32_SINT: return 32;
    case DXGI_FORMAT_R16G16B16A16_FLOAT: return 27; case DXGI_FORMAT_R16G16_FLOAT: return 25; case DXGI_FORMAT_R16_FLOAT: return 53;
    case DXGI_FORMAT_R16G16B16A16_UNORM: return 21; case DXGI_FORMAT_R16G16_UNORM: return 19; case DXGI_FORMAT_R16_UNORM: return 51;
    case DXGI_FORMAT_R16G16B16A16_SNORM: return 24; case DXGI_FORMAT_R16G16_SNORM: return 22; case DXGI_FORMAT_R16_SNORM: return 52;
    case DXGI_FORMAT_R16G16B16A16_UINT: return 15; case DXGI_FORMAT_R16G16_UINT: return 13; case DXGI_FORMAT_R16_UINT: return 49;
    case DXGI_FORMAT_R16G16B16A16_SINT: return 18; case DXGI_FORMAT_R16G16_SINT: return 16; case DXGI_FORMAT_R16_SINT: return 50;
    case DXGI_FORMAT_R8G8B8A8_UNORM: return 9; case DXGI_FORMAT_R8G8_UNORM: return 7; case DXGI_FORMAT_R8_UNORM: return 47;
    case DXGI_FORMAT_R8G8B8A8_SNORM: return 12; case DXGI_FORMAT_R8G8_SNORM: return 10; case DXGI_FORMAT_R8_SNORM: return 48;
    case DXGI_FORMAT_R8G8B8A8_UINT: return 3; case DXGI_FORMAT_R8G8_UINT: return 1; case DXGI_FORMAT_R8_UINT: return 45;
    case DXGI_FORMAT_R8G8B8A8_SINT: return 6; case DXGI_FORMAT_R8G8_SINT: return 4; case DXGI_FORMAT_R8_SINT: return 46;
    case DXGI_FORMAT_B8G8R8A8_UNORM: return 42;
    case DXGI_FORMAT_R10G10B10A2_UNORM: case DXGI_FORMAT_R10G10B10A2_UINT: return 41;
    case DXGI_FORMAT_R11G11B10_FLOAT: return 54;
    case DXGI_FORMAT_R9G9B9E5_SHAREDEXP: return 55;
    default: return 0;
    }
}

/* The converter names an input after its semantic; the exact spelling is
 * read from the log the first times it appears. Matching takes the part
 * after the last '.', ignores case, and accepts either NAME (index 0) or
 * NAME<index>. */
static int mad_semantic_match(const char *refl, const char *sem, UINT sem_index) {
    const char *t = strrchr(refl, '.');
    char want[80];
    size_t n;
    t = t ? t + 1 : refl;
    n = strlen(sem);
    if (_strnicmp(t, sem, n) != 0) return 0;
    if (t[n] == 0) return sem_index == 0;
    snprintf(want, sizeof want, "%s%u", sem, sem_index);
    return _stricmp(t, want) == 0;
}

/* The top-level argument buffer layout. ml883: MEASURED OFFLINE against the
 * converter (IRRootSignatureGetResourceLocations on six signature shapes):
 * strictly DECLARATION ORDER, one entry per root parameter, each at its
 * natural alignment -- 32-bit constants take 4*N bytes at 4-byte alignment,
 * every pointer parameter takes 8 bytes at 8-byte alignment. Static samplers
 * add one implicit trailing table entry after the last parameter. The old
 * "constants first" rule was only ever right for signatures that declared
 * their constants first; a compute signature with constants after a CBV had
 * the CBV pointer written into the constants' slot. */
static UINT mad_root_layout(const struct mad_rootsig *rs, UINT offsets[MAD_ROOT_PARAM_MAX]) {
    UINT i, off = 0;
    for (i = 0; i < rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        if (rs->params[i].type == MADEIRA_IR_PARAM_CONSTANTS) {
            off = (off + 3) & ~3u; offsets[i] = off; off += rs->params[i].num_constants * 4;
        } else {
            off = (off + 7) & ~7u; offsets[i] = off; off += 8;
        }
    }
    return off;
}

/* ml882: reconcile the computed layout with the converter's reflection. A
 * mismatch here was invisible: the shader read a CBV pointer from one slot
 * while the runtime wrote it into another, and the GPU dereferenced whatever
 * happened to be there. Reflection wins; the computed rule is only a default
 * for parameters the shader never touches. */
static void mad_apply_reflected_layout(struct mad_pso *p, const struct mad_rootsig *rs,
                                       const struct madeira_ir_loc *locs, unsigned n, const char *tag) {
    static unsigned said_dump, said_mismatch;
    unsigned i, k;
    if (!rs) return;
    if (!p->has_root_off) { mad_root_layout(rs, p->root_off); p->has_root_off = 1; }
    if (said_dump < 12 && n) {
        char line[700]; int c = snprintf(line, sizeof line, "[root-layout] %s '%s' %u params:", tag, p->vs_name, rs->nparams);
        said_dump++;
        for (k = 0; k < n && c < (int)sizeof(line) - 40; k++)
            c += snprintf(line + c, sizeof(line) - c, " t%u s%u r%u@%u/%u", locs[k].type, locs[k].space, locs[k].slot, locs[k].offset, (unsigned)locs[k].size);
        d3d12_log("%s\n", line);
    }
    /* ml883: reflection entry i IS root parameter i (declaration order; the
     * only extra entry is the implicit static-sampler table at the end).
     * Matching by register was ambiguous: per-stage signatures declare the
     * same register once per visibility, and the first hit flip-flopped
     * between the vertex and pixel entries. */
    (void)k;
    if (rs->nsamplers && n > rs->nparams && locs[rs->nparams].type == MADEIRA_IR_PARAM_TABLE) {   /* ml923 */
        p->static_off = locs[rs->nparams].offset; p->has_static_off = 1;
        { static unsigned said; if (said++ < 6) d3d12_log("[root-layout] %s '%s': static-sampler table slot at %u\n", tag, p->vs_name, p->static_off); }
    }
    for (i = 0; i < n && i < rs->nparams && i < MAD_ROOT_PARAM_MAX; i++) {
        const struct madeira_ir_loc *L = &locs[i];
        if (rs->params[i].type != L->type) {
            if (said_mismatch++ < 16)
                d3d12_log("[root-layout] %s '%s': param %u is type %u here but the converter lists type %u at entry %u; leaving the computed offset\n",
                          tag, p->vs_name, i, rs->params[i].type, L->type, i);
            continue;
        }
        if (p->root_off[i] != L->offset) {
            if (said_mismatch++ < 16)
                d3d12_log("[root-layout] MISMATCH %s '%s': param %u (type %u) computed at %u, converter put it at %u -- using the converter's\n",
                          tag, p->vs_name, i, rs->params[i].type, p->root_off[i], L->offset);
            p->root_off[i] = L->offset;
        }
    }
}

/* ml1011: the application's input layout in ABI form, plus the per-slot strides
 * the pipeline has to assume.
 *
 * Hoisted out of the geometry-shader branch, which was the only caller: the
 * ORDINARY vertex path never built one, so nothing was passed to the shader
 * compiler. That is why every graphics pipeline failed once vertex shaders
 * started going through the DXBC backend -- with no input layout it emits
 * [[attribute(n)]] stage_in inputs, and Metal then refuses the pipeline with
 * "Vertex function has input attributes but no vertex descriptor was set".
 * Given the layout it generates explicit vertex FETCH instead, which is how
 * DXMT has always driven it (it builds no MTLVertexDescriptor anywhere). */
static void mad_build_input_layout(const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc,
                                   struct mad_pso *p, struct madeira_ir_input_layout *L) {
    UINT running[16] = {0};
    UINT i;
    for (i = 0; i < desc->InputLayout.NumElements && L->n < 31; i++) {
        const D3D12_INPUT_ELEMENT_DESC *el = &desc->InputLayout.pInputElementDescs[i];
        UINT slot = el->InputSlot, bytes, block, off, step;
        struct madeira_ir_input_element *ie = &L->el[L->n];
        if (slot >= 16) continue;
        mad_format_info(el->Format, &bytes, &block);
        /* APPEND aligns to min(4, element size), matching the input-layout rule
         * the DXBC backend was written against. */
        step = bytes < 4 ? (bytes ? bytes : 1u) : 4u;
        off = (el->AlignedByteOffset == D3D12_APPEND_ALIGNED_ELEMENT)
            ? ((running[slot] + step - 1) & ~(step - 1))
            : el->AlignedByteOffset;
        if (off + bytes > running[slot]) running[slot] = off + bytes;
        snprintf(ie->semantic, sizeof ie->semantic, "%s", el->SemanticName ? el->SemanticName : "");
        ie->semantic_index = el->SemanticIndex; ie->format = (UINT)el->Format; ie->slot = slot; ie->offset = off;
        ie->per_instance = el->InputSlotClass == D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA ? 1u : 0u;
        ie->step_rate = el->InstanceDataStepRate;
        ie->attr_format = (UINT)mad_attr_format(el->Format);   /* ml1011 */
        if (!ie->attr_format) {
            static unsigned said;
            if (said++ < 16)
                d3d12_log("[madeira-d3d12] ml1011 input element %u (%s%u) has DXGI format %u with no "
                          "Metal attribute format; the vertex stage cannot fetch it\n",
                          i, ie->semantic, ie->semantic_index, (unsigned)el->Format);
        }
        p->vb_mask |= 1u << slot;
        L->n++;
    }
    for (i = 0; i < 16; i++) if (p->vb_mask & (1u << i)) p->vb_stride[i] = (running[i] + 3) & ~3u;
}

/* ml1083: build the object/mesh pipelines for a hull+domain pipeline state.
 * Returns 1 when at least one index-format variant exists; the pixel stage is
 * the one already compiled for this pipeline (never paired with the vertex
 * shader, see ml1033). Every failure is logged and leaves the draws dropped and
 * counted exactly as before, so the census still says what is missing. */
static int mad_tess_build(struct mad_device *d, struct mad_rootsig *rs, struct mad_pso *p,
                          const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc, const struct WMTRenderPipelineInfo *rp) {
    struct mad_tess *t = calloc(1, sizeof *t);
    struct madeira_ir_input_layout *L = calloc(1, sizeof *L);
    struct madeira_ir_loc locs[MAD_LOC_MAX]; unsigned nl = 0;
    struct mad_air_out *air = malloc(sizeof *air), *air2 = malloc(sizeof *air2);   /* 8 KB each: not on the stack */
    unsigned fmt, built = 0;
    static unsigned said;
    if (!t || !L || !air || !air2) { free(t); free(L); free(air); free(air2); return 0; }
    mad_build_input_layout(desc, p, L);

    {   /* the mesh (domain) function: shared by every object variant */
        struct mad_convert_opts o; memset(&o, 0, sizeof o);
        o.tess_stage = 2; o.hs_bc = desc->HS.pShaderBytecode; o.hs_bc_len = desc->HS.BytecodeLength;
        o.air = air; o.name_out = t->ds_name; o.name_cap = sizeof t->ds_name; o.max_potential = &t->max_potential;
        t->ds_fn = mad_convert_stage_opts(d, rs, desc->DS.pShaderBytecode, desc->DS.BytecodeLength, NULL, &t->ds_lib, "DS(tess)",
                                          NULL, 0, NULL, NULL, locs, &nl, &o);
        if (!t->ds_fn) goto fail;
        t->ds.cb_bind = air->cb_bind; t->ds.arg_bind = air->arg_bind; t->ds.arg_qwords = air->arg_qwords; t->ds.nair = air->nranges;
        if (air->nranges) { t->ds.air = malloc((size_t)air->nranges * sizeof *t->ds.air); if (!t->ds.air) goto fail;
                            memcpy(t->ds.air, air->ranges, (size_t)air->nranges * sizeof *t->ds.air); }
    }
    for (fmt = 0; fmt < 3; fmt++) {   /* the object (vertex+hull) function, per index format */
        struct mad_convert_opts o; struct WMTMeshRenderPipelineInfo mp; obj_handle_t err = 0;
        UINT tpp = 0, prim = 0, mpf = 0;
        memset(&o, 0, sizeof o);
        o.tess_stage = 1; o.tess_index_format = fmt; o.layout = L->n ? L : NULL;
        o.hs_bc = desc->HS.pShaderBytecode; o.hs_bc_len = desc->HS.BytecodeLength;
        o.ds_bc = desc->DS.pShaderBytecode; o.ds_bc_len = desc->DS.BytecodeLength;
        o.air = air; o.air2 = air2; o.name_out = t->obj_name; o.name_cap = sizeof t->obj_name;
        o.threads_per_patch = &tpp; o.max_potential = &mpf; o.out_prim = &prim;
        nl = 0;
        t->obj[fmt].fn = mad_convert_stage_opts(d, rs, desc->VS.pShaderBytecode, desc->VS.BytecodeLength, NULL, &t->obj[fmt].lib, "VS+HS(tess)",
                                                NULL, 0, NULL, NULL, locs, &nl, &o);
        if (!t->obj[fmt].fn) continue;
        if (mpf != t->max_potential) {   /* both functions must have been sized for the same factor */
            d3d12_log("[madeira-d3d12] ml1083 tessellation factor mismatch: object %u, mesh %u; variant %u dropped\n", mpf, t->max_potential, fmt);
            NSObject_release(t->obj[fmt].fn); t->obj[fmt].fn = 0; continue;
        }
        t->threads_per_patch = tpp; t->out_prim = prim;
        t->obj[fmt].slot_mask = air->slot_mask;
        t->obj[fmt].vs.cb_bind = air->cb_bind; t->obj[fmt].vs.arg_bind = air->arg_bind; t->obj[fmt].vs.arg_qwords = air->arg_qwords; t->obj[fmt].vs.nair = air->nranges;
        t->obj[fmt].hs.cb_bind = air2->cb_bind; t->obj[fmt].hs.arg_bind = air2->arg_bind; t->obj[fmt].hs.arg_qwords = air2->arg_qwords; t->obj[fmt].hs.nair = air2->nranges;
        if (air->nranges) { t->obj[fmt].vs.air = malloc((size_t)air->nranges * sizeof *t->obj[fmt].vs.air); if (!t->obj[fmt].vs.air) goto fail;
                            memcpy(t->obj[fmt].vs.air, air->ranges, (size_t)air->nranges * sizeof *t->obj[fmt].vs.air); }
        if (air2->nranges) { t->obj[fmt].hs.air = malloc((size_t)air2->nranges * sizeof *t->obj[fmt].hs.air); if (!t->obj[fmt].hs.air) goto fail;
                             memcpy(t->obj[fmt].hs.air, air2->ranges, (size_t)air2->nranges * sizeof *t->obj[fmt].hs.air); }

        memset(&mp, 0, sizeof mp);
        memcpy(mp.colors, rp->colors, sizeof mp.colors);
        mp.alpha_to_coverage_enabled = rp->alpha_to_coverage_enabled;
        mp.rasterization_enabled = true;
        mp.raster_sample_count = rp->raster_sample_count;
        mp.depth_pixel_format = rp->depth_pixel_format; mp.stencil_pixel_format = rp->stencil_pixel_format;
        mp.object_function = t->obj[fmt].fn; mp.mesh_function = t->ds_fn; mp.fragment_function = p->ps_fn;
        /* The compiler's fixed bindings (DXMT d3d11_pipeline_ts.cpp): vertex-buffer
         * table 16, draw arguments 21, vertex tables 27/28, hull tables 29/30 on
         * the object stage; domain tables 29/30 on the mesh stage. */
        mp.immutable_object_buffers = (1u << 16) | (1u << 21) | (1u << 27) | (1u << 28) | (1u << 29) | (1u << 30);
        mp.immutable_mesh_buffers = (1u << 29) | (1u << 30);
        mp.immutable_fragment_buffers = (1u << 29) | (1u << 30);
        mp.payload_memory_length = 0;   /* Apple7+: the object function declares its own payload */
        mp.mesh_tgsize_is_multiple_of_sgwidth = true;
        mp.object_tgsize_is_multiple_of_sgwidth = true;
        t->obj[fmt].rps = MTLDevice_newMeshRenderPipelineState(d->mtl_device, &mp, &err);
        if (err) mad_log_nserror("tessellation mesh pipeline", err);
        if (!t->obj[fmt].rps) {
            d3d12_log("[madeira-d3d12] ml1083 tessellation pipeline FAILED (index format %u): vs+hs '%s' ds '%s' ps '%s'\n",
                      fmt, t->obj_name, t->ds_name, p->ps_name);
            continue;
        }
        built++;
    }
    if (!built) goto fail;
    if (said++ < 12)
        d3d12_log("[madeira-d3d12] ml1083 tessellation pipeline built: %u index-format variant(s), %u threads/patch, "
                  "max factor %u, output primitive %u, vs '%s' ps '%s' (%u targets, %u input elements)\n",
                  built, t->threads_per_patch, t->max_potential, t->out_prim, p->vs_name, p->ps_name, desc->NumRenderTargets, L->n);
    InterlockedIncrement(&g_tess_built);
    p->tess = t;
    free(L); free(air); free(air2);
    return 1;
fail:
    d3d12_log("[madeira-d3d12] ml1083 tessellation pipeline NOT built for vs '%s' ps '%s'; its draws stay dropped\n", p->vs_name, p->ps_name);
    for (fmt = 0; fmt < 3; fmt++) {
        if (t->obj[fmt].rps) NSObject_release(t->obj[fmt].rps);
        if (t->obj[fmt].fn) NSObject_release(t->obj[fmt].fn);
        if (t->obj[fmt].lib) NSObject_release(t->obj[fmt].lib);
        free(t->obj[fmt].vs.air); free(t->obj[fmt].hs.air);
    }
    if (t->ds_fn) NSObject_release(t->ds_fn);
    if (t->ds_lib) NSObject_release(t->ds_lib);
    free(t->ds.air); free(t); free(L); free(air); free(air2);
    return 0;
}

/* ml1147: is this shader container DXBC (SHEX/SHDR chunk) rather than DXIL? */
static int mad_bc_is_dxbc(const void *bc, SIZE_T len) {
    const unsigned char *b = bc; UINT32 n, i;
    if (!b || len < 32 || memcmp(b, "DXBC", 4)) return 0;
    memcpy(&n, b + 28, 4);
    if (n > 64 || 32 + (SIZE_T)n * 4 > len) return 0;
    for (i = 0; i < n; i++) {
        UINT32 off; memcpy(&off, b + 32 + i * 4, 4);
        if ((SIZE_T)off + 8 > len) continue;
        if (!memcmp(b + off, "DXIL", 4)) return 0;
        if (!memcmp(b + off, "SHEX", 4) || !memcmp(b + off, "SHDR", 4)) return 1;
    }
    return 0;
}
/* ml1147: GEOMETRY SHADERS on the DXBC backend, as DXMT's D3D11 layer runs them
 * (d3d11_pipeline_gs.cpp): a mesh pipeline whose OBJECT function is the vertex
 * shader compiled against the geometry shader and whose MESH function is the
 * geometry shader. Before this every DXBC geometry pipeline lost its geometry
 * stage ("Geometry shader cannot be independently converted"): UE 5.0's
 * WriteToSlice volume passes (the colour-grading LUT among them) drew nothing
 * and the frame came out black (ph-valley03). Built for LIST topologies, one
 * object variant per index format; a strip draw keeps the plain pipeline. The
 * mad_tess record is reused: obj[fmt].vs = the vertex tables, ds = the geometry
 * shader's, no hull. */
static int mad_gsx_build(struct mad_device *d, struct mad_rootsig *rs, struct mad_pso *p,
                         const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc, const struct WMTRenderPipelineInfo *rp, UINT strip) {
    struct mad_tess *t = calloc(1, sizeof *t);
    struct madeira_ir_input_layout *L = calloc(1, sizeof *L);
    struct madeira_ir_loc locs[MAD_LOC_MAX]; unsigned nl = 0;
    struct mad_air_out *air = malloc(sizeof *air);   /* 8 KB: not on the stack */
    unsigned fmt, built = 0;
    static unsigned said;
    if (!t || !L || !air) { free(t); free(L); free(air); return 0; }
    t->is_gs = 1;
    mad_build_input_layout(desc, p, L);
    {   /* the mesh (geometry) function: shared by every object variant */
        struct mad_convert_opts o; memset(&o, 0, sizeof o);
        o.gs_stage = 2; o.gs_strip = strip; o.gs_bc = desc->VS.pShaderBytecode; o.gs_bc_len = desc->VS.BytecodeLength;
        o.air = air; o.name_out = t->ds_name; o.name_cap = sizeof t->ds_name;
        t->ds_fn = mad_convert_stage_opts(d, rs, desc->GS.pShaderBytecode, desc->GS.BytecodeLength, NULL, &t->ds_lib, "GS(dxbc)",
                                          NULL, 0, NULL, NULL, locs, &nl, &o);
        if (!t->ds_fn) goto fail;
        t->ds.cb_bind = air->cb_bind; t->ds.arg_bind = air->arg_bind; t->ds.arg_qwords = air->arg_qwords; t->ds.nair = air->nranges;
        if (air->nranges) { t->ds.air = malloc((size_t)air->nranges * sizeof *t->ds.air); if (!t->ds.air) goto fail;
                            memcpy(t->ds.air, air->ranges, (size_t)air->nranges * sizeof *t->ds.air); }
    }
    for (fmt = 0; fmt < 3; fmt++) {   /* the object (vertex-for-geometry) function, per index format */
        struct mad_convert_opts o; struct WMTMeshRenderPipelineInfo mp; obj_handle_t err = 0;
        memset(&o, 0, sizeof o);
        o.gs_stage = 1; o.gs_strip = strip; o.tess_index_format = fmt; o.layout = L->n ? L : NULL;
        o.gs_bc = desc->GS.pShaderBytecode; o.gs_bc_len = desc->GS.BytecodeLength;
        o.air = air; o.name_out = t->obj_name; o.name_cap = sizeof t->obj_name;
        nl = 0;
        t->obj[fmt].fn = mad_convert_stage_opts(d, rs, desc->VS.pShaderBytecode, desc->VS.BytecodeLength, NULL, &t->obj[fmt].lib, "VS+GS(dxbc)",
                                                NULL, 0, NULL, NULL, locs, &nl, &o);
        if (!t->obj[fmt].fn) continue;
        t->obj[fmt].slot_mask = air->slot_mask;
        t->obj[fmt].vs.cb_bind = air->cb_bind; t->obj[fmt].vs.arg_bind = air->arg_bind; t->obj[fmt].vs.arg_qwords = air->arg_qwords; t->obj[fmt].vs.nair = air->nranges;
        t->obj[fmt].hs.cb_bind = ~0u; t->obj[fmt].hs.arg_bind = ~0u;
        if (air->nranges) { t->obj[fmt].vs.air = malloc((size_t)air->nranges * sizeof *t->obj[fmt].vs.air); if (!t->obj[fmt].vs.air) goto fail;
                            memcpy(t->obj[fmt].vs.air, air->ranges, (size_t)air->nranges * sizeof *t->obj[fmt].vs.air); }
        memset(&mp, 0, sizeof mp);
        memcpy(mp.colors, rp->colors, sizeof mp.colors);
        mp.alpha_to_coverage_enabled = rp->alpha_to_coverage_enabled;
        mp.rasterization_enabled = true;
        mp.raster_sample_count = rp->raster_sample_count;
        mp.depth_pixel_format = rp->depth_pixel_format; mp.stencil_pixel_format = rp->stencil_pixel_format;
        mp.object_function = t->obj[fmt].fn; mp.mesh_function = t->ds_fn; mp.fragment_function = p->ps_fn;
        /* DXMT's fixed bindings for a geometry pipeline: vertex-buffer table 16,
         * draw arguments 21, vertex tables 29/30 on the object stage; geometry
         * tables 29/30 on the mesh stage; the pixel stage's 29/30. The payload
         * is DXMT's size; its object threadgroups are 30 or 32 wide. */
        mp.immutable_object_buffers = (1u << 16) | (1u << 21) | (1u << 29) | (1u << 30);
        mp.immutable_mesh_buffers = (1u << 29) | (1u << 30);
        mp.immutable_fragment_buffers = (1u << 29) | (1u << 30);
        mp.payload_memory_length = 16256;
        t->obj[fmt].rps = MTLDevice_newMeshRenderPipelineState(d->mtl_device, &mp, &err);
        if (err) mad_log_nserror("geometry mesh pipeline", err);
        if (!t->obj[fmt].rps) {
            d3d12_log("[madeira-d3d12] ml1147 geometry pipeline FAILED (index format %u): vs+gs '%s' gs '%s' ps '%s'\n",
                      fmt, t->obj_name, t->ds_name, p->ps_name);
            continue;
        }
        built++;
    }
    if (!built) goto fail;
    if (said++ < 16)
        d3d12_log("[madeira-d3d12] ml1147 geometry pipeline built (%s): %u index-format variant(s), vs '%s' gs '%s' ps '%s' (%u targets, %u input elements)\n",
                  strip ? "strip" : "list", built, p->vs_name, t->ds_name, p->ps_name, desc->NumRenderTargets, L->n);
    InterlockedIncrement(&g_gs_built);
    if (strip) p->tess_strip = t; else p->tess = t;
    free(L); free(air);
    return 1;
fail:
    d3d12_log("[madeira-d3d12] ml1147 geometry pipeline NOT built for vs '%s' ps '%s'; its geometry stage stays dropped\n", p->vs_name, p->ps_name);
    for (fmt = 0; fmt < 3; fmt++) {
        if (t->obj[fmt].rps) NSObject_release(t->obj[fmt].rps);
        if (t->obj[fmt].fn) NSObject_release(t->obj[fmt].fn);
        if (t->obj[fmt].lib) NSObject_release(t->obj[fmt].lib);
        free(t->obj[fmt].vs.air);
    }
    if (t->ds_fn) NSObject_release(t->ds_fn);
    if (t->ds_lib) NSObject_release(t->ds_lib);
    free(t->ds.air); free(t); free(L); free(air);
    return 0;
}

static HRESULT STDMETHODCALLTYPE device_CreateGraphicsPipelineState(ID3D12Device *This,
        const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc, REFIID riid, void **out) {
    struct mad_device *d = (struct mad_device *)This;
    struct mad_rootsig *rs;
    struct mad_pso *p;
    struct WMTRenderPipelineInfo rp;
    struct WMTVertexDescriptorInfo vd;
    struct WMTDepthStencilInfo dsi;
    struct madeira_ir_vs_input vsin[32];
    unsigned nvsin = 0, i;
    int has_vd = 0, is_depth;
    static unsigned said_inputs, said_pso;
    HRESULT hr;
    if (!desc || !out) return E_INVALIDARG;
    if (!desc->VS.pShaderBytecode) { d3d12_log("[madeira-d3d12] pipeline has no vertex shader\n"); return E_INVALIDARG; }
    if (desc->GS.pShaderBytecode || desc->HS.pShaderBytecode || desc->DS.pShaderBytecode) {   /* ml926: stages this runtime cannot run yet */
        static unsigned said; if (said++ < 12)
            d3d12_log("[madeira-d3d12] pipeline carries %s%s%s (%u/%u/%u bytes) which this runtime DROPS; VS %u B, PS %u B\n",
                      desc->GS.pShaderBytecode ? "GS " : "", desc->HS.pShaderBytecode ? "HS " : "", desc->DS.pShaderBytecode ? "DS " : "",
                      (unsigned)desc->GS.BytecodeLength, (unsigned)desc->HS.BytecodeLength, (unsigned)desc->DS.BytecodeLength,
                      (unsigned)desc->VS.BytecodeLength, (unsigned)desc->PS.BytecodeLength);
    }
    rs = (struct mad_rootsig *)desc->pRootSignature;
    mad_resolve_target(d);

    p = calloc(1, sizeof *p);
    if (!p) return E_OUTOFMEMORY;
    p->vtbl = &g_pso_vtbl; p->refs = 1; p->iid = &IID_ID3D12PipelineState; p->name = "PipelineState";
    if (desc->HS.pShaderBytecode || desc->DS.pShaderBytecode) { p->has_tess = 1; InterlockedIncrement(&g_tess_psos); }   /* ml1050 */

    {
        struct madeira_ir_loc locs[MAD_LOC_MAX]; unsigned nl = 0;
        if (desc->GS.pShaderBytecode && !mad_bc_is_dxbc(desc->GS.pShaderBytecode, desc->GS.BytecodeLength)) {   /* ml927: geometry-shader pipeline -> converter mesh emulation; ml1147: DXIL only */
            struct madeira_ir_input_layout *L = calloc(1, sizeof *L);
            struct mad_convert_opts ov, og;
            char gsname[64];
            if (!L) { pso_Release((ID3D12PipelineState *)p); return E_OUTOFMEMORY; }
            mad_build_input_layout(desc, p, L);
            memset(&ov, 0, sizeof ov); ov.gs_emulation = 1; ov.topology = (UINT)desc->PrimitiveTopologyType; ov.layout = L->n ? L : NULL;
            ov.lib2_out = &p->si_lib; ov.vs_output_size = &p->gs_vertex_size; ov.name_out = p->vs_name; ov.name_cap = sizeof p->vs_name;
            p->vs_fn = mad_convert_stage_opts(d, rs, desc->VS.pShaderBytecode, desc->VS.BytecodeLength, NULL, &p->vs_lib, "VS(gs)",
                                              vsin, 32, &nvsin, NULL, locs, &nl, &ov);
            if (p->vs_fn) mad_apply_reflected_layout(p, rs, locs, nl, "VS");
            memset(&og, 0, sizeof og); og.gs_emulation = 1; og.topology = (UINT)desc->PrimitiveTopologyType; og.gs_max_prims = &p->gs_max_prims;
            og.name_out = gsname; og.name_cap = sizeof gsname; gsname[0] = 0;
            nl = 0;
            {
                obj_handle_t gfn = mad_convert_stage_opts(d, rs, desc->GS.pShaderBytecode, desc->GS.BytecodeLength, NULL, &p->gs_lib, "GS",
                                                          NULL, 0, NULL, NULL, locs, &nl, &og);
                if (gfn) { mad_apply_reflected_layout(p, rs, locs, nl, "GS"); NSObject_release(gfn); }
                else gsname[0] = 0;
            }
            { UINT ln = L->n; free(L); L = NULL;
            if (p->vs_fn && gsname[0] && (!ln || p->si_lib) && p->gs_max_prims) {
                p->gs_emu = 1;
                snprintf(p->gs_name, sizeof p->gs_name, "%s", gsname);
            } else {
                d3d12_log("[madeira-d3d12] geometry pipeline: conversion incomplete (vs %d, gs '%s', stage-in %d, max prims %u); the geometry shader is DROPPED for this pipeline\n",
                          !!p->vs_fn, gsname, !!p->si_lib, p->gs_max_prims);
                if (p->si_lib) { NSObject_release(p->si_lib); p->si_lib = 0; }
                if (p->gs_lib) { NSObject_release(p->gs_lib); p->gs_lib = 0; }
                if (p->vs_fn) { NSObject_release(p->vs_fn); p->vs_fn = 0; }
                if (p->vs_lib) { NSObject_release(p->vs_lib); p->vs_lib = 0; }
                nvsin = 0; nl = 0;
            } }
        }
        if (!p->gs_emu) {
        /* ml1011: the ordinary vertex path now supplies the input layout too, so
         * a DXBC-backend vertex shader fetches vertices itself instead of
         * declaring stage_in attributes Metal has no descriptor for. */
        struct madeira_ir_input_layout *LV = calloc(1, sizeof *LV);
        struct mad_air_out air_vs;
        struct mad_convert_opts ov2;
        char vsentry[MADEIRA_IR_ENTRY_MAX];
        if (!LV) { pso_Release((ID3D12PipelineState *)p); return E_OUTOFMEMORY; }
        mad_build_input_layout(desc, p, LV);
        memset(&air_vs, 0, sizeof air_vs);
        memset(&ov2, 0, sizeof ov2);
        ov2.layout = LV->n ? LV : NULL;
        ov2.air = &air_vs;
        ov2.name_out = vsentry; ov2.name_cap = sizeof vsentry; vsentry[0] = 0;
        p->vs_fn = mad_convert_stage_opts(d, rs, desc->VS.pShaderBytecode, desc->VS.BytecodeLength, NULL, &p->vs_lib, "VS",
                                     vsin, 32, &nvsin, NULL, locs, &nl, &ov2);
        free(LV);
        if (p->vs_fn) {
            snprintf(p->vs_name, sizeof p->vs_name, "%s", vsentry[0] ? vsentry : g_last_entry);
            p->backend = air_vs.backend;
            if (air_vs.backend == MADEIRA_IR_BACKEND_AIRCONV) {   /* ml1011 */
                static unsigned said_vs;
                p->cb_bind = air_vs.cb_bind; p->arg_bind = air_vs.arg_bind;
                p->arg_qwords = air_vs.arg_qwords; p->nair = 0;
                p->air_slot_mask = air_vs.slot_mask;   /* ml1011 */
                if (air_vs.nranges) {
                    p->air = malloc((size_t)air_vs.nranges * sizeof *p->air);
                    if (!p->air) { pso_Release((ID3D12PipelineState *)p); return E_OUTOFMEMORY; }
                    memcpy(p->air, air_vs.ranges, (size_t)air_vs.nranges * sizeof *p->air);
                    p->nair = air_vs.nranges;
                }
                if (said_vs++ < 8)
                    d3d12_log("[madeira-d3d12] ml1011 VS via the sm5/dxbc backend: cbTable=%d argTable=%d "
                              "qwords=%u ranges=%u, %u input element(s)\n",
                              air_vs.cb_bind == ~0u ? -1 : (int)air_vs.cb_bind,
                              air_vs.arg_bind == ~0u ? -1 : (int)air_vs.arg_bind,
                              air_vs.arg_qwords, air_vs.nranges, desc->InputLayout.NumElements);
            } else {
                mad_apply_reflected_layout(p, rs, locs, nl, "VS");
            }
        }
        }
        if (desc->PS.pShaderBytecode) {
            struct mad_convert_opts op; struct mad_air_out air_ps;
            memset(&op, 0, sizeof op); op.name_out = p->ps_name; op.name_cap = sizeof p->ps_name;   /* ml927b: per-call name */
            memset(&air_ps, 0, sizeof air_ps);
            op.air = &air_ps;   /* ml1011 */
            {   /* ml1023: what the pixel stage must be compiled against. */
                UINT k, flags = 0, unorm = 0;
                const D3D12_RENDER_TARGET_BLEND_DESC *b0 = &desc->BlendState.RenderTarget[0];
                /* Dual-source blending is in use when any factor names SRC1. */
                UINT f[4] = { b0->SrcBlend, b0->DestBlend, b0->SrcBlendAlpha, b0->DestBlendAlpha };
                for (k = 0; k < 4; k++)
                    if (f[k] == D3D12_BLEND_SRC1_COLOR || f[k] == D3D12_BLEND_INV_SRC1_COLOR ||
                        f[k] == D3D12_BLEND_SRC1_ALPHA || f[k] == D3D12_BLEND_INV_SRC1_ALPHA)
                        flags |= MADEIRA_IR_PS_DUAL_SOURCE_BLEND;
                if (desc->DSVFormat == DXGI_FORMAT_UNKNOWN) flags |= MADEIRA_IR_PS_DISABLE_DEPTH;
                for (k = 0; k < desc->NumRenderTargets && k < 8; k++)
                    if (mad_format_is_unorm(desc->RTVFormats[k])) unorm |= 1u << k;
                op.ps_valid = 1;
                op.ps_sample_mask = desc->SampleMask ? desc->SampleMask : ~0u;
                op.ps_flags = flags;
                op.ps_unorm_mask = unorm;
                /* ml1031: pair it with the stage that actually feeds it.
                 *
                 * ml1033: ONLY the vertex shader may be paired this way. If the
                 * pipeline has a geometry or domain shader, the pixel stage's
                 * interpolants come from THAT stage, and pairing against the VS
                 * would zero-fill inputs the real producer does write -- wrong by
                 * construction. Those pipelines keep the old behaviour. */
                if (!desc->GS.pShaderBytecode && !desc->DS.pShaderBytecode &&
                    !desc->HS.pShaderBytecode) {
                    op.vs_bc = desc->VS.pShaderBytecode;
                    op.vs_bc_len = desc->VS.BytecodeLength;
                } else {
                    static unsigned said_skip;
                    if (!said_skip++)
                        d3d12_log("[madeira-d3d12] ml1033 pixel stage is fed by GS/HS/DS, NOT the "
                                  "vertex shader -- skipping interpolant pairing for it\n");
                }
                if (op.vs_bc && op.vs_bc_len) {
                    static unsigned said_vsi;
                    if (!said_vsi++)
                        d3d12_log("[madeira-d3d12] ml1031 pixel stage paired with its vertex "
                                  "stage (%u bytes) -- interpolants the VS does not write are "
                                  "zero-filled instead of declared, which is what Metal "
                                  "rejected the G-buffer pipelines over\n",
                                  (unsigned)op.vs_bc_len);
                }
                if (flags & MADEIRA_IR_PS_DUAL_SOURCE_BLEND) {
                    static unsigned said_ds;
                    if (said_ds++ < 8)
                        d3d12_log("[madeira-d3d12] ml1023 PS compiled for DUAL-SOURCE blending "
                                  "(unorm RT mask %#x, sample mask %#x)\n", unorm, op.ps_sample_mask);
                }
            }
            nl = 0;
            p->ps_fn = mad_convert_stage_opts(d, rs, desc->PS.pShaderBytecode, desc->PS.BytecodeLength, NULL, &p->ps_lib, "PS",
                                              NULL, 0, NULL, NULL, locs, &nl, &op);
            if (p->ps_fn) {
                if (air_ps.backend == MADEIRA_IR_BACKEND_AIRCONV) {   /* ml1011 */
                    p->ps_cb_bind = air_ps.cb_bind; p->ps_arg_bind = air_ps.arg_bind;
                    p->ps_arg_qwords = air_ps.arg_qwords; p->ps_nair = 0;
                    if (air_ps.nranges) {
                        p->ps_air = malloc((size_t)air_ps.nranges * sizeof *p->ps_air);
                        if (!p->ps_air) { pso_Release((ID3D12PipelineState *)p); return E_OUTOFMEMORY; }
                        memcpy(p->ps_air, air_ps.ranges, (size_t)air_ps.nranges * sizeof *p->ps_air);
                        p->ps_nair = air_ps.nranges;
                    }
                    /* A pipeline whose stages came from DIFFERENT compilers would
                     * need both ABIs bound at once; refuse rather than bind one
                     * stage's layout with the other's rules. */
                    if (p->backend != MADEIRA_IR_BACKEND_AIRCONV) {
                        d3d12_log("[madeira-d3d12] ml1011 mixed-backend pipeline (VS=%s, PS=sm5/dxbc); refused\n",
                                  p->backend == MADEIRA_IR_BACKEND_AIRCONV ? "sm5/dxbc" : "dxil");
                        pso_Release((ID3D12PipelineState *)p);
                        return E_FAIL;
                    }
                } else {
                    if (p->backend == MADEIRA_IR_BACKEND_AIRCONV) {
                        d3d12_log("[madeira-d3d12] ml1011 mixed-backend pipeline (VS=sm5/dxbc, PS=dxil); refused\n");
                        pso_Release((ID3D12PipelineState *)p);
                        return E_FAIL;
                    }
                    mad_apply_reflected_layout(p, rs, locs, nl, "PS");
                }
            }
        }
    }
    if (!p->vs_fn || (desc->PS.pShaderBytecode && !p->ps_fn)) { pso_Release((ID3D12PipelineState *)p); return E_FAIL; }

    /* Input layout -> vertex descriptor, through the attribute indices the
     * converted vertex shader reports. Element offsets follow D3D's append
     * rule; the per-slot stride is not part of a D3D12 pipeline, so the
     * tightest stride that covers the declared elements is used and every
     * draw checks it against the bound buffer's real stride. */
    memset(&vd, 0, sizeof vd);
    if (desc->InputLayout.NumElements && nvsin) {
        UINT running[16] = {0};
        if (said_inputs < 3) {
            said_inputs++;
            for (i = 0; i < nvsin && i < 32; i++)
                d3d12_log("[madeira-d3d12] VS input %u: '%s' -> attribute %u\n", i, vsin[i].name, vsin[i].attribute);
        }
        for (i = 0; i < desc->InputLayout.NumElements; i++) {
            const D3D12_INPUT_ELEMENT_DESC *el = &desc->InputLayout.pInputElementDescs[i];
            UINT slot = el->InputSlot, bytes, block, off, j, ai;
            uint32_t fmt = mad_vertex_format(el->Format);
            if (slot >= 16) continue;
            mad_format_info(el->Format, &bytes, &block);
            off = (el->AlignedByteOffset == D3D12_APPEND_ALIGNED_ELEMENT) ? ((running[slot] + 3) & ~3u) : el->AlignedByteOffset;
            if (off + bytes > running[slot]) running[slot] = off + bytes;
            for (j = 0; j < nvsin && j < 32; j++) {
                if (!mad_semantic_match(vsin[j].name, el->SemanticName, el->SemanticIndex)) continue;
                /* ml878: the converter's attributeIndex is the input's ORDINAL
                 * (attribute13 -> 1); the converted shader reads it from Metal
                 * attribute kIRStageInAttributeStartIndex (11) + ordinal. Every
                 * pipeline with an input layout failed with "attribute0(11) is
                 * missing from the vertex descriptor" before this. */
                ai = 11 + vsin[j].attribute;
                if (ai >= 31) break;
                if (!fmt) { d3d12_log("[madeira-d3d12] input element %s%u has vertex format %u with no Metal equivalent\n",
                                      el->SemanticName, el->SemanticIndex, (unsigned)el->Format); break; }
                vd.attributes[ai].format = fmt;
                vd.attributes[ai].offset = off;
                vd.attributes[ai].buffer_index = 6 + slot;
                vd.attribute_mask |= 1u << ai;
                vd.layouts[6 + slot].step_function = (el->InputSlotClass == D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA) ? 2 : 1;
                vd.layouts[6 + slot].step_rate = el->InstanceDataStepRate ? el->InstanceDataStepRate : 1;
                vd.layout_mask |= 1u << (6 + slot);
                has_vd = 1;
                break;
            }
            if (j == nvsin || j == 32) {
                static unsigned said_nomatch;
                if (said_nomatch++ < 8)
                    d3d12_log("[madeira-d3d12] input element %s%u matched no vertex-shader input\n", el->SemanticName, el->SemanticIndex);
            }
        }
        for (i = 0; i < 16; i++) if (vd.layout_mask & (1u << (6 + i))) {
            vd.layouts[6 + i].stride = (running[i] + 3) & ~3u;
            p->vb_stride[i] = vd.layouts[6 + i].stride;
            p->vb_mask |= 1u << i;
        }
    } else if (desc->InputLayout.NumElements) {
        d3d12_log("[madeira-d3d12] input layout has %u elements but the vertex shader reported no inputs\n",
                  desc->InputLayout.NumElements);
    }

    memset(&rp, 0, sizeof rp);
    rp.vertex_function = p->vs_fn;
    rp.fragment_function = p->ps_fn;
    rp.rasterization_enabled = true;
    {
        UINT req = desc->SampleDesc.Count ? desc->SampleDesc.Count : 1;
        UINT use = mad_clamp_sample_count(req);
        if (use != req) {
            static UINT warned_req;          /* one line per distinct request */
            if (warned_req != req) {
                warned_req = req;
                d3d12_log("[madeira-d3d12] ml1030 PSO sample count %u is not rasterisable "
                          "here -> using %u (pipeline creation used to FAIL outright, "
                          "dropping every draw)\n", req, use);
            }
        }
        rp.raster_sample_count = use;
    }
    rp.alpha_to_coverage_enabled = desc->BlendState.AlphaToCoverageEnable != 0;
    for (i = 0; i < desc->NumRenderTargets && i < 8; i++) {
        const D3D12_RENDER_TARGET_BLEND_DESC *b = &desc->BlendState.RenderTarget[desc->BlendState.IndependentBlendEnable ? i : 0];
        enum WMTPixelFormat pf;
        if (desc->RTVFormats[i] == DXGI_FORMAT_UNKNOWN) continue;
        if (!mad_map_texture_format(desc->RTVFormats[i], D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, &pf, &is_depth) || is_depth) {
            d3d12_log("[madeira-d3d12] pipeline render target %u format %u is not supported\n", i, (unsigned)desc->RTVFormats[i]);
            pso_Release((ID3D12PipelineState *)p); return E_NOTIMPL;
        }
        rp.colors[i].pixel_format = pf;
        rp.colors[i].blending_enabled = b->BlendEnable != 0;
        rp.colors[i].rgb_blend_operation = mad_blend_op(b->BlendOp);
        rp.colors[i].alpha_blend_operation = mad_blend_op(b->BlendOpAlpha);
        rp.colors[i].src_rgb_blend_factor = mad_blend_factor(b->SrcBlend);
        rp.colors[i].dst_rgb_blend_factor = mad_blend_factor(b->DestBlend);
        rp.colors[i].src_alpha_blend_factor = mad_blend_factor(b->SrcBlendAlpha);
        rp.colors[i].dst_alpha_blend_factor = mad_blend_factor(b->DestBlendAlpha);
        rp.colors[i].write_mask = mad_write_mask(b->RenderTargetWriteMask);
        if (b->LogicOpEnable) { static unsigned said; if (!said++) d3d12_log("[madeira-d3d12] logic ops are not implemented\n"); }
        {   /* ml1106, ml1107: every render target's blend state (D3D values; Metal values for rt0) */
            size_t used = strlen(p->blend);
            if (i == 0)
                snprintf(p->blend, sizeof p->blend, "indep=%u a2c=%u rt0:en=%u src=%u/%u dst=%u/%u op=%u/%u wm=%x mtl:src=%u/%u dst=%u/%u op=%u/%u",
                         (unsigned)desc->BlendState.IndependentBlendEnable, (unsigned)desc->BlendState.AlphaToCoverageEnable,
                         (unsigned)b->BlendEnable, (unsigned)b->SrcBlend, (unsigned)b->SrcBlendAlpha, (unsigned)b->DestBlend, (unsigned)b->DestBlendAlpha,
                         (unsigned)b->BlendOp, (unsigned)b->BlendOpAlpha, (unsigned)b->RenderTargetWriteMask,
                         (unsigned)rp.colors[i].src_rgb_blend_factor, (unsigned)rp.colors[i].src_alpha_blend_factor,
                         (unsigned)rp.colors[i].dst_rgb_blend_factor, (unsigned)rp.colors[i].dst_alpha_blend_factor, (unsigned)rp.colors[i].rgb_blend_operation,
                         (unsigned)rp.colors[i].alpha_blend_operation);
            else if (used < sizeof p->blend - 1)
                snprintf(p->blend + used, sizeof p->blend - used, " rt%u:en=%u src=%u/%u dst=%u/%u op=%u/%u wm=%x", i,
                         (unsigned)b->BlendEnable, (unsigned)b->SrcBlend, (unsigned)b->SrcBlendAlpha, (unsigned)b->DestBlend, (unsigned)b->DestBlendAlpha,
                         (unsigned)b->BlendOp, (unsigned)b->BlendOpAlpha, (unsigned)b->RenderTargetWriteMask);
        }
    }
    rp.depth_pixel_format = WMTPixelFormatInvalid;
    rp.stencil_pixel_format = WMTPixelFormatInvalid;
    if (desc->DSVFormat != DXGI_FORMAT_UNKNOWN) {
        enum WMTPixelFormat pf;
        if (!mad_map_texture_format(desc->DSVFormat, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, &pf, &is_depth) || !is_depth) {
            d3d12_log("[madeira-d3d12] pipeline depth format %u is not supported\n", (unsigned)desc->DSVFormat);
            pso_Release((ID3D12PipelineState *)p); return E_NOTIMPL;
        }
        rp.depth_pixel_format = pf;
        p->uses_depth = 1;
        if (pf == WMTPixelFormatDepth32Float_Stencil8) { rp.stencil_pixel_format = pf; p->uses_stencil = 1; }
    }
    switch (desc->PrimitiveTopologyType) {
    case D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT: rp.input_primitive_topology = WMTPrimitiveTopologyClassPoint; break;
    case D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE: rp.input_primitive_topology = WMTPrimitiveTopologyClassLine; break;
    default: rp.input_primitive_topology = WMTPrimitiveTopologyClassTriangle; break;
    }
    rp.max_tessellation_factor = 16;   /* Metal requires 1..64 even when unused */

    if (p->gs_emu) {   /* ml927 */
        struct WMTMeshRenderPipelineInfo mp; struct WMTGeometryEmulationInfo ge; obj_handle_t err = 0;
        memset(&mp, 0, sizeof mp); memset(&ge, 0, sizeof ge);
        memcpy(mp.colors, rp.colors, sizeof mp.colors);
        mp.alpha_to_coverage_enabled = rp.alpha_to_coverage_enabled;
        mp.rasterization_enabled = rp.rasterization_enabled;
        mp.raster_sample_count = rp.raster_sample_count;
        mp.depth_pixel_format = rp.depth_pixel_format; mp.stencil_pixel_format = rp.stencil_pixel_format;
        ge.stagein_library = p->si_lib; ge.vertex_library = p->vs_lib; ge.geometry_library = p->gs_lib; ge.fragment_library = p->ps_lib;
        snprintf(ge.vertex_function, sizeof ge.vertex_function, "%s", p->vs_name);
        snprintf(ge.geometry_function, sizeof ge.geometry_function, "%s", p->gs_name);
        if (p->ps_fn) snprintf(ge.fragment_function, sizeof ge.fragment_function, "%s", p->ps_name);
        ge.gs_vertex_size_bytes = p->gs_vertex_size; ge.gs_max_input_primitives = p->gs_max_prims;
        p->rps = MTLDevice_newGeometryEmulationPipelineState(d->mtl_device, &mp, &ge, &err);
        if (err) mad_log_nserror("geometry-emulation pipeline", err);
        { static unsigned said; if (said++ < 8) d3d12_log("[madeira-d3d12] geometry pipeline %s: vs '%s' gs '%s' ps '%s' (vertex %u B, %u prims/tg, %u targets)\n",
                                                        p->rps ? "created" : "FAILED", ge.vertex_function, ge.geometry_function, ge.fragment_function,
                                                        p->gs_vertex_size, p->gs_max_prims, desc->NumRenderTargets); }
        if (!p->rps) { p->gs_emu = 0; d3d12_log("[madeira-d3d12] geometry pipeline: falling back to a plain vertex pipeline (geometry shader DROPPED)\n"); }
    }
    /* ml1086: a hull+domain pipeline gets NO plain vertex pipeline. Its pixel
     * shader is fed by the domain shader, so the VS->PS pairing Metal checks
     * fails by construction ("Fragment input(s) ... not written by vertex
     * shader") -- ph-rdr51 lost two G-buffer material pipelines this way, and a
     * pipeline the game cannot create is a material it never draws. Only a
     * patch-list draw can use such a pipeline, and those go through the mesh
     * pipelines below. */
    if (!p->gs_emu && !p->has_tess) {
        obj_handle_t err = 0;
        p->rps = has_vd ? MTLDevice_newRenderPipelineStateVD(d->mtl_device, &rp, &vd, &err)
                        : MTLDevice_newRenderPipelineState(d->mtl_device, &rp, &err);
        if (err) mad_log_nserror(p->vs_name, err);
    }
    /* ml1083: hull+domain -> object/mesh pipeline, DXBC backend only (the DXIL
     * path has no tessellation emulation of its own yet). */
    if (p->has_tess && desc->HS.pShaderBytecode && desc->DS.pShaderBytecode && !desc->GS.pShaderBytecode &&
        p->backend == MADEIRA_IR_BACKEND_AIRCONV)
        mad_tess_build(d, rs, p, desc, &rp);
    /* ml1147: DXBC geometry shader -> object/mesh pipeline; the plain pipeline
     * above stays as the fallback for draws the mesh variants cannot take. */
    if (!p->tess && desc->GS.pShaderBytecode && desc->GS.BytecodeLength && !desc->HS.pShaderBytecode &&
        p->backend == MADEIRA_IR_BACKEND_AIRCONV && mad_bc_is_dxbc(desc->GS.pShaderBytecode, desc->GS.BytecodeLength))
    {
        mad_gsx_build(d, rs, p, desc, &rp, 0);
        /* ml1147b: UE's volume rasterizer draws each slice as a 4-vertex TRIANGLE
         * STRIP (ph-valley04: all 8 WriteToSlice draws were topology 5), and
         * the object/mesh functions are specialised on strip vs list. */
        if (desc->PrimitiveTopologyType == D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE || desc->PrimitiveTopologyType == D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE)
            mad_gsx_build(d, rs, p, desc, &rp, 1);
    }
    if (!p->rps && !p->tess && !p->tess_strip && desc->GS.pShaderBytecode && desc->GS.BytecodeLength) {
        /* ml1138: a geometry-shader pipeline we cannot build becomes a PLACEHOLDER
         * (draws with it are skipped and counted), not E_FAIL. UE5 creates
         * pipelines asynchronously; an E_FAIL for its WriteToSlice pipelines on the
         * device left the render thread waiting forever (the demo froze behind the
         * loading throbber). A missing effect is recoverable; a hang is not. */
        static unsigned said;
        if (said++ < 16)
            d3d12_log("[madeira-d3d12] ml1138 geometry-shader pipeline could not be built; returning a placeholder whose draws are skipped "
                      "(%u targets, gs %u B)\n", desc->NumRenderTargets, (unsigned)desc->GS.BytecodeLength);
    } else if (!p->rps && !p->tess) {
        d3d12_log("[madeira-d3d12] newRenderPipelineState failed (%u targets, depth %u, %u input elements%s)\n",
                  desc->NumRenderTargets, (unsigned)desc->DSVFormat, desc->InputLayout.NumElements,
                  p->has_tess ? ", tessellation" : "");
        pso_Release((ID3D12PipelineState *)p);
        return E_FAIL;
    }
    if (has_vd && p->rps) { p->rp = rp; p->vd = vd; p->has_vd = 1; p->device_handle = d->mtl_device; InitializeCriticalSection(&p->var_lock); }

    /* Depth-stencil state is encoder state in Metal; one object per pipeline. */
    memset(&dsi, 0, sizeof dsi);
    p->dbg_denable = desc->DepthStencilState.DepthEnable != 0;
    p->dbg_dfunc = (UINT8)desc->DepthStencilState.DepthFunc;
    p->dbg_dwrite = desc->DepthStencilState.DepthWriteMask == D3D12_DEPTH_WRITE_MASK_ALL;
    { unsigned wi; for (wi = 0; wi < 8; wi++) p->dbg_wmask[wi] = desc->BlendState.RenderTarget[wi].RenderTargetWriteMask; }
    p->dbg_senable = desc->DepthStencilState.StencilEnable != 0; p->dbg_sfunc = (UINT8)desc->DepthStencilState.FrontFace.StencilFunc;
    p->dbg_srmask = desc->DepthStencilState.StencilReadMask; p->dbg_swmask = desc->DepthStencilState.StencilWriteMask;
    if (desc->DepthStencilState.DepthEnable) {
        dsi.depth_compare_function = mad_compare(desc->DepthStencilState.DepthFunc);
        dsi.depth_write_enabled = desc->DepthStencilState.DepthWriteMask == D3D12_DEPTH_WRITE_MASK_ALL;
    } else {
        dsi.depth_compare_function = WMTCompareFunctionAlways;
        dsi.depth_write_enabled = false;
    }
    mad_stencil_face(&dsi.front_stencil, &desc->DepthStencilState.FrontFace, desc->DepthStencilState.StencilEnable,
                     desc->DepthStencilState.StencilReadMask, desc->DepthStencilState.StencilWriteMask);
    mad_stencil_face(&dsi.back_stencil, &desc->DepthStencilState.BackFace, desc->DepthStencilState.StencilEnable,
                     desc->DepthStencilState.StencilReadMask, desc->DepthStencilState.StencilWriteMask);
    p->dsso = MTLDevice_newDepthStencilState(d->mtl_device, &dsi);

    memset(&p->raster, 0, sizeof p->raster);
    p->raster.type = WMTRenderCommandSetRasterizerState;
    p->raster.fill_mode = desc->RasterizerState.FillMode == D3D12_FILL_MODE_WIREFRAME ? WMTTriangleFillModeLines : WMTTriangleFillModeFill;
    p->raster.cull_mode = desc->RasterizerState.CullMode == D3D12_CULL_MODE_FRONT ? WMTCullModeFront
                        : desc->RasterizerState.CullMode == D3D12_CULL_MODE_BACK ? WMTCullModeBack : WMTCullModeNone;
    p->raster.depth_clip_mode = desc->RasterizerState.DepthClipEnable ? WMTDepthClipModeClip : WMTDepthClipModeClamp;
    p->raster.winding = desc->RasterizerState.FrontCounterClockwise ? WMTWindingCounterClockwise : WMTWindingClockwise;
    p->raster.depth_bias = (float)desc->RasterizerState.DepthBias;
    p->raster.scole_scale = desc->RasterizerState.SlopeScaledDepthBias;
    p->raster.depth_bias_clamp = desc->RasterizerState.DepthBiasClamp;

    if (said_pso < 8) {
        said_pso++;
        d3d12_log("[madeira-d3d12] pipeline: %u targets (fmt %u), depth fmt %u, %u input elements%s, %s\n",
                  desc->NumRenderTargets, (unsigned)desc->RTVFormats[0], (unsigned)desc->DSVFormat,
                  desc->InputLayout.NumElements, has_vd ? " (vertex descriptor)" : "", p->ps_fn ? "VS+PS" : "VS only");
    }
    hr = pso_QI((ID3D12PipelineState *)p, riid, out);
    pso_Release((ID3D12PipelineState *)p);
    return hr;
}


static HRESULT STDMETHODCALLTYPE device_CreateComputePipelineState(ID3D12Device *This,
        const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc, REFIID riid, void **out) {
    struct mad_device *d = (struct mad_device *)This;
    struct mad_pso *p;
    struct WMTComputePipelineInfo ci;
    obj_handle_t err = 0;
    static unsigned said;
    HRESULT hr;
    if (!desc || !out) return E_INVALIDARG;
    if (!desc->CS.pShaderBytecode) return E_INVALIDARG;
    mad_resolve_target(d);
    p = calloc(1, sizeof *p);
    if (!p) return E_OUTOFMEMORY;
    p->vtbl = &g_pso_vtbl; p->refs = 1; p->iid = &IID_ID3D12PipelineState; p->name = "ComputePipelineState";
    p->is_compute = 1;
    {
        struct madeira_ir_loc locs[MAD_LOC_MAX]; unsigned nl = 0;
        struct mad_air_out air;
        struct mad_convert_opts o;
        char entry[MADEIRA_IR_ENTRY_MAX];
        memset(&air, 0, sizeof air);
        memset(&o, 0, sizeof o);
        o.air = &air;
        o.name_out = entry; o.name_cap = sizeof entry;
        p->vs_fn = mad_convert_stage_opts(d, (struct mad_rootsig *)desc->pRootSignature, desc->CS.pShaderBytecode,
                                     desc->CS.BytecodeLength, NULL, &p->vs_lib, "CS", NULL, 0, NULL, p->tg, locs, &nl, &o);
        p->backend = air.backend;
        if (air.backend == MADEIRA_IR_BACKEND_AIRCONV) {   /* ml1008 */
            static unsigned said_air;
            p->cb_bind = air.cb_bind; p->arg_bind = air.arg_bind;
            p->arg_qwords = air.arg_qwords;
            p->nair = 0;
            if (air.nranges) {   /* ml1010: exactly what this shader declared */
                p->air = malloc((size_t)air.nranges * sizeof *p->air);
                if (!p->air) { pso_Release((ID3D12PipelineState *)p); return E_OUTOFMEMORY; }
                memcpy(p->air, air.ranges, (size_t)air.nranges * sizeof *p->air);
                p->nair = air.nranges;
            }
            if (said_air++ < 12) {
                unsigned k;
                d3d12_log("[madeira-d3d12] ml1008 CS via the sm5/dxbc backend: cbTable=%d argTable=%d "
                          "qwords=%u ranges=%u tg=%ux%ux%u\n",
                          air.cb_bind == ~0u ? -1 : (int)air.cb_bind,
                          air.arg_bind == ~0u ? -1 : (int)air.arg_bind,
                          air.arg_qwords, air.nranges, p->tg[0], p->tg[1], p->tg[2]);
                for (k = 0; k < air.nranges; k++) {
                    static const char *cls[4] = { "b", "s", "t", "u" };
                    d3d12_log("[madeira-d3d12]   range %s%u space %u (id %u) -> %s word %u, flags %#x\n",
                              air.ranges[k].type < 4 ? cls[air.ranges[k].type] : "?",
                              air.ranges[k].lower_bound, air.ranges[k].space, air.ranges[k].range_id,
                              air.ranges[k].cb_table ? "cbtable" : "argtable",
                              air.ranges[k].ptr_offset, air.ranges[k].flags);
                }
            }
        }
        {   /* ml931; ml1990: opt-in (MADEIRA_D3D12_CS_DUMP=1). Writing up to
             * 400 files into C:\madeira-cs on every run cost startup time for
             * a diagnostic that is only wanted while chasing one kernel. */
            char fn[96]; static unsigned ndump; static int dump_on = -1;
            if (dump_on < 0) {
                char v[4] = {0};
                DWORD n = GetEnvironmentVariableA("MADEIRA_D3D12_CS_DUMP", v, sizeof v);
                dump_on = n == 1 && v[0] == '1';
                if (dump_on) d3d12_log("[madeira-d3d12] ml1990 compute bytecode dump to C:\\madeira-cs enabled (MADEIRA_D3D12_CS_DUMP=1)\n");
            }
            if (dump_on && ndump++ < 400) { snprintf(fn, sizeof fn, "cs_%p_%u.dxil", (void *)p, (unsigned)desc->CS.BytecodeLength); mad_dump_blob(fn, desc->CS.pShaderBytecode, desc->CS.BytecodeLength); }
        }
        snprintf(p->vs_name, sizeof p->vs_name, "%s", entry[0] ? entry : g_last_entry);   /* ml880 */
        /* ml1008: the reflected top-level layout is the DXIL converter's, and
         * means nothing to the DXBC backend, which reports its own tables. */
        if (p->vs_fn && air.backend != MADEIRA_IR_BACKEND_AIRCONV)
            mad_apply_reflected_layout(p, (struct mad_rootsig *)desc->pRootSignature, locs, nl, "CS");
    }
    if (!p->vs_fn) {
        /* ml1139: a compute shader the converter refuses becomes a PLACEHOLDER
         * pipeline (its dispatches are skipped and counted), not E_FAIL. UE5 treats
         * a failed CreateComputePipelineState as fatal (PipelineStateCache.cpp:437),
         * and under this runtime a UE fatal presents as a freeze. A missing effect
         * is recoverable and shows how far the title gets. */
        static unsigned said_ph;
        if (said_ph++ < 16)
            d3d12_log("[madeira-d3d12] ml1139 compute shader could not be converted (%u bytes); returning a placeholder whose dispatches are skipped\n",
                      (unsigned)desc->CS.BytecodeLength);
        hr = pso_QI((ID3D12PipelineState *)p, riid, out);
        pso_Release((ID3D12PipelineState *)p);
        return hr;
    }
    if (!p->tg[0]) { p->tg[0] = 1; }
    if (!p->tg[1]) { p->tg[1] = 1; }
    if (!p->tg[2]) { p->tg[2] = 1; }
    memset(&ci, 0, sizeof ci);
    ci.compute_function = p->vs_fn;
    p->cps = MTLDevice_newComputePipelineState(d->mtl_device, &ci, &err);
    if (err) mad_log_nserror("compute pipeline", err);
    if (!p->cps) {
        d3d12_log("[madeira-d3d12] newComputePipelineState failed\n");
        pso_Release((ID3D12PipelineState *)p);
        return E_FAIL;
    }
    if (said < 8) {
        said++;
        d3d12_log("[madeira-d3d12] compute pipeline: threadgroup %ux%ux%u\n", p->tg[0], p->tg[1], p->tg[2]);
    }
    hr = pso_QI((ID3D12PipelineState *)p, riid, out);
    pso_Release((ID3D12PipelineState *)p);
    return hr;
}

/* ---- render recording ---------------------------------------------------- */
/* ---- recording ------------------------------------------------------------ */
static void mad_subresource(const struct mad_resource *r, UINT sub, UINT *level, UINT *slice) {
    UINT mips = r->desc.MipLevels ? r->desc.MipLevels : 1;
    *level = sub % mips; *slice = sub / mips;
}
static void mad_mip_dims(const struct mad_resource *r, UINT level, UINT *w, UINT *h, UINT *d) {
    *w = (UINT)(r->desc.Width >> level); if (!*w) *w = 1;
    *h = r->desc.Height >> level; if (!*h) *h = 1;
    *d = (r->desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) ? (r->desc.DepthOrArraySize >> level) : 1;
    if (!*d) *d = 1;
}

static void STDMETHODCALLTYPE list_OMSetRenderTargets(ID3D12GraphicsCommandList *This, UINT n,
        const D3D12_CPU_DESCRIPTOR_HANDLE *rtvs, BOOL single, const D3D12_CPU_DESCRIPTOR_HANDLE *dsv) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_cmd *c = mad_list_push(l, MC_RTS);
    UINT i;
    if (!c) return;
    if (n > 8) n = 8;
    for (i = 0; i < n && rtvs; i++) {
        /* With `single`, the handles are consecutive slots after the first. */
        SIZE_T h = single ? rtvs[0].ptr + i * sizeof(struct mad_rtv) : rtvs[i].ptr;
        c->u.rts.rt[i] = mad_slot_resource(h); c->u.rts.v[i] = mad_slot_view(h);
    }
    c->u.rts.n = rtvs ? n : 0;
    c->u.rts.depth = dsv ? mad_slot_resource(dsv->ptr) : NULL;
    c->u.rts.dv = mad_slot_view(dsv ? dsv->ptr : 0);
}
static void STDMETHODCALLTYPE list_ClearRenderTargetView(ID3D12GraphicsCommandList *This,
        D3D12_CPU_DESCRIPTOR_HANDLE rtv, const FLOAT rgba[4], UINT n, const D3D12_RECT *rects) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_resource *rt = mad_slot_resource(rtv.ptr);
    struct mad_cmd *c;
    static unsigned said_rects;
    if (!rt) return;
    if (n && rects && !said_rects++) d3d12_log("[madeira-d3d12] ClearRenderTargetView: rects are ignored; the whole target is cleared\n");
    c = mad_list_push(l, MC_CLEAR_RT);
    if (!c) return;
    c->u.clear.res = rt; c->u.clear.v = mad_slot_view(rtv.ptr);
    if (rgba) memcpy(c->u.clear.rgba, rgba, sizeof c->u.clear.rgba);
}
static void STDMETHODCALLTYPE list_ClearDepthStencilView(ID3D12GraphicsCommandList *This,
        D3D12_CPU_DESCRIPTOR_HANDLE dsv, D3D12_CLEAR_FLAGS flags, FLOAT depth, UINT8 stencil,
        UINT n, const D3D12_RECT *rects) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_resource *d = mad_slot_resource(dsv.ptr);
    struct mad_cmd *c;
    static unsigned said, said_rect;
    if (!d) return;
    if (n && rects && said_rect++ < 4)
        d3d12_log("[madeira-d3d12] ClearDepthStencilView: %u clear rects ignored (whole view cleared)\n", n);
    if (said++ < 24)
        d3d12_log("[madeira-d3d12] ClearDepthStencilView: res %p %ux%u flags %#x depth %g stencil %u\n", (void *)d,
                  d->width, d->height, (unsigned)flags, depth, (unsigned)stencil);
    c = mad_list_push(l, MC_CLEAR_DS);
    if (!c) return;
    c->u.clear.res = d; c->u.clear.v = mad_slot_view(dsv.ptr); c->u.clear.depth = depth; c->u.clear.stencil = stencil;
    c->u.clear.flags = (UINT8)(flags & (D3D12_CLEAR_FLAG_DEPTH | D3D12_CLEAR_FLAG_STENCIL));
    if (!c->u.clear.flags) c->u.clear.flags = D3D12_CLEAR_FLAG_DEPTH | D3D12_CLEAR_FLAG_STENCIL;
}
static void STDMETHODCALLTYPE list_SetPipelineState(ID3D12GraphicsCommandList *This, ID3D12PipelineState *pso) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_PSO);
    if (c) c->u.pso = (struct mad_pso *)pso;
}
static void STDMETHODCALLTYPE list_SetGraphicsRootSignature(ID3D12GraphicsCommandList *This, ID3D12RootSignature *rs) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_ROOTSIG);
    if (c) c->u.rootsig = (struct mad_rootsig *)rs;
}
static void STDMETHODCALLTYPE list_SetComputeRootSignature(ID3D12GraphicsCommandList *This, ID3D12RootSignature *rs) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_CROOTSIG);
    if (c) c->u.rootsig = (struct mad_rootsig *)rs;
}
static void mad_record_croot(struct mad_list *l, UINT index, UINT64 value, int resolve) {
    struct mad_cmd *c;
    if (index >= MAD_ROOT_PARAM_MAX) return;
    c = mad_list_push(l, MC_CROOT);
    if (!c) return;
    c->u.root.index = index; c->u.root.value = value;
    if (resolve) { UINT64 off = 0; mad_list_note_used(l, mad_resolve_address(l->device, value, &off)); }
}
static void STDMETHODCALLTYPE list_SetComputeRootConstantBufferView(ID3D12GraphicsCommandList *This, UINT index, D3D12_GPU_VIRTUAL_ADDRESS a) { mad_record_croot((struct mad_list *)This, index, a, 1); }
static void STDMETHODCALLTYPE list_SetComputeRootShaderResourceView(ID3D12GraphicsCommandList *This, UINT index, D3D12_GPU_VIRTUAL_ADDRESS a) { mad_record_croot((struct mad_list *)This, index, a, 1); }
static void STDMETHODCALLTYPE list_SetComputeRootUnorderedAccessView(ID3D12GraphicsCommandList *This, UINT index, D3D12_GPU_VIRTUAL_ADDRESS a) { mad_record_croot((struct mad_list *)This, index, a, 1); }
static void STDMETHODCALLTYPE list_SetComputeRootDescriptorTable(ID3D12GraphicsCommandList *This, UINT index, D3D12_GPU_DESCRIPTOR_HANDLE h) { mad_record_croot((struct mad_list *)This, index, h.ptr, 0); }
static void STDMETHODCALLTYPE list_SetComputeRoot32BitConstants(ID3D12GraphicsCommandList *This,
        UINT index, UINT n, const void *data, UINT dst_offset) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_cmd *c;
    if (!n || !data || index >= MAD_ROOT_PARAM_MAX || dst_offset + n > 64) return;
    if (!mad_grow((void **)&l->cdata, &l->cdcap, l->ncdata + n, sizeof *l->cdata)) return;
    c = mad_list_push(l, MC_CROOT_CONST);
    if (!c) return;
    memcpy(&l->cdata[l->ncdata], data, n * 4);
    c->u.rconst.index = index; c->u.rconst.dst = dst_offset; c->u.rconst.n = n; c->u.rconst.data = l->ncdata;
    l->ncdata += n;
}
static void STDMETHODCALLTYPE list_SetComputeRoot32BitConstant(ID3D12GraphicsCommandList *This, UINT index, UINT data, UINT dst_offset) {
    list_SetComputeRoot32BitConstants(This, index, 1, &data, dst_offset);
}
/* ml892: UAV clears for BUFFER views through the blit fill. The CPU handle
 * points at our descriptor entry, whose address+size name the range; the
 * resource is found by address. Metal fills bytes, so a value whose four
 * bytes are equal is exact. Texture UAV clears are not implemented yet.
 *
 * ml1151: anything else used to be approximated by its low byte -- a clear to
 * 1 wrote 0x01010101 into every element (ph-valley09: UE 5.0 clears Nanite /
 * instance-culling buffers to 1). Now the value is copied from a small shared
 * buffer holding it repeated, kept per device for the few distinct values a
 * title uses. D3D12 clears raw and structured views with Values[0] per dword,
 * which is also exact for the R32 typed views these clears target. */
static obj_handle_t mad_fill_pattern(struct mad_device *d, UINT32 v) {
    obj_handle_t buf = 0; unsigned i;
    AcquireSRWLockExclusive(&d->fillpat_lock);
    for (i = 0; i < d->nfillpat; i++) if (d->fillpat[i].value == v) { buf = d->fillpat[i].buf; break; }
    if (!buf && d->nfillpat < (sizeof d->fillpat / sizeof d->fillpat[0])) {
        struct WMTBufferInfo bi;
        memset(&bi, 0, sizeof bi); bi.length = MAD_FILLPAT_BYTES; bi.options = WMTResourceStorageModeShared;
        buf = MTLDevice_newBuffer(d->mtl_device, &bi);
        if (buf && bi.memory.ptr) {
            UINT32 *w = (UINT32 *)bi.memory.ptr; UINT64 k;
            for (k = 0; k < MAD_FILLPAT_BYTES / 4; k++) w[k] = v;
            mad_resident(d, buf);
            d->fillpat[d->nfillpat].value = v; d->fillpat[d->nfillpat].buf = buf; d->nfillpat++;
            d3d12_log("[madeira-d3d12] ml1151 UAV clear value %#x: exact pattern buffer %u of %u\n", v, d->nfillpat, (unsigned)(sizeof d->fillpat / sizeof d->fillpat[0]));
        } else if (buf) { NSObject_release(buf); buf = 0; }
    }
    ReleaseSRWLockExclusive(&d->fillpat_lock);
    return buf;
}
static void mad_record_uav_clear(ID3D12GraphicsCommandList *This, D3D12_CPU_DESCRIPTOR_HANDLE cpu, ID3D12Resource *res, const UINT32 v[4], const char *what) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_descriptor *e = (struct mad_descriptor *)cpu.ptr;
    struct mad_resource *r; UINT64 off = 0; UINT64 len;
    struct mad_cmd *c;
    static unsigned said_tex, said_approx;
    if (!e || !l) return;
    if (!e->gpu_va) { if (said_tex++ < 2) d3d12_log("[madeira-d3d12] %s on a texture view is not implemented; skipped\n", what); return; }
    /* ml1157: the application names the resource; use it. Resolving the view's
     * address picked whichever placed resource aliased it, which could be one
     * the application frees before this list runs. */
    r = (struct mad_resource *)res;
    if (r && r->buffer && r->gpu_address && e->gpu_va >= r->gpu_address && e->gpu_va < r->gpu_address + r->size) off = e->gpu_va - r->gpu_address;
    else r = mad_resolve_address(l->device, e->gpu_va, &off);
    if (!r || !r->buffer) return;
    len = e->metadata & 0xffffffffu;
    if (!len || off + len > r->size) len = r->size > off ? r->size - off : 0;
    if (!len) return;
    c = mad_list_push(l, MC_FILL_BB);
    if (!c) return;
    c->u.fill.res = r; c->u.fill.off = off; c->u.fill.len = len;
    {
        UINT32 x = v ? v[0] : 0; UINT8 b = (UINT8)(x & 0xff);
        int exact = v && v[0] == v[1] && v[1] == v[2] && v[2] == v[3] &&
                    ((x >> 8) & 0xff) == b && ((x >> 16) & 0xff) == b && ((x >> 24) & 0xff) == b;
        c->u.fill.byte = b; c->u.fill.pattern = 0;
        if (!(((x >> 8) & 0xff) == b && ((x >> 16) & 0xff) == b && ((x >> 24) & 0xff) == b))
        {
            static unsigned said_pat;
            c->u.fill.pattern = mad_fill_pattern(l->device, x);   /* ml1151 */
            if (c->u.fill.pattern && said_pat++ < 16)
                d3d12_log("[madeira-d3d12] ml1151 %s value %#x exact: resource '%s' %llu bytes, range +%llu len %llu (gpu 0x%llx)\n",
                          what, x, r->name ? r->name : "?", (unsigned long long)r->size, (unsigned long long)off,
                          (unsigned long long)len, (unsigned long long)r->gpu_address);
        }
        if (!exact && !c->u.fill.pattern && said_approx++ < 4)
            d3d12_log("[madeira-d3d12] %s with value %#x is approximated by byte %#x (no pattern buffer)\n", what, x, b);
    }
}
static void STDMETHODCALLTYPE list_ClearUnorderedAccessViewUint(ID3D12GraphicsCommandList *This,
        D3D12_GPU_DESCRIPTOR_HANDLE gpu, D3D12_CPU_DESCRIPTOR_HANDLE cpu, ID3D12Resource *res,
        const UINT values[4], UINT n, const D3D12_RECT *rects) {
    (void)gpu; (void)n; (void)rects;
    mad_record_uav_clear(This, cpu, res, values, "ClearUnorderedAccessViewUint");
}
static void STDMETHODCALLTYPE list_ClearUnorderedAccessViewFloat(ID3D12GraphicsCommandList *This,
        D3D12_GPU_DESCRIPTOR_HANDLE gpu, D3D12_CPU_DESCRIPTOR_HANDLE cpu, ID3D12Resource *res,
        const FLOAT values[4], UINT n, const D3D12_RECT *rects) {
    UINT32 u[4]; int i;
    (void)gpu; (void)n; (void)rects;
    for (i = 0; i < 4; i++) memcpy(&u[i], &values[i], 4);
    mad_record_uav_clear(This, cpu, res, u, "ClearUnorderedAccessViewFloat");
}
static void STDMETHODCALLTYPE list_OMSetBlendFactor(ID3D12GraphicsCommandList *This, const FLOAT f[4]) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_BLEND_FACTOR);
    if (c) { if (f) memcpy(c->u.blend.rgba, f, sizeof c->u.blend.rgba); else { c->u.blend.rgba[0] = c->u.blend.rgba[1] = c->u.blend.rgba[2] = c->u.blend.rgba[3] = 1.0f; } }
}
static void STDMETHODCALLTYPE list_DiscardResource(ID3D12GraphicsCommandList *This, ID3D12Resource *res, const D3D12_DISCARD_REGION *region) {
    (void)This; (void)res; (void)region;   /* a hint; nothing to do */
    InterlockedIncrement(&g_discards);    /* ml1137: does the application use it at all? */
}
static void STDMETHODCALLTYPE list_OMSetStencilRef(ID3D12GraphicsCommandList *This, UINT ref) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_STENCIL_REF);
    if (c) c->u.stencil_ref = ref;
}
static void mad_record_root(struct mad_list *l, UINT index, UINT64 value, int resolve) {
    struct mad_cmd *c;
    if (index >= MAD_ROOT_PARAM_MAX) {
        static unsigned said;
        if (!said++) d3d12_log("[madeira-d3d12] root parameter index %u is beyond this build's limit\n", index);
        return;
    }
    c = mad_list_push(l, MC_ROOT);
    if (!c) return;
    c->u.root.index = index; c->u.root.value = value;
    if (resolve) {
        UINT64 off = 0;
        mad_list_note_used(l, mad_resolve_address(l->device, value, &off));
    }
}
static void STDMETHODCALLTYPE list_SetGraphicsRootConstantBufferView(ID3D12GraphicsCommandList *This,
        UINT index, D3D12_GPU_VIRTUAL_ADDRESS addr) { mad_record_root((struct mad_list *)This, index, addr, 1); }
static void STDMETHODCALLTYPE list_SetGraphicsRootShaderResourceView(ID3D12GraphicsCommandList *This,
        UINT index, D3D12_GPU_VIRTUAL_ADDRESS addr) { mad_record_root((struct mad_list *)This, index, addr, 1); }
static void STDMETHODCALLTYPE list_SetGraphicsRootUnorderedAccessView(ID3D12GraphicsCommandList *This,
        UINT index, D3D12_GPU_VIRTUAL_ADDRESS addr) { mad_record_root((struct mad_list *)This, index, addr, 1); }
static void STDMETHODCALLTYPE list_SetGraphicsRootDescriptorTable(ID3D12GraphicsCommandList *This,
        UINT index, D3D12_GPU_DESCRIPTOR_HANDLE h) {
    /* The handle already IS the address of the first descriptor. */
    mad_record_root((struct mad_list *)This, index, h.ptr, 0);
}
static void STDMETHODCALLTYPE list_SetGraphicsRoot32BitConstants(ID3D12GraphicsCommandList *This,
        UINT index, UINT n, const void *data, UINT dst_offset) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_cmd *c;
    if (!n || !data || index >= MAD_ROOT_PARAM_MAX || dst_offset + n > 64) return;
    if (!mad_grow((void **)&l->cdata, &l->cdcap, l->ncdata + n, sizeof *l->cdata)) return;
    c = mad_list_push(l, MC_ROOT_CONST);
    if (!c) return;
    memcpy(&l->cdata[l->ncdata], data, n * 4);
    c->u.rconst.index = index; c->u.rconst.dst = dst_offset; c->u.rconst.n = n; c->u.rconst.data = l->ncdata;
    l->ncdata += n;
}
static void STDMETHODCALLTYPE list_SetGraphicsRoot32BitConstant(ID3D12GraphicsCommandList *This,
        UINT index, UINT data, UINT dst_offset) { list_SetGraphicsRoot32BitConstants(This, index, 1, &data, dst_offset); }
static void STDMETHODCALLTYPE list_SetDescriptorHeaps(ID3D12GraphicsCommandList *This,
        UINT n, ID3D12DescriptorHeap *const *heaps) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_cmd *c;
    UINT i;
    if (!heaps) return;
    c = mad_list_push(l, MC_HEAPS);
    if (!c) return;
    for (i = 0; i < n; i++) {
        struct mad_heap *h = (struct mad_heap *)heaps[i];
        if (!h || !h->buffer) continue;
        if (h->type == D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER) c->u.heaps.smp = h; else c->u.heaps.srv = h;
    }
}
static void STDMETHODCALLTYPE list_RSSetViewports(ID3D12GraphicsCommandList *This, UINT n, const D3D12_VIEWPORT *vp) {
    struct mad_cmd *c;
    if (!n || !vp) return;
    c = mad_list_push((struct mad_list *)This, MC_VP);
    if (c) c->u.vp = vp[0];
}
static void STDMETHODCALLTYPE list_RSSetScissorRects(ID3D12GraphicsCommandList *This, UINT n, const D3D12_RECT *r) {
    struct mad_cmd *c;
    if (!n || !r) return;
    c = mad_list_push((struct mad_list *)This, MC_SCISSOR);
    if (c) c->u.scissor = r[0];
}
static void STDMETHODCALLTYPE list_IASetPrimitiveTopology(ID3D12GraphicsCommandList *This, D3D12_PRIMITIVE_TOPOLOGY t) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_TOPO);
    static unsigned said;
    if (c) c->u.topo = t;
    if (t >= D3D_PRIMITIVE_TOPOLOGY_LINELIST_ADJ && !said++)
        d3d12_log("[madeira-d3d12] topology %u (adjacency or patches) drawn as triangles\n", (unsigned)t);
}
static void STDMETHODCALLTYPE list_IASetIndexBuffer(ID3D12GraphicsCommandList *This, const D3D12_INDEX_BUFFER_VIEW *view) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_cmd *c = mad_list_push(l, MC_IB);
    UINT64 off = 0;
    if (!c) return;
    if (!view) return;   /* an unbound index buffer */
    c->u.ib.res = mad_resolve_address(l->device, view->BufferLocation, &off);
    c->u.ib.off = off;
    c->u.ib.type = view->Format == DXGI_FORMAT_R32_UINT ? WMTIndexTypeUInt32 : WMTIndexTypeUInt16;
    if (!c->u.ib.res) {
        static unsigned said;
        if (!said++) d3d12_log("[madeira-d3d12] index buffer address %llx matches no live resource\n",
                               (unsigned long long)view->BufferLocation);
    }
}
static void STDMETHODCALLTYPE list_IASetVertexBuffers(ID3D12GraphicsCommandList *This, UINT start, UINT n,
        const D3D12_VERTEX_BUFFER_VIEW *views) {
    struct mad_list *l = (struct mad_list *)This;
    UINT i;
    for (i = 0; i < n; i++) {
        struct mad_cmd *c = mad_list_push(l, MC_VB);
        UINT64 off = 0;
        if (!c) return;
        c->u.vb.slot = start + i;
        if (views && views[i].BufferLocation) {
            c->u.vb.res = mad_resolve_address(l->device, views[i].BufferLocation, &off);
            c->u.vb.off = off;
            c->u.vb.stride = views[i].StrideInBytes;
        }
    }
}
static void STDMETHODCALLTYPE list_DrawInstanced(ID3D12GraphicsCommandList *This,
        UINT vcount, UINT icount, UINT vstart, UINT istart) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_DRAW);
    if (!c) return;
    c->u.draw.vcount = vcount; c->u.draw.icount = icount; c->u.draw.vstart = vstart; c->u.draw.istart = istart;
}
static void STDMETHODCALLTYPE list_DrawIndexedInstanced(ID3D12GraphicsCommandList *This,
        UINT icount, UINT inst, UINT start, INT base, UINT istart) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_DRAW_INDEXED);
    if (!c) return;
    c->u.drawi.icount = icount; c->u.drawi.inst = inst; c->u.drawi.start = start;
    c->u.drawi.base = base; c->u.drawi.istart = istart;
}
static void STDMETHODCALLTYPE list_Dispatch(ID3D12GraphicsCommandList *This, UINT x, UINT y, UINT z) {
    struct mad_cmd *c = mad_list_push((struct mad_list *)This, MC_DISPATCH);
    if (c) { c->u.dispatch.x = x; c->u.dispatch.y = y; c->u.dispatch.z = z; }
}
static void STDMETHODCALLTYPE list_ResourceBarrier(ID3D12GraphicsCommandList *This, UINT n, const D3D12_RESOURCE_BARRIER *b) {
    /* ml1091: recorded. Metal tracks hazards only for DIRECTLY declared
     * resources; a barrier here is the one place the application tells us a
     * producer must finish before a consumer that reaches the resource through
     * an argument table. At replay it closes an open compute or blit encoder
     * (render passes are closed by their target changes), and the encoder
     * fence chain does the rest. Consecutive barrier calls fold into one. */
    struct mad_list *l = (struct mad_list *)This;
    struct mad_cmd *c; UINT i;
    if (!n) return;
    InterlockedIncrement(&g_barriers);
    if (l->ncmds && l->cmds[l->ncmds - 1].kind == MC_BARRIER) c = &l->cmds[l->ncmds - 1];
    else { c = mad_list_push(l, MC_BARRIER); if (!c) return; }
    if (c->u.barrier.n == 0 && !c->u.barrier.all) c->u.barrier.cls_noref = BC_NONE;
    for (i = 0; i < n; i++) {   /* ml1116: fence-chain = 3 waits only for resources an encoder in flight wrote */
        struct mad_resource *r = NULL;
        UINT8 cls = BC_ALL;
        const UINT W = D3D12_RESOURCE_STATE_RENDER_TARGET | D3D12_RESOURCE_STATE_UNORDERED_ACCESS | D3D12_RESOURCE_STATE_DEPTH_WRITE |
                       D3D12_RESOURCE_STATE_STREAM_OUT | D3D12_RESOURCE_STATE_COPY_DEST | D3D12_RESOURCE_STATE_RESOLVE_DEST;
        if (b[i].Type == D3D12_RESOURCE_BARRIER_TYPE_TRANSITION) {
            UINT bs = (UINT)b[i].Transition.StateBefore, as = (UINT)b[i].Transition.StateAfter;
            r = (struct mad_resource *)b[i].Transition.pResource;
            /* ml1137: COMMON on either side and any write after are "wait for everything" */
            if (b[i].Flags & D3D12_RESOURCE_BARRIER_FLAG_BEGIN_ONLY) cls = BC_RAR;
            else if (!as || (as & W) || !bs) cls = BC_ALL;
            else if (!(bs & W)) cls = BC_RAR;
            else if (!(bs & ~(UINT)(D3D12_RESOURCE_STATE_RENDER_TARGET | D3D12_RESOURCE_STATE_DEPTH_WRITE))) cls = BC_RAW_ATT;
            else if (bs == D3D12_RESOURCE_STATE_COPY_DEST) cls = BC_RAW_COPY;
            else if (bs == D3D12_RESOURCE_STATE_UNORDERED_ACCESS) cls = BC_RAW_UAV;
        } else if (b[i].Type == D3D12_RESOURCE_BARRIER_TYPE_UAV) {
            r = (struct mad_resource *)b[i].UAV.pResource;
            cls = BC_RAW_UAV;   /* UAV accesses happen only in compute and render encoders */
        }
        if (!r) {
            c->u.barrier.all = 1;
            if (c->u.barrier.cls_noref == BC_NONE || cls > c->u.barrier.cls_noref) c->u.barrier.cls_noref = cls;
            continue;
        }
        if (c->u.barrier.n < 8) { c->u.barrier.cls[c->u.barrier.n] = cls; c->u.barrier.res[c->u.barrier.n++] = r; }
        else { c->u.barrier.all = 1; c->u.barrier.cls_noref = BC_ALL; }
    }
}
/* ml889: ExecuteIndirect. D3D12's argument records are byte-for-byte Metal's
 * indirect argument structs (DRAW_ARGUMENTS == MTLDrawPrimitivesIndirectArguments,
 * DRAW_INDEXED_ARGUMENTS == MTLDrawIndexedPrimitivesIndirectArguments,
 * DISPATCH_ARGUMENTS == MTLDispatchThreadgroupsIndirectArguments), so a
 * single-argument signature is one indirect draw/dispatch per record. Metal
 * has no count buffer: MaxCommandCount records are issued, and a record the
 * GPU zeroed draws nothing. Signatures with root-constant/VBV/IBV changes per
 * record are refused by name. */
static void STDMETHODCALLTYPE list_ExecuteIndirect(ID3D12GraphicsCommandList *This, ID3D12CommandSignature *sig,
        UINT max_count, ID3D12Resource *args, UINT64 args_off, ID3D12Resource *count_buf, UINT64 count_off) {
    struct mad_cmdsig *cs = (struct mad_cmdsig *)sig;
    struct mad_cmd *c;
    enum mad_ck kind;
    static unsigned said_multi, said_count, said_big;
    if (!cs || !args || !max_count) return;
    if (cs->desc.NumArgumentDescs != 1) {
        if (said_multi++ < 4) d3d12_log("[madeira-d3d12] ExecuteIndirect: signature with %u argument descs is not implemented; skipped\n", cs->desc.NumArgumentDescs);
        return;
    }
    switch (cs->args[0].Type) {
    case D3D12_INDIRECT_ARGUMENT_TYPE_DRAW: kind = MC_DRAW_INDIRECT; break;
    case D3D12_INDIRECT_ARGUMENT_TYPE_DRAW_INDEXED: kind = MC_DRAW_INDEXED_INDIRECT; break;
    case D3D12_INDIRECT_ARGUMENT_TYPE_DISPATCH: kind = MC_DISPATCH_INDIRECT; break;
    default:
        if (said_multi++ < 4) d3d12_log("[madeira-d3d12] ExecuteIndirect: argument type %u is not implemented; skipped\n", (unsigned)cs->args[0].Type);
        return;
    }
    if (count_buf && said_count++ < 1)
        d3d12_log("[madeira-d3d12] ExecuteIndirect: count buffers are not honoured yet; issuing all %u records\n", max_count);
    if (max_count > 8192) { if (said_big++ < 4) d3d12_log("[madeira-d3d12] ExecuteIndirect: %u records capped at 8192\n", max_count); max_count = 8192; }
    c = mad_list_push((struct mad_list *)This, kind);
    if (!c) return;
    c->u.ind.args = (struct mad_resource *)args; c->u.ind.off = args_off; c->u.ind.count = max_count;
    c->u.ind.stride = cs->desc.ByteStride ? cs->desc.ByteStride : (kind == MC_DRAW_INDIRECT ? 16 : kind == MC_DRAW_INDEXED_INDIRECT ? 20 : 12);
    c->u.ind.cnt = (struct mad_resource *)count_buf; c->u.ind.cnt_off = count_off;
}
static void STDMETHODCALLTYPE list_CopyBufferRegion(ID3D12GraphicsCommandList *This,
        ID3D12Resource *dst, UINT64 dst_off, ID3D12Resource *src, UINT64 src_off, UINT64 len) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_resource *d = (struct mad_resource *)dst, *s = (struct mad_resource *)src;
    struct mad_cmd *c;
    if (!d || !s || !len) return;
    if (dst_off + len > d->size || src_off + len > s->size) {
        static unsigned said;
        if (!said++) d3d12_log("[madeira-d3d12] CopyBufferRegion out of range; skipped\n");
        return;
    }
    c = mad_list_push(l, MC_COPY_BB);
    if (!c) return;
    c->u.bb.dst = d; c->u.bb.doff = dst_off; c->u.bb.src = s; c->u.bb.soff = src_off; c->u.bb.len = len;
}
static void STDMETHODCALLTYPE list_CopyTextureRegion(ID3D12GraphicsCommandList *This,
        const D3D12_TEXTURE_COPY_LOCATION *dst, UINT x, UINT y, UINT z,
        const D3D12_TEXTURE_COPY_LOCATION *src, const D3D12_BOX *box) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_resource *d, *s;
    struct mad_cmd *c;
    UINT bytes, block;
    if (!dst || !src) return;
    d = (struct mad_resource *)dst->pResource; s = (struct mad_resource *)src->pResource;
    if (!d || !s) return;
    if (d->texture && !s->texture) {           /* upload: buffer -> texture */
        const D3D12_PLACED_SUBRESOURCE_FOOTPRINT *f = &src->PlacedFootprint;
        UINT w, h, dd;
        c = mad_list_push(l, MC_COPY_B2T);
        if (!c) return;
        mad_subresource(d, dst->SubresourceIndex, &c->u.bt.level, &c->u.bt.slice);
        mad_mip_dims(d, c->u.bt.level, &w, &h, &dd);
        mad_format_info(d->desc.Format, &bytes, &block);
        c->u.bt.tex = d; c->u.bt.buf = s; c->u.bt.off = f->Offset;
        c->u.bt.w = f->Footprint.Width ? f->Footprint.Width : w;
        c->u.bt.h = f->Footprint.Height ? f->Footprint.Height : h;
        c->u.bt.d = f->Footprint.Depth ? f->Footprint.Depth : dd;
        /* ml1100: the row pitch and the image pitch describe the WHOLE footprint;
         * a source box selects a region inside it, so the box's left/top/front
         * move the source ADDRESS and shrink the extent -- they never shrink the
         * image pitch (Astra, ph-rdr54 review). Before this, a cropped copy read
         * from the footprint's origin with a too-small image pitch. */
        c->u.bt.row = f->Footprint.RowPitch ? f->Footprint.RowPitch : (UINT)(((c->u.bt.w + block - 1) / block) * bytes);
        c->u.bt.rows = (c->u.bt.h + block - 1) / block;
        if (box) {
            c->u.bt.off += (UINT64)box->front * c->u.bt.row * c->u.bt.rows + (UINT64)(box->top / block) * c->u.bt.row + (UINT64)(box->left / block) * bytes;
            c->u.bt.w = box->right - box->left; c->u.bt.h = box->bottom - box->top; c->u.bt.d = box->back - box->front;
        }
        c->u.bt.x = x; c->u.bt.y = y; c->u.bt.z = z;
        return;
    }
    if (s->texture && !d->texture) {           /* readback: texture -> buffer */
        const D3D12_PLACED_SUBRESOURCE_FOOTPRINT *f = &dst->PlacedFootprint;
        UINT w, h, dd;
        c = mad_list_push(l, MC_COPY_T2B);
        if (!c) return;
        mad_subresource(s, src->SubresourceIndex, &c->u.bt.level, &c->u.bt.slice);
        mad_mip_dims(s, c->u.bt.level, &w, &h, &dd);
        mad_format_info(s->desc.Format, &bytes, &block);
        c->u.bt.tex = s; c->u.bt.buf = d; c->u.bt.off = f->Offset;
        c->u.bt.w = w; c->u.bt.h = h; c->u.bt.d = dd;
        c->u.bt.x = 0; c->u.bt.y = 0; c->u.bt.z = 0;
        if (box) { c->u.bt.x = box->left; c->u.bt.y = box->top; c->u.bt.z = box->front;
                   c->u.bt.w = box->right - box->left; c->u.bt.h = box->bottom - box->top; c->u.bt.d = box->back - box->front; }
        {   /* ml1100: pitches from the footprint, and DstX/Y/Z is an offset INTO it */
            UINT fw = f->Footprint.Width ? f->Footprint.Width : w, fh = f->Footprint.Height ? f->Footprint.Height : h;
            c->u.bt.row = f->Footprint.RowPitch ? f->Footprint.RowPitch : (UINT)(((fw + block - 1) / block) * bytes);
            c->u.bt.rows = (fh + block - 1) / block;
            c->u.bt.off += (UINT64)z * c->u.bt.row * c->u.bt.rows + (UINT64)(y / block) * c->u.bt.row + (UINT64)(x / block) * bytes;
        }
        return;
    }
    if (s->texture && d->texture) {            /* texture -> texture */
        UINT w, h, dd;
        c = mad_list_push(l, MC_COPY_T2T);
        if (!c) return;
        mad_subresource(d, dst->SubresourceIndex, &c->u.tt.dlevel, &c->u.tt.dslice);
        mad_subresource(s, src->SubresourceIndex, &c->u.tt.slevel, &c->u.tt.sslice);
        mad_mip_dims(s, c->u.tt.slevel, &w, &h, &dd);
        c->u.tt.dst = d; c->u.tt.src = s;
        c->u.tt.dx = x; c->u.tt.dy = y; c->u.tt.dz = z;
        c->u.tt.w = w; c->u.tt.h = h; c->u.tt.d = dd;
        if (box) { c->u.tt.sx = box->left; c->u.tt.sy = box->top; c->u.tt.sz = box->front;
                   c->u.tt.w = box->right - box->left; c->u.tt.h = box->bottom - box->top; c->u.tt.d = box->back - box->front; }
        return;
    }
    list_CopyBufferRegion(This, dst->pResource, 0, src->pResource, 0, s->size < d->size ? s->size : d->size);
}
/* A multisampled source resolves through a render pass (exec_resolve); a
 * single-sampled one is a plain copy, which is what D3D12 does with it too.
 * The format argument only matters for typeless resources, which are created
 * here with a concrete Metal format already. */
static void STDMETHODCALLTYPE list_ResolveSubresource(ID3D12GraphicsCommandList *This, ID3D12Resource *dst, UINT dst_sub,
        ID3D12Resource *src, UINT src_sub, DXGI_FORMAT format) {
    struct mad_list *l = (struct mad_list *)This;
    struct mad_resource *d = (struct mad_resource *)dst, *s = (struct mad_resource *)src;
    struct mad_cmd *c;
    static unsigned said;
    if (!d || !s || !d->texture || !s->texture) return;
    if (said++ < 4)
        d3d12_log("[madeira-d3d12] ResolveSubresource: %ux%u x%u samples, format %u -> %ux%u x%u, format %u (as %u)\n",
                  (unsigned)s->width, (unsigned)s->height, (unsigned)s->samples, (unsigned)s->desc.Format,
                  (unsigned)d->width, (unsigned)d->height, (unsigned)d->samples, (unsigned)d->desc.Format, (unsigned)format);
    if (s->samples <= 1) {
        D3D12_TEXTURE_COPY_LOCATION a, b;
        memset(&a, 0, sizeof a); memset(&b, 0, sizeof b);
        a.pResource = dst; a.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; a.SubresourceIndex = dst_sub;
        b.pResource = src; b.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; b.SubresourceIndex = src_sub;
        list_CopyTextureRegion(This, &a, 0, 0, 0, &b, NULL);
        return;
    }
    c = mad_list_push(l, MC_RESOLVE);
    if (!c) return;
    mad_subresource(d, dst_sub, &c->u.tt.dlevel, &c->u.tt.dslice);
    mad_subresource(s, src_sub, &c->u.tt.slevel, &c->u.tt.sslice);
    c->u.tt.dst = d; c->u.tt.src = s;
}

static void STDMETHODCALLTYPE list_CopyResource(ID3D12GraphicsCommandList *This, ID3D12Resource *dst, ID3D12Resource *src) {
    struct mad_resource *d = (struct mad_resource *)dst, *s = (struct mad_resource *)src;
    if (!d || !s) return;
    if (d->buffer && s->buffer) { list_CopyBufferRegion(This, dst, 0, src, 0, s->size < d->size ? s->size : d->size); return; }
    if (d->texture && s->texture) {
        UINT mips = s->desc.MipLevels ? s->desc.MipLevels : 1;
        UINT layers = (s->desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) ? 1 : (s->desc.DepthOrArraySize ? s->desc.DepthOrArraySize : 1);
        UINT sub, n = mips * layers;
        D3D12_TEXTURE_COPY_LOCATION a, b;
        memset(&a, 0, sizeof a); memset(&b, 0, sizeof b);
        a.pResource = dst; a.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        b.pResource = src; b.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        for (sub = 0; sub < n; sub++) {
            a.SubresourceIndex = sub; b.SubresourceIndex = sub;
            list_CopyTextureRegion(This, &a, 0, 0, 0, &b, NULL);
        }
        return;
    }
    {
        static unsigned said;
        if (!said++) d3d12_log("[madeira-d3d12] CopyResource between a buffer and a texture is not implemented; skipped\n");
    }
}


/* ---- ID3D12Device1..8 methods (ml877) --------------------------------------
 * Everything here is a thin adapter onto the ID3D12Device implementation:
 * DESC1 is DESC plus a sampler-feedback mip region, protected sessions and
 * castable-format lists are accepted only when empty, and the pipeline-state
 * stream is unpacked into the classic descs. */
static void mad_desc1_to_desc(const D3D12_RESOURCE_DESC1 *d1, D3D12_RESOURCE_DESC *d) {
    memcpy(d, d1, sizeof *d);   /* DESC is an exact prefix of DESC1 */
}

static HRESULT STDMETHODCALLTYPE device_CreateCommittedResource1(ID3D12Device10 *This,
        const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf, const D3D12_RESOURCE_DESC *desc,
        D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear,
        ID3D12ProtectedResourceSession *session, REFIID riid, void **out) {
    if (session) return E_NOTIMPL;
    return device_CreateCommittedResource((ID3D12Device *)This, hp, hf, desc, state, clear, riid, out);
}
static HRESULT STDMETHODCALLTYPE device_CreateCommittedResource2(ID3D12Device10 *This,
        const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf, const D3D12_RESOURCE_DESC1 *desc1,
        D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear,
        ID3D12ProtectedResourceSession *session, REFIID riid, void **out) {
    D3D12_RESOURCE_DESC d;
    if (session || !desc1) return E_NOTIMPL;
    mad_desc1_to_desc(desc1, &d);
    return device_CreateCommittedResource((ID3D12Device *)This, hp, hf, &d, state, clear, riid, out);
}
static HRESULT STDMETHODCALLTYPE device_CreateCommittedResource3(ID3D12Device10 *This,
        const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf, const D3D12_RESOURCE_DESC1 *desc1,
        D3D12_BARRIER_LAYOUT layout, const D3D12_CLEAR_VALUE *clear,
        ID3D12ProtectedResourceSession *session, UINT32 ncast, DXGI_FORMAT *cast, REFIID riid, void **out) {
    D3D12_RESOURCE_DESC d;
    (void)layout; (void)cast;
    if (session || ncast || !desc1) return E_NOTIMPL;
    mad_desc1_to_desc(desc1, &d);
    return device_CreateCommittedResource((ID3D12Device *)This, hp, hf, &d, D3D12_RESOURCE_STATE_COMMON, clear, riid, out);
}
static HRESULT STDMETHODCALLTYPE device_CreateHeap1(ID3D12Device10 *This, const D3D12_HEAP_DESC *desc,
        ID3D12ProtectedResourceSession *session, REFIID riid, void **out) {
    if (session) return E_NOTIMPL;
    return device_CreateHeap((ID3D12Device *)This, desc, riid, out);
}
static HRESULT STDMETHODCALLTYPE device_CreatePlacedResource1(ID3D12Device10 *This, ID3D12Heap *heap,
        UINT64 offset, const D3D12_RESOURCE_DESC1 *desc1, D3D12_RESOURCE_STATES state,
        const D3D12_CLEAR_VALUE *clear, REFIID riid, void **out) {
    D3D12_RESOURCE_DESC d;
    if (!desc1) return E_INVALIDARG;
    mad_desc1_to_desc(desc1, &d);
    return device_CreatePlacedResource((ID3D12Device *)This, heap, offset, &d, state, clear, riid, out);
}
static HRESULT STDMETHODCALLTYPE device_CreatePlacedResource2(ID3D12Device10 *This, ID3D12Heap *heap,
        UINT64 offset, const D3D12_RESOURCE_DESC1 *desc1, D3D12_BARRIER_LAYOUT layout,
        const D3D12_CLEAR_VALUE *clear, UINT32 ncast, DXGI_FORMAT *cast, REFIID riid, void **out) {
    D3D12_RESOURCE_DESC d;
    (void)layout; (void)cast;
    if (!desc1 || ncast) return E_NOTIMPL;
    mad_desc1_to_desc(desc1, &d);
    return device_CreatePlacedResource((ID3D12Device *)This, heap, offset, &d, D3D12_RESOURCE_STATE_COMMON, clear, riid, out);
}
static D3D12_RESOURCE_ALLOCATION_INFO * STDMETHODCALLTYPE device_GetResourceAllocationInfo1(ID3D12Device10 *This,
        D3D12_RESOURCE_ALLOCATION_INFO *ret, UINT visible, UINT n, const D3D12_RESOURCE_DESC *descs,
        D3D12_RESOURCE_ALLOCATION_INFO1 *info1) {
    /* The total comes from the base method; per-resource offsets are laid out
     * sequentially with each resource at its own alignment. */
    UINT64 off = 0, align = 0; UINT i;
    memset(ret, 0, sizeof *ret);
    if (!descs || !n) return ret;
    for (i = 0; i < n; i++) {
        D3D12_RESOURCE_ALLOCATION_INFO one;
        device_GetResourceAllocationInfo((ID3D12Device *)This, &one, visible, 1, &descs[i]);
        if (one.Alignment > align) align = one.Alignment;
        if (one.Alignment) off = (off + one.Alignment - 1) & ~(one.Alignment - 1);
        if (info1) { info1[i].Offset = off; info1[i].Alignment = one.Alignment; info1[i].SizeInBytes = one.SizeInBytes; }
        off += one.SizeInBytes;
    }
    ret->SizeInBytes = off; ret->Alignment = align;
    return ret;
}
static D3D12_RESOURCE_ALLOCATION_INFO * STDMETHODCALLTYPE device_GetResourceAllocationInfo2(ID3D12Device10 *This,
        D3D12_RESOURCE_ALLOCATION_INFO *ret, UINT visible, UINT n, const D3D12_RESOURCE_DESC1 *descs1,
        D3D12_RESOURCE_ALLOCATION_INFO1 *info1) {
    D3D12_RESOURCE_DESC stackd[8], *d = stackd; UINT i;
    memset(ret, 0, sizeof *ret);
    if (!descs1 || !n) return ret;
    if (n > 8) { d = calloc(n, sizeof *d); if (!d) return ret; }
    for (i = 0; i < n; i++) mad_desc1_to_desc(&descs1[i], &d[i]);
    device_GetResourceAllocationInfo1(This, ret, visible, n, d, info1);
    if (d != stackd) free(d);
    return ret;
}
static void STDMETHODCALLTYPE device_GetCopyableFootprints1(ID3D12Device10 *This, const D3D12_RESOURCE_DESC1 *desc1,
        UINT first, UINT count, UINT64 base, D3D12_PLACED_SUBRESOURCE_FOOTPRINT *layouts, UINT *rows,
        UINT64 *rowbytes, UINT64 *total) {
    D3D12_RESOURCE_DESC d;
    if (!desc1) return;
    mad_desc1_to_desc(desc1, &d);
    device_GetCopyableFootprints((ID3D12Device *)This, &d, first, count, base, layouts, rows, rowbytes, total);
}
static HRESULT STDMETHODCALLTYPE device_CreateCommandQueue1(ID3D12Device10 *This, const D3D12_COMMAND_QUEUE_DESC *desc,
        REFIID creator, REFIID riid, void **out) {
    (void)creator;
    return device_CreateCommandQueue((ID3D12Device *)This, desc, riid, out);
}
/* A list born closed: no allocator until the first Reset, which list_Reset
 * already handles (it adopts the allocator it is given). */
static HRESULT STDMETHODCALLTYPE device_CreateCommandList1(ID3D12Device10 *This, UINT node,
        D3D12_COMMAND_LIST_TYPE type, D3D12_COMMAND_LIST_FLAGS flags, REFIID riid, void **out) {
    (void)node;
    if (!out) return E_INVALIDARG;
    if (flags != D3D12_COMMAND_LIST_FLAG_NONE) return E_INVALIDARG;
    if (!mad_list_type_ok(type)) return E_NOTIMPL;
    struct mad_list *l = calloc(1, sizeof *l);
    if (!l) return E_OUTOFMEMORY;
    l->type = type;
    l->vtbl = &g_list_vtbl; l->refs = 1; l->iid = &IID_ID3D12GraphicsCommandList; l->name = "GraphicsCommandList";
    l->device = (struct mad_device *)This;
    l->closed = 1;
    HRESULT hr = list_QI((ID3D12GraphicsCommandList *)l, riid, out);
    list_Release((ID3D12GraphicsCommandList *)l);
    return hr;
}
static HRESULT STDMETHODCALLTYPE device_SetResidencyPriority(ID3D12Device10 *This, UINT n,
        ID3D12Pageable *const *objs, const D3D12_RESIDENCY_PRIORITY *prio) {
    (void)This; (void)n; (void)objs; (void)prio;
    return S_OK;                     /* unified memory: everything is resident */
}
static HRESULT STDMETHODCALLTYPE device_EnqueueMakeResident(ID3D12Device10 *This, D3D12_RESIDENCY_FLAGS flags,
        UINT n, ID3D12Pageable *const *objs, ID3D12Fence *fence, UINT64 value) {
    (void)This; (void)flags; (void)n; (void)objs;
    if (!fence) return E_INVALIDARG;
    return fence_Signal(fence, value);   /* resident already; complete the request at once */
}
static void STDMETHODCALLTYPE device_RemoveDevice(ID3D12Device10 *This) {
    struct mad_device *d = (struct mad_device *)This;
    d3d12_log("[madeira-d3d12] RemoveDevice requested by the application\n");
    InterlockedExchange(&d->device_lost, 1);
}
static HRESULT STDMETHODCALLTYPE device_SetBackgroundProcessingMode(ID3D12Device10 *This,
        D3D12_BACKGROUND_PROCESSING_MODE mode, D3D12_MEASUREMENTS_ACTION action, HANDLE event, WINBOOL *further) {
    (void)This; (void)mode; (void)action;
    if (further) *further = FALSE;
    if (event) SetEvent(event);
    return S_OK;
}
/* Multiple-fence waits: one helper thread per request. ALL waits each fence in
 * turn (order is irrelevant for the conjunction); ANY spawns one waiter per
 * fence and the first to finish signals the event (later ones re-signal, which
 * is harmless for an auto-reset or manual event alike). */
struct mad_multiwait { ID3D12Fence *fence; UINT64 value; HANDLE event; unsigned n; ID3D12Fence **fences; UINT64 *values; };
static DWORD WINAPI mad_multiwait_all(void *arg) {
    struct mad_multiwait *w = arg; unsigned i;
    for (i = 0; i < w->n; i++) { fence_SetEventOnCompletion(w->fences[i], w->values[i], NULL); ID3D12Fence_Release(w->fences[i]); }
    SetEvent(w->event);
    free(w->fences); free(w->values); free(w);
    return 0;
}
static DWORD WINAPI mad_multiwait_one(void *arg) {
    struct mad_multiwait *w = arg;
    fence_SetEventOnCompletion(w->fence, w->value, NULL);
    SetEvent(w->event);
    ID3D12Fence_Release(w->fence);
    free(w);
    return 0;
}
static HRESULT STDMETHODCALLTYPE device_SetEventOnMultipleFenceCompletion(ID3D12Device10 *This,
        ID3D12Fence *const *fences, const UINT64 *values, UINT n, D3D12_MULTIPLE_FENCE_WAIT_FLAGS flags, HANDLE event) {
    unsigned i;
    (void)This;
    if (!fences || !values || !n || !event) return E_INVALIDARG;
    if (flags & D3D12_MULTIPLE_FENCE_WAIT_FLAG_ANY) {
        for (i = 0; i < n; i++) {
            struct mad_multiwait *w = calloc(1, sizeof *w);
            HANDLE t;
            if (!w) return E_OUTOFMEMORY;
            w->fence = fences[i]; w->value = values[i]; w->event = event;
            ID3D12Fence_AddRef(w->fence);
            t = CreateThread(NULL, 0, mad_multiwait_one, w, 0, NULL);
            if (!t) { ID3D12Fence_Release(w->fence); free(w); return E_FAIL; }
            CloseHandle(t);
        }
        return S_OK;
    } else {
        struct mad_multiwait *w = calloc(1, sizeof *w);
        HANDLE t;
        if (!w) return E_OUTOFMEMORY;
        w->n = n; w->event = event;
        w->fences = calloc(n, sizeof *w->fences); w->values = calloc(n, sizeof *w->values);
        if (!w->fences || !w->values) { free(w->fences); free(w->values); free(w); return E_OUTOFMEMORY; }
        for (i = 0; i < n; i++) { w->fences[i] = fences[i]; w->values[i] = values[i]; ID3D12Fence_AddRef(fences[i]); }
        t = CreateThread(NULL, 0, mad_multiwait_all, w, 0, NULL);
        if (!t) { for (i = 0; i < n; i++) ID3D12Fence_Release(fences[i]); free(w->fences); free(w->values); free(w); return E_FAIL; }
        CloseHandle(t);
        return S_OK;
    }
}

/* Pipeline-state stream (ID3D12Device2). Each subobject is a UINT type tag
 * followed by its payload at the payload's own alignment, and the next
 * subobject starts pointer-aligned -- the layout of D3DX12's
 * CD3DX12_PIPELINE_STATE_STREAM_SUBOBJECT. The stream is unpacked into the
 * classic graphics/compute descs and handed to the existing creators. */
static HRESULT STDMETHODCALLTYPE device_CreatePipelineState(ID3D12Device10 *This,
        const D3D12_PIPELINE_STATE_STREAM_DESC *sd, REFIID riid, void **out) {
    D3D12_GRAPHICS_PIPELINE_STATE_DESC g;
    D3D12_COMPUTE_PIPELINE_STATE_DESC c;
    const BYTE *p; SIZE_T off = 0;
    int have_cs = 0, have_gfx = 0;
    unsigned i;
    if (!sd || !sd->pPipelineStateSubobjectStream || !out) return E_INVALIDARG;
    memset(&g, 0, sizeof g); memset(&c, 0, sizeof c);
    /* defaults match D3DX12's CD3DX12_DEFAULT helpers */
    g.SampleMask = 0xffffffffu;
    g.SampleDesc.Count = 1;
    g.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    g.RasterizerState.CullMode = D3D12_CULL_MODE_BACK;
    g.RasterizerState.DepthClipEnable = TRUE;
    g.DepthStencilState.DepthEnable = TRUE;
    g.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
    g.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
    g.DepthStencilState.StencilReadMask = 0xff; g.DepthStencilState.StencilWriteMask = 0xff;
    g.DepthStencilState.FrontFace.StencilFunc = g.DepthStencilState.BackFace.StencilFunc = D3D12_COMPARISON_FUNC_ALWAYS;
    g.DepthStencilState.FrontFace.StencilFailOp = g.DepthStencilState.FrontFace.StencilDepthFailOp =
        g.DepthStencilState.FrontFace.StencilPassOp = D3D12_STENCIL_OP_KEEP;
    g.DepthStencilState.BackFace = g.DepthStencilState.FrontFace;
    for (i = 0; i < 8; i++) {
        g.BlendState.RenderTarget[i].SrcBlend = D3D12_BLEND_ONE; g.BlendState.RenderTarget[i].DestBlend = D3D12_BLEND_ZERO;
        g.BlendState.RenderTarget[i].BlendOp = D3D12_BLEND_OP_ADD;
        g.BlendState.RenderTarget[i].SrcBlendAlpha = D3D12_BLEND_ONE; g.BlendState.RenderTarget[i].DestBlendAlpha = D3D12_BLEND_ZERO;
        g.BlendState.RenderTarget[i].BlendOpAlpha = D3D12_BLEND_OP_ADD;
        g.BlendState.RenderTarget[i].LogicOp = D3D12_LOGIC_OP_NOOP;
        g.BlendState.RenderTarget[i].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    }
    g.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_UNDEFINED;

    p = sd->pPipelineStateSubobjectStream;
    while (off + sizeof(UINT) <= sd->SizeInBytes) {
        UINT t = *(const UINT *)(p + off);
        SIZE_T sz, al;
        const void *pl;
#define SUB(type_) do { sz = sizeof(type_); al = _Alignof(type_); } while (0)
        switch (t) {
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_ROOT_SIGNATURE:      SUB(ID3D12RootSignature *); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VS: case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PS:
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DS: case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_HS:
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_GS: case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_CS:
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_AS: case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_MS:
                                                                        SUB(D3D12_SHADER_BYTECODE); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_STREAM_OUTPUT:       SUB(D3D12_STREAM_OUTPUT_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_BLEND:               SUB(D3D12_BLEND_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_SAMPLE_MASK:         SUB(UINT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RASTERIZER:          SUB(D3D12_RASTERIZER_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL:       SUB(D3D12_DEPTH_STENCIL_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_INPUT_LAYOUT:        SUB(D3D12_INPUT_LAYOUT_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_IB_STRIP_CUT_VALUE:  SUB(UINT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PRIMITIVE_TOPOLOGY:  SUB(UINT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RENDER_TARGET_FORMATS: SUB(struct D3D12_RT_FORMAT_ARRAY); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL_FORMAT: SUB(DXGI_FORMAT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_SAMPLE_DESC:         SUB(DXGI_SAMPLE_DESC); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_NODE_MASK:           SUB(UINT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_CACHED_PSO:          SUB(D3D12_CACHED_PIPELINE_STATE); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_FLAGS:               SUB(UINT); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL1:      SUB(D3D12_DEPTH_STENCIL_DESC1); break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VIEW_INSTANCING:     SUB(D3D12_VIEW_INSTANCING_DESC); break;
        default:
            d3d12_log("[madeira-d3d12] CreatePipelineState: unknown subobject type %u at offset %u; refused\n",
                      t, (unsigned)off);
            return E_INVALIDARG;
        }
#undef SUB
        off = (off + sizeof(UINT) + al - 1) & ~(al - 1);      /* payload at its own alignment */
        if (off + sz > sd->SizeInBytes) return E_INVALIDARG;
        pl = p + off;
        switch (t) {
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_ROOT_SIGNATURE: g.pRootSignature = c.pRootSignature = *(ID3D12RootSignature *const *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VS: g.VS = *(const D3D12_SHADER_BYTECODE *)pl; if (g.VS.BytecodeLength) have_gfx = 1; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PS: g.PS = *(const D3D12_SHADER_BYTECODE *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DS: g.DS = *(const D3D12_SHADER_BYTECODE *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_HS: g.HS = *(const D3D12_SHADER_BYTECODE *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_GS: g.GS = *(const D3D12_SHADER_BYTECODE *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_CS: c.CS = *(const D3D12_SHADER_BYTECODE *)pl; if (c.CS.BytecodeLength) have_cs = 1; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_AS: case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_MS:
            if (((const D3D12_SHADER_BYTECODE *)pl)->BytecodeLength) {
                d3d12_log("[madeira-d3d12] CreatePipelineState: mesh/amplification shader stages are not implemented\n");
                return E_NOTIMPL;
            }
            break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_STREAM_OUTPUT: g.StreamOutput = *(const D3D12_STREAM_OUTPUT_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_BLEND: g.BlendState = *(const D3D12_BLEND_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_SAMPLE_MASK: g.SampleMask = *(const UINT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RASTERIZER: g.RasterizerState = *(const D3D12_RASTERIZER_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL: g.DepthStencilState = *(const D3D12_DEPTH_STENCIL_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL1:
            memcpy(&g.DepthStencilState, pl, sizeof g.DepthStencilState);   /* DESC is a prefix of DESC1 */
            break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_INPUT_LAYOUT: g.InputLayout = *(const D3D12_INPUT_LAYOUT_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_IB_STRIP_CUT_VALUE: g.IBStripCutValue = *(const UINT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PRIMITIVE_TOPOLOGY: g.PrimitiveTopologyType = *(const UINT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RENDER_TARGET_FORMATS: {
            const struct D3D12_RT_FORMAT_ARRAY *r = pl;
            g.NumRenderTargets = r->NumRenderTargets;
            for (i = 0; i < 8; i++) g.RTVFormats[i] = r->RTFormats[i];
            break;
        }
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL_FORMAT: g.DSVFormat = *(const DXGI_FORMAT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_SAMPLE_DESC: g.SampleDesc = *(const DXGI_SAMPLE_DESC *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_NODE_MASK: g.NodeMask = c.NodeMask = *(const UINT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_CACHED_PSO: g.CachedPSO = c.CachedPSO = *(const D3D12_CACHED_PIPELINE_STATE *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_FLAGS: g.Flags = c.Flags = *(const UINT *)pl; break;
        case D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VIEW_INSTANCING: {
            const D3D12_VIEW_INSTANCING_DESC *v = pl;
            if (v->ViewInstanceCount > 1) {
                d3d12_log("[madeira-d3d12] CreatePipelineState: view instancing (%u views) is not implemented\n", v->ViewInstanceCount);
                return E_NOTIMPL;
            }
            break;
        }
        }
        off = (off + sz + sizeof(void *) - 1) & ~(sizeof(void *) - 1);   /* next subobject: pointer-aligned */
    }
    if (have_cs && !have_gfx) return device_CreateComputePipelineState((ID3D12Device *)This, &c, riid, out);
    if (have_gfx) return device_CreateGraphicsPipelineState((ID3D12Device *)This, &g, riid, out);
    d3d12_log("[madeira-d3d12] CreatePipelineState: stream carried no VS and no CS; refused\n");
    return E_INVALIDARG;
}

/* ml887: ID3D12DeviceChild::GetDevice for every child. UE 5.4 calls
 * Resource->GetDevice(IID_ID3D12Device, &dev) then dev->GetCopyableFootprints
 * while streaming textures; the generated stub left the out-pointer null and
 * three background workers dereferenced it. */
static HRESULT mad_child_get_device(struct mad_device *d, REFIID riid, void **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (!d) d = g_last_device;
    if (!d) return E_FAIL;
    return d->vtbl->QueryInterface((ID3D12Device10 *)d, riid, out);
}
static HRESULT STDMETHODCALLTYPE res_GetDevice(ID3D12Resource2 *This, REFIID riid, void **out) {
    return mad_child_get_device(((struct mad_resource *)This)->owner, riid, out);
}
static HRESULT STDMETHODCALLTYPE list_GetDevice(ID3D12GraphicsCommandList *This, REFIID riid, void **out) {
    return mad_child_get_device(((struct mad_list *)This)->device, riid, out);
}
static HRESULT STDMETHODCALLTYPE queue_GetDevice(ID3D12CommandQueue *This, REFIID riid, void **out) {
    return mad_child_get_device(((struct mad_queue *)This)->device, riid, out);
}
static HRESULT STDMETHODCALLTYPE heap_GetDevice(ID3D12DescriptorHeap *This, REFIID riid, void **out) {
    return mad_child_get_device(((struct mad_heap *)This)->owner, riid, out);
}
static HRESULT STDMETHODCALLTYPE alloc_GetDevice(ID3D12CommandAllocator *This, REFIID riid, void **out) {
    (void)This; return mad_child_get_device(NULL, riid, out);
}
static HRESULT STDMETHODCALLTYPE fence_GetDevice(ID3D12Fence *This, REFIID riid, void **out) {
    (void)This; return mad_child_get_device(NULL, riid, out);
}
static HRESULT STDMETHODCALLTYPE pso_GetDevice(ID3D12PipelineState *This, REFIID riid, void **out) {
    (void)This; return mad_child_get_device(NULL, riid, out);
}
static HRESULT STDMETHODCALLTYPE rootsig_GetDevice(ID3D12RootSignature *This, REFIID riid, void **out) {
    (void)This; return mad_child_get_device(NULL, riid, out);
}

/* ---- vtable construction ------------------------------------------------- */
static void build_vtables(void) {
    static LONG done;
    if (InterlockedCompareExchange(&done, 1, 0) != 0) return;

    madeira_fill_ID3D12Device10(&g_device_vtbl);
    /* ml877: ID3D12Device1..8 */
    g_device_vtbl.CreatePipelineState                = device_CreatePipelineState;
    g_device_vtbl.CreateCommandList1                 = device_CreateCommandList1;
    g_device_vtbl.CreateCommittedResource1           = device_CreateCommittedResource1;
    g_device_vtbl.CreateCommittedResource2           = device_CreateCommittedResource2;
    g_device_vtbl.CreateCommittedResource3           = device_CreateCommittedResource3;
    g_device_vtbl.CreateHeap1                        = device_CreateHeap1;
    g_device_vtbl.CreatePlacedResource1              = device_CreatePlacedResource1;
    g_device_vtbl.CreatePlacedResource2              = device_CreatePlacedResource2;
    g_device_vtbl.GetResourceAllocationInfo1         = device_GetResourceAllocationInfo1;
    g_device_vtbl.GetResourceAllocationInfo2         = device_GetResourceAllocationInfo2;
    g_device_vtbl.GetCopyableFootprints1             = device_GetCopyableFootprints1;
    g_device_vtbl.CreateCommandQueue1                = device_CreateCommandQueue1;
    g_device_vtbl.SetResidencyPriority               = device_SetResidencyPriority;
    g_device_vtbl.EnqueueMakeResident                = device_EnqueueMakeResident;
    g_device_vtbl.RemoveDevice                       = device_RemoveDevice;
    g_device_vtbl.SetBackgroundProcessingMode        = device_SetBackgroundProcessingMode;
    g_device_vtbl.SetEventOnMultipleFenceCompletion  = device_SetEventOnMultipleFenceCompletion;
    g_device_vtbl.QueryInterface = (void *)device_QI;
    g_device_vtbl.AddRef = (void *)device_AddRef;
    g_device_vtbl.Release = (void *)device_Release;
    g_device_vtbl.GetNodeCount = (void *)device_GetNodeCount;
    g_device_vtbl.CreateCommandQueue = (void *)device_CreateCommandQueue;
    g_device_vtbl.CreateCommandAllocator = (void *)device_CreateCommandAllocator;
    g_device_vtbl.CreateCommandList = (void *)device_CreateCommandList;
    g_device_vtbl.CreateFence = (void *)device_CreateFence;
    g_device_vtbl.CreateCommandSignature = (void *)device_CreateCommandSignature;
    g_device_vtbl.CreateQueryHeap = (void *)device_CreateQueryHeap;
    g_device_vtbl.CreateHeap = (void *)device_CreateHeap;
    g_device_vtbl.CreatePlacedResource = (void *)device_CreatePlacedResource;
    g_memheap_vtbl.QueryInterface          = memheap_QI;
    g_memheap_vtbl.AddRef                  = memheap_AddRef;
    g_memheap_vtbl.Release                 = memheap_Release;
    g_memheap_vtbl.GetPrivateData          = memheap_GetPrivateData;
    g_memheap_vtbl.SetPrivateData          = memheap_SetPrivateData;
    g_memheap_vtbl.SetPrivateDataInterface = memheap_SetPrivateDataInterface;
    g_memheap_vtbl.SetName                 = memheap_SetName;
    g_memheap_vtbl.GetDevice               = memheap_GetDevice;
    g_memheap_vtbl.GetDesc                 = memheap_GetDesc;
    g_device_vtbl.CreateConstantBufferView = (void *)device_CreateConstantBufferView;
    g_device_vtbl.CreateUnorderedAccessView = (void *)device_CreateUnorderedAccessView;
    g_device_vtbl.CopyDescriptors = (void *)device_CopyDescriptors;
    g_device_vtbl.CopyDescriptorsSimple = (void *)device_CopyDescriptorsSimple;
    g_device_vtbl.GetCopyableFootprints = (void *)device_GetCopyableFootprints;
    g_device_vtbl.GetResourceAllocationInfo = (void *)device_GetResourceAllocationInfo;
    g_qheap_vtbl.QueryInterface          = qheap_QI;
    g_qheap_vtbl.AddRef                  = qheap_AddRef;
    g_qheap_vtbl.Release                 = qheap_Release;
    g_qheap_vtbl.GetPrivateData          = qheap_GetPrivateData;
    g_qheap_vtbl.SetPrivateData          = qheap_SetPrivateData;
    g_qheap_vtbl.SetPrivateDataInterface = qheap_SetPrivateDataInterface;
    g_qheap_vtbl.SetName                 = qheap_SetName;
    g_qheap_vtbl.GetDevice               = qheap_GetDevice;

    g_cmdsig_vtbl.QueryInterface          = cmdsig_QI;
    g_cmdsig_vtbl.AddRef                  = cmdsig_AddRef;
    g_cmdsig_vtbl.Release                 = cmdsig_Release;
    g_cmdsig_vtbl.GetPrivateData          = cmdsig_GetPrivateData;
    g_cmdsig_vtbl.SetPrivateData          = cmdsig_SetPrivateData;
    g_cmdsig_vtbl.SetPrivateDataInterface = cmdsig_SetPrivateDataInterface;
    g_cmdsig_vtbl.SetName                 = cmdsig_SetName;
    g_cmdsig_vtbl.GetDevice               = cmdsig_GetDevice;
    g_device_vtbl.CreateCommittedResource = (void *)device_CreateCommittedResource;
    g_device_vtbl.CreateRootSignature = (void *)device_CreateRootSignature;
    g_device_vtbl.CreateDescriptorHeap = (void *)device_CreateDescriptorHeap;
    g_device_vtbl.CreateRenderTargetView = (void *)device_CreateRenderTargetView;
    g_device_vtbl.CreateDepthStencilView = (void *)device_CreateDepthStencilView;
    g_device_vtbl.CreateShaderResourceView = (void *)device_CreateShaderResourceView;
    g_device_vtbl.CreateSampler = (void *)device_CreateSampler;
    g_device_vtbl.GetDescriptorHandleIncrementSize = (void *)device_GetDescriptorHandleIncrementSize;
    g_device_vtbl.CreateGraphicsPipelineState = (void *)device_CreateGraphicsPipelineState;
    g_device_vtbl.CheckFeatureSupport = (void *)device_CheckFeatureSupport;

    madeira_fill_ID3D12CommandQueue(&g_queue_vtbl);
    g_queue_vtbl.GetDevice = queue_GetDevice;
    g_queue_vtbl.QueryInterface         = queue_QI;
    g_queue_vtbl.AddRef                 = queue_AddRef;
    g_queue_vtbl.Release                = queue_Release;
    g_queue_vtbl.ExecuteCommandLists    = queue_ExecuteCommandLists;
    g_queue_vtbl.Signal                 = queue_Signal;
    g_queue_vtbl.Wait                   = queue_Wait;
    g_queue_vtbl.GetTimestampFrequency  = queue_GetTimestampFrequency;
    g_queue_vtbl.GetClockCalibration    = queue_GetClockCalibration;
    g_queue_vtbl.GetDesc                = queue_GetDesc;

    madeira_fill_ID3D12CommandAllocator(&g_alloc_vtbl);
    g_alloc_vtbl.GetDevice = alloc_GetDevice;
    g_alloc_vtbl.QueryInterface         = alloc_QI;
    g_alloc_vtbl.AddRef                 = alloc_AddRef;
    g_alloc_vtbl.Release                = alloc_Release;
    g_alloc_vtbl.Reset                  = alloc_Reset;

    madeira_fill_ID3D12Resource2(&g_res_vtbl);
    g_res_vtbl.GetDevice = res_GetDevice;
    g_res_vtbl.GetDesc1 = (void *)res_GetDesc1;
    g_res_vtbl.QueryInterface = (void *)res_QI;
    g_res_vtbl.AddRef = (void *)res_AddRef;
    g_res_vtbl.Release = (void *)res_Release;
    g_res_vtbl.Map = (void *)res_Map;
    g_res_vtbl.Unmap = (void *)res_Unmap;
    g_res_vtbl.GetGPUVirtualAddress = (void *)res_GetGPUVirtualAddress;
    g_res_vtbl.GetDesc = (void *)res_GetDesc;

    madeira_fill_ID3D12GraphicsCommandList7(&g_list_vtbl);
    g_list_vtbl.GetDevice = (void *)list_GetDevice;
    g_list_vtbl.QueryInterface          = (void *)list_QI;
    g_list_vtbl.AddRef                  = (void *)list_AddRef;
    g_list_vtbl.Release                 = (void *)list_Release;
    g_list_vtbl.Close                   = (void *)list_Close;
    g_list_vtbl.Reset                   = (void *)list_Reset;
    g_list_vtbl.GetType                 = (void *)list_GetType;
    g_list_vtbl.CopyBufferRegion        = (void *)list_CopyBufferRegion;
    g_list_vtbl.OMSetRenderTargets      = (void *)list_OMSetRenderTargets;
    g_list_vtbl.ClearRenderTargetView   = (void *)list_ClearRenderTargetView;
    g_list_vtbl.SetPipelineState        = (void *)list_SetPipelineState;
    g_list_vtbl.SetGraphicsRootSignature= (void *)list_SetGraphicsRootSignature;
    g_list_vtbl.SetGraphicsRootConstantBufferView = (void *)list_SetGraphicsRootConstantBufferView;
    g_list_vtbl.SetGraphicsRootDescriptorTable = (void *)list_SetGraphicsRootDescriptorTable;
    g_list_vtbl.SetDescriptorHeaps      = (void *)list_SetDescriptorHeaps;
    g_list_vtbl.RSSetViewports          = (void *)list_RSSetViewports;
    g_list_vtbl.RSSetScissorRects       = (void *)list_RSSetScissorRects;
    g_list_vtbl.IASetVertexBuffers      = (void *)list_IASetVertexBuffers;
    g_list_vtbl.OMSetStencilRef         = (void *)list_OMSetStencilRef;
    g_list_vtbl.SetComputeRootSignature            = (void *)list_SetComputeRootSignature;
    g_list_vtbl.SetComputeRootConstantBufferView   = (void *)list_SetComputeRootConstantBufferView;
    g_list_vtbl.SetComputeRootShaderResourceView   = (void *)list_SetComputeRootShaderResourceView;
    g_list_vtbl.SetComputeRootUnorderedAccessView  = (void *)list_SetComputeRootUnorderedAccessView;
    g_list_vtbl.SetComputeRootDescriptorTable      = (void *)list_SetComputeRootDescriptorTable;
    g_list_vtbl.SetComputeRoot32BitConstant        = (void *)list_SetComputeRoot32BitConstant;
    g_list_vtbl.SetComputeRoot32BitConstants       = (void *)list_SetComputeRoot32BitConstants;
    g_device_vtbl.CreateComputePipelineState = (void *)device_CreateComputePipelineState;
    g_list_vtbl.CopyResource            = (void *)list_CopyResource;
    g_list_vtbl.ResourceBarrier         = (void *)list_ResourceBarrier;
    g_list_vtbl.Dispatch                = (void *)list_Dispatch;
    g_list_vtbl.ExecuteIndirect         = (void *)list_ExecuteIndirect;
    g_list_vtbl.SetGraphicsRootShaderResourceView  = (void *)list_SetGraphicsRootShaderResourceView;
    g_list_vtbl.SetGraphicsRootUnorderedAccessView = (void *)list_SetGraphicsRootUnorderedAccessView;
    g_list_vtbl.SetGraphicsRoot32BitConstant       = (void *)list_SetGraphicsRoot32BitConstant;
    g_list_vtbl.SetGraphicsRoot32BitConstants      = (void *)list_SetGraphicsRoot32BitConstants;
    g_list_vtbl.ClearUnorderedAccessViewUint  = (void *)list_ClearUnorderedAccessViewUint;
    g_list_vtbl.ClearUnorderedAccessViewFloat = (void *)list_ClearUnorderedAccessViewFloat;
    g_list_vtbl.OMSetBlendFactor              = (void *)list_OMSetBlendFactor;
    g_list_vtbl.DiscardResource               = (void *)list_DiscardResource;
    g_list_vtbl.BeginQuery              = (void *)list_BeginQuery;
    g_list_vtbl.EndQuery                = (void *)list_EndQuery;
    g_list_vtbl.ResolveQueryData        = (void *)list_ResolveQueryData;
    g_list_vtbl.IASetPrimitiveTopology  = (void *)list_IASetPrimitiveTopology;
    g_list_vtbl.DrawInstanced           = (void *)list_DrawInstanced;
    g_list_vtbl.CopyTextureRegion       = (void *)list_CopyTextureRegion;
    g_list_vtbl.ResolveSubresource      = (void *)list_ResolveSubresource;
    g_list_vtbl.IASetIndexBuffer        = (void *)list_IASetIndexBuffer;
    g_list_vtbl.DrawIndexedInstanced    = (void *)list_DrawIndexedInstanced;
    g_list_vtbl.ClearDepthStencilView   = (void *)list_ClearDepthStencilView;

    madeira_fill_ID3D12RootSignature(&g_rootsig_vtbl);
    g_rootsig_vtbl.GetDevice = rootsig_GetDevice;
    g_rootsig_vtbl.QueryInterface = rootsig_QI;
    g_rootsig_vtbl.AddRef = rootsig_AddRef;
    g_rootsig_vtbl.Release = rootsig_Release;

    madeira_fill_ID3D12PipelineState(&g_pso_vtbl);
    g_pso_vtbl.GetDevice = pso_GetDevice;
    g_pso_vtbl.QueryInterface = pso_QI;
    g_pso_vtbl.AddRef = pso_AddRef;
    g_pso_vtbl.Release = pso_Release;

    madeira_fill_ID3D12DescriptorHeap(&g_heap_vtbl);
    g_heap_vtbl.GetDevice = heap_GetDevice;
    g_heap_vtbl.QueryInterface = heap_QI;
    g_heap_vtbl.AddRef = heap_AddRef;
    g_heap_vtbl.Release = heap_Release;
    g_heap_vtbl.GetCPUDescriptorHandleForHeapStart = heap_GetCPUDescriptorHandleForHeapStart;
    g_heap_vtbl.GetGPUDescriptorHandleForHeapStart = heap_GetGPUDescriptorHandleForHeapStart;
    g_heap_vtbl.GetDesc = heap_GetDesc;
    g_device_vtbl.GetCustomHeapProperties = (void *)device_GetCustomHeapProperties;

    madeira_fill_ID3D12Fence(&g_fence_vtbl);
    g_fence_vtbl.GetDevice = fence_GetDevice;
    g_fence_vtbl.QueryInterface         = fence_QI;
    g_fence_vtbl.AddRef                 = fence_AddRef;
    g_fence_vtbl.Release                = fence_Release;
    g_fence_vtbl.GetCompletedValue      = fence_GetCompletedValue;
    g_fence_vtbl.SetEventOnCompletion   = fence_SetEventOnCompletion;
    g_fence_vtbl.Signal                 = fence_Signal;
}

/* ---- exports ------------------------------------------------------------- */

/* Lets a caller prove which implementation it reached, and on which
 * architecture, without a debugger. The design asks for exactly this. */
/* ml909: drive the production logger with oversized records from a test so
 * the newline/length contract above is checked where it matters. */
__declspec(dllexport) void MadeiraD3D12LogProbe(const char *msg, unsigned repeat) {
    unsigned i;
    for (i = 0; i < repeat; i++) d3d12_log("[log-probe] %u %s", i, msg ? msg : "");
}
__declspec(dllexport) const char *MadeiraD3D12GetBuildMarker(void) {
#if defined(__aarch64__) || defined(_M_ARM64) || defined(_M_ARM64EC)
    return MADEIRA_D3D12_BUILD " [arm64ec]";
#else
    return MADEIRA_D3D12_BUILD " [x64]";
#endif
}

/* Test hook. ExecuteCommandLists returns void, so a rejected submission has no
 * API-visible effect; without this a negative test could not tell "rejected"
 * from "executed". Named as a Madeira export so it cannot be mistaken for D3D12. */
__declspec(dllexport) void MadeiraD3D12GetQueueStats(ID3D12CommandQueue *queue,
                                                     UINT64 *executed, UINT64 *rejected) {
    struct mad_queue *q = (struct mad_queue *)queue;
    if (!q) return;
    if (executed) *executed = q->executed;
    if (rejected) *rejected = q->rejected;
}

__declspec(dllexport) HRESULT WINAPI MadeiraD3D12CreateDevice(IUnknown *adapter,
        D3D_FEATURE_LEVEL min_feature_level, REFIID riid, void **device) {
    (void)adapter;
    build_vtables();

    /* The design is explicit that accepting the controlled sample's requested
     * baseline is a documented limitation, not a conformance claim. Anything
     * above 11_0 is refused rather than quietly accepted. */
    if (min_feature_level > D3D_FEATURE_LEVEL_12_0) {
        d3d12_log("[madeira-d3d12] feature level %#x refused; 12_0 is the ceiling claimed\n", min_feature_level);
        return E_NOTIMPL;
    }
    if (!device) return S_FALSE;   /* the documented "is it supported" probe */

    struct mad_device *d = calloc(1, sizeof *d);
    if (!d) return E_OUTOFMEMORY;
    d->vtbl = &g_device_vtbl; d->refs = 1; d->iid = &IID_ID3D12Device; d->name = "Device";
    g_last_device = d;

    /* Whichever backend winemetal is configured for, local or remote. Failing
     * here is reported rather than deferred to the first draw. */
    /* Ownership, read from winemetal's local implementations rather than
     * assumed, because the two backends differ and only one of them forgives
     * a mistake:
     *
     *   MTLCopyAllDevices   -> +1, ours to release (the Copy rule).
     *   NSArray objectAtIndex -> UNOWNED. Releasing it is an over-release, and
     *                          locally that is a real Metal object being
     *                          deallocated out from under the process.
     *   newCommandQueue     -> +1, ours to release.
     *
     * Remotely every handle is interned with its own reference, so the same
     * code is harmless there. That asymmetry is why this only ever faulted on
     * the A15, and it faulted during teardown rather than at the call. */
    obj_handle_t devices = WMTCopyAllDevices();
    d->mtl_device = devices ? NSArray_object(devices, 0) : 0;
    if (d->mtl_device) NSObject_retain(d->mtl_device);   /* take our own reference */
    if (devices) NSObject_release(devices);
    InitializeCriticalSection(&d->live_lock);
    InitializeSRWLock(&d->list_lock);
    InitializeCriticalSection(&d->view_lock);   /* ml1049 */
    InitializeCriticalSection(&d->ring_lock);   /* ml1061 */
    InitializeCriticalSection(&d->vis_lock);    /* ml1088 */
    InitializeCriticalSection(&d->vis_pub_lock); /* ml1092 */
    InitializeCriticalSection(&d->heap_lock);   /* ml1072 */
    g_hp_dev = d;
    InitializeCriticalSection(&d->fence_lock);
    if (d->mtl_device) d->mtl_queue = MTLDevice_newCommandQueue(d->mtl_device, 64);
    if (d->mtl_device) {   /* ml1061: the GPU timeline every batch signals */
        d->gpu_event = MTLDevice_newSharedEvent(d->mtl_device);
        d3d12_log("[madeira-d3d12] ml1061 GPU timeline event %s: fences are %s\n", d->gpu_event ? "created" : "UNAVAILABLE",
                  d->gpu_event ? "delivered asynchronously" : "synchronous (old behaviour)");
    }
    if (d->mtl_device && d->mtl_queue) {
        struct WMTBufferInfo nbi;
        d->resset = MTLDevice_newResidencySet(d->mtl_device, 4096);
        if (d->resset) MTLCommandQueue_addResidencySet(d->mtl_queue, d->resset);
        d3d12_log("[madeira-d3d12] residency set: %s\n", d->resset ? "attached to the queue" : "UNAVAILABLE (per-draw lists only)");
        memset(&nbi, 0, sizeof nbi);
        nbi.length = 65536;
        nbi.options = WMTResourceStorageModeShared;
        d->null_buffer = MTLDevice_newBuffer(d->mtl_device, &nbi);
        if (d->null_buffer) {
            if (nbi.memory.ptr) memset(nbi.memory.ptr, 0, 65536);
            d->null_gpu = nbi.gpu_address;
            mad_resident(d, d->null_buffer);
        }
    }
    if (d->mtl_device) {
        /* One depth state for the cube: closer fragments win and write. */
        struct WMTDepthStencilInfo dsi;
        memset(&dsi, 0, sizeof dsi);
        dsi.depth_compare_function = WMTCompareFunctionLessEqual;
        dsi.depth_write_enabled = true;
        d->dsso = MTLDevice_newDepthStencilState(d->mtl_device, &dsi);
    }
    if (!d->mtl_device || !d->mtl_queue) {
        d3d12_log("[madeira-d3d12] no Metal device or queue available\n");
        free(d);
        return E_FAIL;
    }
    HRESULT hr = device_QI((ID3D12Device *)d, riid, device);
    device_Release((ID3D12Device *)d);
    if (SUCCEEDED(hr)) d3d12_log("[madeira-d3d12] device created: %s\n", MadeiraD3D12GetBuildMarker());
    return hr;
}

/* ===========================================================================
 * DXGI swapchain bridge (ml857).
 *
 * DXMT's dxgi.dll builds a swapchain by asking the device object it was given
 * for a private interface, IMTLDXGIDevice, and calling CreateSwapChain on it
 * ("Unsupported device type" when the query fails -- the ml856 wall). Our
 * command queue answers that query with a tear-off, and the swapchain itself
 * lives here: D3D12 semantics need N persistent back buffers the application
 * renders into by index, while a Metal layer hands out transient drawables.
 * So the back buffers are ordinary textures and Present blits the current one
 * into the next drawable. dxgi.dll is not modified. */

#define MAD_SWAP_MAX_BUFFERS 8
struct mad_swapchain {
    IDXGISwapChain4Vtbl *vtbl; LONG refs; const IID *iid; const char *name;
    struct mad_device *dev;
    struct mad_queue *queue;
    IDXGIFactory1 *factory;
    HWND hwnd;
    DXGI_SWAP_CHAIN_DESC1 desc;
    DXGI_SWAP_CHAIN_FULLSCREEN_DESC fs;
    obj_handle_t view, layer;
    enum WMTPixelFormat pf;
    struct mad_resource *buffers[MAD_SWAP_MAX_BUFFERS];
    UINT nbuf, index;
    UINT64 presents;
    UINT max_latency;
    HANDLE latency_event;
    UINT64 present_serial[8];   /* ml1070: GPU serial the frame presented N ago must have passed */
};
static IDXGISwapChain4Vtbl g_swap_vtbl;

static void mad_swap_release_buffers(struct mad_swapchain *s) {
    UINT i;
    for (i = 0; i < s->nbuf; i++)
        if (s->buffers[i]) { res_Release((ID3D12Resource *)s->buffers[i]); s->buffers[i] = NULL; }
    s->nbuf = 0;
}

static HRESULT mad_swap_make_buffers(struct mad_swapchain *s) {
    D3D12_RESOURCE_DESC rd;
    struct WMTLayerProps props;
    UINT i, n = s->desc.BufferCount ? s->desc.BufferCount : 2;
    int is_depth;
    if (n > MAD_SWAP_MAX_BUFFERS) n = MAD_SWAP_MAX_BUFFERS;
    if (!mad_map_texture_format(s->desc.Format, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, &s->pf, &is_depth) || is_depth) {
        d3d12_log("[madeira-d3d12] swapchain format %u is not presentable\n", (unsigned)s->desc.Format);
        return DXGI_ERROR_INVALID_CALL;
    }
    memset(&rd, 0, sizeof rd);
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    rd.Width = s->desc.Width; rd.Height = s->desc.Height;
    rd.DepthOrArraySize = 1; rd.MipLevels = 1;
    rd.Format = s->desc.Format;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    if (s->desc.BufferUsage & DXGI_USAGE_UNORDERED_ACCESS) rd.Flags |= D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    for (i = 0; i < n; i++) {
        void *out = NULL;
        HRESULT hr = mad_create_resource(s->dev, D3D12_HEAP_TYPE_DEFAULT, &rd, &IID_ID3D12Resource, &out);
        if (FAILED(hr)) { s->nbuf = i; mad_swap_release_buffers(s); return hr; }
        s->buffers[i] = (struct mad_resource *)out;
        s->buffers[i]->name = "Backbuffer";
    }
    s->nbuf = n;
    s->index = 0;
    /* The layer takes the same pixel format so the presenting blit is a plain
     * copy. framebuffer_only must be off: a framebuffer-only drawable cannot
     * be a blit destination. */
    memset(&props, 0, sizeof props);
    MetalLayer_getProps(s->layer, &props);
    props.device = s->dev->mtl_device;
    props.drawable_width = s->desc.Width;
    props.drawable_height = s->desc.Height;
    props.pixel_format = s->pf;
    props.framebuffer_only = false;
    props.display_sync_enabled = true;
    MetalLayer_setProps(s->layer, &props);
    d3d12_log("[madeira-d3d12] swapchain: %ux%u, %u buffers, format %u, hwnd %p\n",
              s->desc.Width, s->desc.Height, n, (unsigned)s->desc.Format, (void *)s->hwnd);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE swap_QI(IDXGISwapChain4 *T, REFIID riid, void **out) {
    struct mad_obj *o = (struct mad_obj *)T;
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, &IID_IDXGIObject) ||
        IsEqualGUID(riid, &IID_IDXGIDeviceSubObject) || IsEqualGUID(riid, &IID_IDXGISwapChain) ||
        IsEqualGUID(riid, &IID_IDXGISwapChain1) || IsEqualGUID(riid, &IID_IDXGISwapChain2) ||
        IsEqualGUID(riid, &IID_IDXGISwapChain3) || IsEqualGUID(riid, &IID_IDXGISwapChain4)) {
        InterlockedIncrement(&o->refs); *out = T; return S_OK;
    }
    *out = NULL;
    d3d12_log("[madeira-d3d12] swapchain QueryInterface refused: {%08lx-%04x-%04x-...}\n",
              (unsigned long)riid->Data1, riid->Data2, riid->Data3);
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE swap_AddRef(IDXGISwapChain4 *T) { return mad_addref((struct mad_obj *)T); }
static ULONG STDMETHODCALLTYPE swap_Release(IDXGISwapChain4 *T) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    LONG n = InterlockedDecrement(&s->refs);
    if (n == 0) { mad_pd_purge(T);   /* ml1143 */
        if (s->queue && s->queue->sub_thread) mad_queue_drain(s->queue);   /* ml1121: queued presents name this swapchain */
        mad_swap_release_buffers(s);
        if (s->view) ReleaseMetalView(s->view);
        if (s->latency_event) CloseHandle(s->latency_event);
        if (s->factory) IDXGIFactory1_Release(s->factory);
        ID3D12CommandQueue_Release((ID3D12CommandQueue *)s->queue);
        d3d12_log("[madeira-d3d12] swapchain destroyed after %llu presents\n", (unsigned long long)s->presents);
        free(s);
    }
    return (ULONG)n;
}
static HRESULT STDMETHODCALLTYPE swap_SetPrivateData(IDXGISwapChain4 *T, REFGUID g, UINT n, const void *d) { return mad_pd_set(T, g, n, d); }   /* ml1143 */
static HRESULT STDMETHODCALLTYPE swap_SetPrivateDataInterface(IDXGISwapChain4 *T, REFGUID g, const IUnknown *d) { return mad_pd_set_iface(T, g, d); }
static HRESULT STDMETHODCALLTYPE swap_GetPrivateData(IDXGISwapChain4 *T, REFGUID g, UINT *n, void *d) { return mad_pd_get(T, g, n, d); }
static HRESULT STDMETHODCALLTYPE swap_GetParent(IDXGISwapChain4 *T, REFIID riid, void **out) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (!out) return E_POINTER;
    *out = NULL;
    if (!s->factory) return E_NOINTERFACE;
    return IDXGIFactory1_QueryInterface(s->factory, riid, out);
}
static HRESULT STDMETHODCALLTYPE swap_GetDevice(IDXGISwapChain4 *T, REFIID riid, void **out) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    return s->dev->vtbl->QueryInterface((ID3D12Device10 *)s->dev, riid, out);
}

/* ml1056: drawable ownership. -[CAMetalLayer nextDrawable] returns an AUTORELEASED
 * (+0) object and this function ended with NSObject_release(drawable): a release
 * of a reference it never owned. On a thread with no autorelease pool that
 * "worked" by stealing the pool's reference, but it meant the drawable died the
 * moment the command buffer's present block dropped ITS reference -- while the
 * GPU driver's completion blocks and CoreAnimation were still using it. Measured
 * as two different native crashes, both immediately after "Present #1": the main
 * thread in objc_retain on an object with a zeroed isa, and an AGX completion
 * block handing libdispatch a NULL object. Timing-dependent, which is why it came
 * and went with unrelated builds.
 * Correct form: a pool scoped to the present owns the +0 references (drawable,
 * the present command buffer, the blit encoder) and nothing is released by hand.
 * It also stops leaking one command buffer per frame. */
static HRESULT swap_Present_inner(IDXGISwapChain4 *T, UINT sync, UINT flags);
static HRESULT swap_Present_pool(IDXGISwapChain4 *T, UINT sync, UINT flags);
static HRESULT STDMETHODCALLTYPE swap_Present(IDXGISwapChain4 *T, UINT sync, UINT flags) {   /* ml1119: timed wrapper */
    LARGE_INTEGER t0, t1; HRESULT hr;
    mad_xp_role('P'); InterlockedIncrement64(&g_xp.pres_enq);   /* ml1128 */
    QueryPerformanceCounter(&t0);
    hr = swap_Present_pool(T, sync, flags);
    QueryPerformanceCounter(&t1);
    InterlockedExchangeAdd64(&g_perf_present_ticks, t1.QuadPart - t0.QuadPart);
    return hr;
}
static HRESULT swap_Present_pool(IDXGISwapChain4 *T, UINT sync, UINT flags) {
    obj_handle_t pool = NSAutoreleasePool_alloc_init();
    HRESULT hr = swap_Present_inner(T, sync, flags);
    if (pool) NSObject_release(pool);
    return hr;
}
static HRESULT swap_Present_inner(IDXGISwapChain4 *T, UINT sync, UINT flags) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    struct mad_queue *q = s->queue;
    (void)sync;
    if (flags & DXGI_PRESENT_TEST) return S_OK;
    if (!s->nbuf) return DXGI_ERROR_INVALID_CALL;
    if (q && q->sub_thread) {   /* ml1121: queue the present behind this frame's lists and return */
        struct mad_subjob *j = calloc(1, sizeof *j);
        if (j) {
            j->kind = MAD_SUB_PRESENT; j->swap = s; j->index = s->index;
            s->index = (s->index + 1) % s->nbuf;   /* GetCurrentBackBufferIndex moves on at once, as on Windows */
            EnterCriticalSection(&q->sub_lock); q->sub_presents++; LeaveCriticalSection(&q->sub_lock);
            mad_sub_enqueue(q, j);
            mad_present_throttle(q);
            return S_OK;
        }
        mad_queue_drain(q);
    }
    mad_present_run(s, s->index);
    s->index = (s->index + 1) % s->nbuf;
    return S_OK;
}
/* ml1121: the Metal half of Present; runs on the queue's worker (async) or on the caller. */
static void mad_mheap_reclaim(struct mad_device *d, int all);
static void mad_present_run(struct mad_swapchain *s, UINT idx) {
    struct mad_resource *src;
    obj_handle_t drawable, tex, cb, enc;
    struct wmtcmd_blit_copy_from_texture_to_texture t2t;
    if (idx >= s->nbuf) return;
    src = s->buffers[idx];
    mad_mheap_reclaim(s->dev, 0);   /* ml1148: once a frame, heaps whose GPU work is long done */
    { LONG64 tf = mad_qpc();   /* ml1128 */
    mad_device_flush_all(s->queue->device);          /* ml884: the frame's batch precedes the present */
    InterlockedExchangeAdd64(&g_xp.t_flush, mad_qpc() - tf); }
    {   /* ml1098: manual frame capture -- finish the frame that just ended, then see whether the UI asked for another */
        struct madeira_ctl_args a;
        if (g_capture_on) { mad_capture_finish(s->queue->device, g_capture_frame); if (g_capture_left) g_capture_left--; g_capture_on = 0; }
        memset(&a, 0, sizeof a); a.op = 0; MadeiraCtl(&a);
        if (a.ret) { g_capture_left += a.ret; d3d12_log("[capture] %u frame(s) requested at present #%llu\n", a.ret, (unsigned long long)s->presents); }
        {   /* ml1136: live fence-chain switch from the overlay; lists already running keep their mode */
            int want;
            memset(&a, 0, sizeof a); a.op = 6; MadeiraCtl(&a);
            want = (int)a.ret;
            if (want >= 1 && want <= 6 && want != 4 && want != g_fence_chain && g_fence_chain >= 0) {
                d3d12_log("[madeira-d3d12] ml1136 fence-chain %d -> %d at present #%llu\n", g_fence_chain, want, (unsigned long long)s->presents);
                g_fence_chain = want;
            } else if (a.ret == 7 && g_fence_chain != 0 && g_fence_chain >= 0) {   /* 7 = request mode 0 (0 means "no request") */
                d3d12_log("[madeira-d3d12] ml1136 fence-chain %d -> 0 (NO fences, diagnostic) at present #%llu\n", g_fence_chain, (unsigned long long)s->presents);
                g_fence_chain = 0;
            }
        }
        if (g_att_census) InterlockedIncrement(&g_ac_frames);   /* ml1137: the frame that just ended was a census frame */
        g_att_census = (s->presents % 16) == 15;
        if (g_occlusion_visible < 0) {   /* ml1103 */
            g_occlusion_visible = mad_cfg_int_pe("occlusion-visible", 0) ? 1 : 0;
            d3d12_log("[madeira-d3d12] ml1103 occlusion-visible = %d (%s)\n", g_occlusion_visible,
                      g_occlusion_visible ? "EVERY occlusion query answers fully visible -- diagnostic" : "real GPU results");
        }
        if (g_capture_left) {
            g_capture_on = 1; g_capture_frame = s->presents + 1; g_dump_draws = 0;
            {   /* ml1152: re-read every CAP, like capture-cs */
                g_capture_ps_loaded = 1; mad_cfg_str_pe("capture-ps", g_capture_ps, sizeof g_capture_ps);
                if (g_capture_ps[0]) d3d12_log("[capture] ml1106 targeted draw capture for ps='%s'\n", g_capture_ps); }
            g_capture_ps_shots = 0;
            {   /* ml1141: re-read every CAP, so the target can change between captures of one run */
                mad_cfg_str_pe("capture-cs", g_capture_cs, sizeof g_capture_cs);
                g_capture_cs_ind = mad_cfg_int_pe("capture-cs-indirect", 0) ? 1 : 0;
                g_capture_cs_max = (int)mad_cfg_int_pe("capture-cs-max", 12);
                if (g_capture_cs[0]) d3d12_log("[capture] ml1141 targeted dispatch capture for cs='%s' (%s, first %d)\n", g_capture_cs,
                                              g_capture_cs_ind ? "indirect only" : "direct and indirect", g_capture_cs_max);
            }
            g_capture_cs_shots = 0;
            d3d12_log("[capture] ===== capturing frame %llu (everything between present #%llu and #%llu; draw-dump forced on) =====\n",
                      (unsigned long long)g_capture_frame, (unsigned long long)s->presents, (unsigned long long)s->presents + 1);
        }
    }
    {   /* ml1070: BOUNDED FRAMES IN FLIGHT. The frame-latency waitable object was
         * permanently signalled and SetMaximumFrameLatency only stored a number, so
         * the CPU could run any number of frames ahead of the GPU: more upload
         * memory live at once (we die at the memory limit), more latency, and no
         * back-pressure when the GPU is the bottleneck (27-40 ms/frame in heavy
         * scenes). Before presenting frame N, wait until the GPU has finished the
         * batches of frame N-latency (default 2, honouring 1..3). */
        struct mad_device *dv = s->queue->device;
        UINT lat = s->max_latency ? s->max_latency : 2; if (lat > 3) lat = 3;
        UINT64 need = s->present_serial[(s->presents + 8 - lat) & 7];
        s->present_serial[s->presents & 7] = (UINT64)dv->gpu_serial_committed;
        if (dv->gpu_event && need && (UINT64)mad_gpu_completed(dv) < need) {
            static LONG waits, said;
            LONG64 tl = mad_qpc();   /* ml1128 */
            InterlockedIncrement(&waits);
            MTLSharedEvent_waitUntilSignaledValue(dv->gpu_event, need, 1000);
            InterlockedIncrement64(&g_xp.n_lat); InterlockedExchangeAdd64(&g_xp.t_lat, mad_qpc() - tl);
            if (InterlockedIncrement(&said) <= 3 || (waits % 2000) == 0)
                d3d12_log("[madeira-d3d12] ml1070 present #%llu waited for the GPU to finish frame N-%u (serial %llu; %ld such waits so far)\n",
                          (unsigned long long)s->presents, lat, (unsigned long long)need, waits);
        }
    }
    { LONG64 td = mad_qpc();   /* ml1128 */
    drawable = MetalLayer_nextDrawable(s->layer);
    InterlockedExchangeAdd64(&g_xp.t_draw, mad_qpc() - td); }
    if (!drawable) {
        static unsigned said;
        if (said++ < 3) d3d12_log("[madeira-d3d12] Present: the layer gave no drawable\n");
        return;   /* a dropped frame, not an error the application can act on */
    }
    { LONG64 tc = mad_qpc();   /* ml1128: blit + presentDrawable + commit */
    tex = MetalDrawable_texture(drawable);
    cb = MTLCommandQueue_commandBuffer(s->queue->device->mtl_queue);
    if (cb && tex) {
        enc = MTLCommandBuffer_blitCommandEncoder(cb); if (enc) g_enc_seq++;
        if (enc && g_f6_used && s->queue->device->enc_fence) {   /* ml1134: after every committed batch, not just queue order */
            obj_handle_t df = s->queue->device->enc_fence;
            f6_encode(enc, F6_BLIT, &df, 1, 0);
        }
        if (enc) {
            memset(&t2t, 0, sizeof t2t);
            t2t.type = WMTBlitCommandCopyFromTextureToTexture;
            t2t.src = src->texture;
            t2t.src_size.width = src->width;
            t2t.src_size.height = src->height;
            t2t.src_size.depth = 1;
            t2t.dst = tex;
            MTLBlitCommandEncoder_encodeCommands(enc, (const struct wmtcmd_base *)&t2t);
            MTLCommandEncoder_endEncoding(enc);
        }
        /* Submitted after the frame's own command buffers on the same queue,
         * which is what orders the copy after the rendering. */
        MTLCommandBuffer_presentDrawable(cb, drawable);
        MTLCommandBuffer_commit(cb);
    }
    InterlockedExchangeAdd64(&g_xp.t_cmt, mad_qpc() - tc); }
    /* ml1056: no release -- the drawable was never ours (see swap_Present). */
    s->presents++;
    mad_perf_present();   /* ml1108 */
    g_census_on = (s->presents >= 1500 && s->presents < 3000 && (s->presents % 200) == 0);   /* ml899 */
    if (g_capture_on) g_census_on = 1;   /* ml1098 */
    if ((g_list_seq >= 12000 && g_list_seq < 12400) || g_census_on)
        d3d12_log("[draw-dump] ===== Present #%llu (list#%u) =====\n", (unsigned long long)s->presents, g_list_seq);
    if (s->presents <= 3 || (s->presents % 600) == 0)
        d3d12_log("[madeira-d3d12] Present #%llu (buffer %u)\n", (unsigned long long)s->presents, idx);
}
static HRESULT STDMETHODCALLTYPE swap_GetBuffer(IDXGISwapChain4 *T, UINT i, REFIID riid, void **out) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (!out) return E_POINTER;
    *out = NULL;
    if (i >= s->nbuf) return DXGI_ERROR_INVALID_CALL;
    return res_QI((ID3D12Resource *)s->buffers[i], riid, out);
}
static HRESULT STDMETHODCALLTYPE swap_SetFullscreenState(IDXGISwapChain4 *T, BOOL fs, IDXGIOutput *target) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    (void)target;
    /* The window is what the desktop says it is; fullscreen is recorded so the
     * application reads back what it set, and changes nothing else. */
    s->fs.Windowed = !fs;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetFullscreenState(IDXGISwapChain4 *T, BOOL *fs, IDXGIOutput **target) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (fs) *fs = !s->fs.Windowed;
    if (target) *target = NULL;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetDesc(IDXGISwapChain4 *T, DXGI_SWAP_CHAIN_DESC *d) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (!d) return E_INVALIDARG;
    memset(d, 0, sizeof *d);
    d->BufferDesc.Width = s->desc.Width; d->BufferDesc.Height = s->desc.Height;
    d->BufferDesc.Format = s->desc.Format;
    d->BufferDesc.RefreshRate = s->fs.RefreshRate;
    d->BufferDesc.ScanlineOrdering = s->fs.ScanlineOrdering;
    d->BufferDesc.Scaling = s->fs.Scaling;
    d->SampleDesc = s->desc.SampleDesc;
    d->BufferUsage = s->desc.BufferUsage;
    d->BufferCount = s->nbuf;
    d->OutputWindow = s->hwnd;
    d->Windowed = s->fs.Windowed;
    d->SwapEffect = s->desc.SwapEffect;
    d->Flags = s->desc.Flags;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_ResizeBuffers(IDXGISwapChain4 *T, UINT count, UINT w, UINT h, DXGI_FORMAT fmt, UINT flags) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    UINT i;
    if (s->queue && s->queue->sub_thread) mad_queue_drain(s->queue);   /* ml1120: no list may still reference the old buffers */
    for (i = 0; i < s->nbuf; i++)
        if (s->buffers[i] && s->buffers[i]->refs > 1)
            d3d12_log("[madeira-d3d12] ResizeBuffers: back buffer %u still has %ld outside references\n", i, (long)s->buffers[i]->refs - 1);
    mad_swap_release_buffers(s);
    if (count) s->desc.BufferCount = count;
    if (w) s->desc.Width = w;
    if (h) s->desc.Height = h;
    if (fmt != DXGI_FORMAT_UNKNOWN) s->desc.Format = fmt;
    s->desc.Flags = flags;
    return mad_swap_make_buffers(s);
}
static HRESULT STDMETHODCALLTYPE swap_ResizeTarget(IDXGISwapChain4 *T, const DXGI_MODE_DESC *m) { (void)T; (void)m; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_GetContainingOutput(IDXGISwapChain4 *T, IDXGIOutput **out) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    IDXGIAdapter1 *adapter = NULL;
    HRESULT hr;
    if (!out) return E_POINTER;
    *out = NULL;
    if (!s->factory) return DXGI_ERROR_UNSUPPORTED;
    hr = IDXGIFactory1_EnumAdapters1(s->factory, 0, &adapter);
    if (FAILED(hr)) return hr;
    hr = IDXGIAdapter1_EnumOutputs(adapter, 0, out);
    IDXGIAdapter1_Release(adapter);
    return hr;
}
static HRESULT STDMETHODCALLTYPE swap_GetFrameStatistics(IDXGISwapChain4 *T, DXGI_FRAME_STATISTICS *st) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (!st) return E_INVALIDARG;
    memset(st, 0, sizeof *st);
    st->PresentCount = (UINT)s->presents;
    st->PresentRefreshCount = (UINT)s->presents;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetLastPresentCount(IDXGISwapChain4 *T, UINT *n) {
    if (!n) return E_INVALIDARG;
    *n = (UINT)((struct mad_swapchain *)T)->presents;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetDesc1(IDXGISwapChain4 *T, DXGI_SWAP_CHAIN_DESC1 *d) {
    if (!d) return E_INVALIDARG;
    *d = ((struct mad_swapchain *)T)->desc;
    d->BufferCount = ((struct mad_swapchain *)T)->nbuf;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetFullscreenDesc(IDXGISwapChain4 *T, DXGI_SWAP_CHAIN_FULLSCREEN_DESC *d) {
    if (!d) return E_INVALIDARG;
    *d = ((struct mad_swapchain *)T)->fs;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetHwnd(IDXGISwapChain4 *T, HWND *h) {
    if (!h) return E_INVALIDARG;
    *h = ((struct mad_swapchain *)T)->hwnd;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_GetCoreWindow(IDXGISwapChain4 *T, REFIID riid, void **out) { (void)T; (void)riid; if (out) *out = NULL; return DXGI_ERROR_INVALID_CALL; }
static HRESULT STDMETHODCALLTYPE swap_Present1(IDXGISwapChain4 *T, UINT sync, UINT flags, const DXGI_PRESENT_PARAMETERS *p) { (void)p; return swap_Present(T, sync, flags); }
static BOOL STDMETHODCALLTYPE swap_IsTemporaryMonoSupported(IDXGISwapChain4 *T) { (void)T; return FALSE; }
static HRESULT STDMETHODCALLTYPE swap_GetRestrictToOutput(IDXGISwapChain4 *T, IDXGIOutput **out) { (void)T; if (out) *out = NULL; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_SetBackgroundColor(IDXGISwapChain4 *T, const DXGI_RGBA *c) { (void)T; (void)c; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_GetBackgroundColor(IDXGISwapChain4 *T, DXGI_RGBA *c) { (void)T; if (c) memset(c, 0, sizeof *c); return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_SetRotation(IDXGISwapChain4 *T, DXGI_MODE_ROTATION r) { (void)T; (void)r; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_GetRotation(IDXGISwapChain4 *T, DXGI_MODE_ROTATION *r) { (void)T; if (r) *r = DXGI_MODE_ROTATION_IDENTITY; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_SetSourceSize(IDXGISwapChain4 *T, UINT w, UINT h) { (void)T; (void)w; (void)h; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_GetSourceSize(IDXGISwapChain4 *T, UINT *w, UINT *h) {
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (w) *w = s->desc.Width; if (h) *h = s->desc.Height; return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_SetMaximumFrameLatency(IDXGISwapChain4 *T, UINT n) { ((struct mad_swapchain *)T)->max_latency = n ? n : 1; return S_OK; }
static HRESULT STDMETHODCALLTYPE swap_GetMaximumFrameLatency(IDXGISwapChain4 *T, UINT *n) { if (!n) return E_INVALIDARG; *n = ((struct mad_swapchain *)T)->max_latency; return S_OK; }
static HANDLE STDMETHODCALLTYPE swap_GetFrameLatencyWaitableObject(IDXGISwapChain4 *T) {
    /* Always signalled: presentation never applies back-pressure here, so a
     * waiter must never block on it. */
    struct mad_swapchain *s = (struct mad_swapchain *)T;
    if (!s->latency_event) s->latency_event = CreateEventW(NULL, TRUE, TRUE, NULL);
    return s->latency_event;
}
static HRESULT STDMETHODCALLTYPE swap_SetMatrixTransform(IDXGISwapChain4 *T, const DXGI_MATRIX_3X2_F *m) { (void)T; (void)m; return DXGI_ERROR_INVALID_CALL; }
static HRESULT STDMETHODCALLTYPE swap_GetMatrixTransform(IDXGISwapChain4 *T, DXGI_MATRIX_3X2_F *m) { (void)T; (void)m; return DXGI_ERROR_INVALID_CALL; }
static UINT STDMETHODCALLTYPE swap_GetCurrentBackBufferIndex(IDXGISwapChain4 *T) { return ((struct mad_swapchain *)T)->index; }
static HRESULT STDMETHODCALLTYPE swap_CheckColorSpaceSupport(IDXGISwapChain4 *T, DXGI_COLOR_SPACE_TYPE cs, UINT *flags) {
    (void)T;
    if (!flags) return E_INVALIDARG;
    *flags = (cs == DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709) ? DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT : 0;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE swap_SetColorSpace1(IDXGISwapChain4 *T, DXGI_COLOR_SPACE_TYPE cs) {
    (void)T;
    if (cs == DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709) return S_OK;
    d3d12_log("[madeira-d3d12] SetColorSpace1(%u) refused: only sRGB is presented\n", (unsigned)cs);
    return E_INVALIDARG;
}
static HRESULT STDMETHODCALLTYPE swap_ResizeBuffers1(IDXGISwapChain4 *T, UINT count, UINT w, UINT h, DXGI_FORMAT fmt, UINT flags,
                                                     const UINT *node_masks, IUnknown *const *queues) {
    (void)node_masks; (void)queues;
    return swap_ResizeBuffers(T, count, w, h, fmt, flags);
}
static HRESULT STDMETHODCALLTYPE swap_SetHDRMetaData(IDXGISwapChain4 *T, DXGI_HDR_METADATA_TYPE type, UINT n, void *d) { (void)T; (void)type; (void)n; (void)d; return S_OK; }

static HRESULT mad_swapchain_create(struct mad_queue *q, IDXGIFactory1 *factory, HWND hwnd,
                                    const DXGI_SWAP_CHAIN_DESC1 *desc,
                                    const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *fs, IDXGISwapChain1 **out) {
    struct mad_swapchain *s;
    HRESULT hr;
    if (!out) return E_POINTER;
    *out = NULL;
    if (!q || !desc || !hwnd) return DXGI_ERROR_INVALID_CALL;
    s = calloc(1, sizeof *s);
    if (!s) return E_OUTOFMEMORY;
    s->vtbl = &g_swap_vtbl; s->refs = 1; s->iid = &IID_IDXGISwapChain4; s->name = "SwapChain";
    s->dev = q->device; s->queue = q;
    ID3D12CommandQueue_AddRef((ID3D12CommandQueue *)q);
    s->factory = factory;
    if (factory) IDXGIFactory1_AddRef(factory);
    s->hwnd = hwnd;
    s->desc = *desc;
    if (fs) s->fs = *fs; else s->fs.Windowed = TRUE;
    s->max_latency = 1;
    s->view = CreateMetalViewFromHWND((intptr_t)hwnd, s->dev->mtl_device, &s->layer);
    if (!s->view || !s->layer) {
        d3d12_log("[madeira-d3d12] swapchain: no Metal view for hwnd %p\n", (void *)hwnd);
        swap_Release((IDXGISwapChain4 *)s);
        return DXGI_ERROR_UNSUPPORTED;
    }
    hr = mad_swap_make_buffers(s);
    if (FAILED(hr)) { swap_Release((IDXGISwapChain4 *)s); return hr; }
    *out = (IDXGISwapChain1 *)s;
    return S_OK;
}

/* ---- the tear-off dxgi.dll asks the queue for ---------------------------
 * IMTLDXGIDevice extends IDXGIDevice3; only the last method matters here.
 * GetMTLDevice returns a C++ object with a user-declared constructor, which
 * on this ABI travels through a hidden pointer that the callee returns. */
struct mad_mtl_dxgi_device;
struct mad_mtl_dxgi_device_vtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(struct mad_mtl_dxgi_device *, REFIID, void **);
    ULONG (STDMETHODCALLTYPE *AddRef)(struct mad_mtl_dxgi_device *);
    ULONG (STDMETHODCALLTYPE *Release)(struct mad_mtl_dxgi_device *);
    HRESULT (STDMETHODCALLTYPE *SetPrivateData)(struct mad_mtl_dxgi_device *, REFGUID, UINT, const void *);
    HRESULT (STDMETHODCALLTYPE *SetPrivateDataInterface)(struct mad_mtl_dxgi_device *, REFGUID, const IUnknown *);
    HRESULT (STDMETHODCALLTYPE *GetPrivateData)(struct mad_mtl_dxgi_device *, REFGUID, UINT *, void *);
    HRESULT (STDMETHODCALLTYPE *GetParent)(struct mad_mtl_dxgi_device *, REFIID, void **);
    HRESULT (STDMETHODCALLTYPE *GetAdapter)(struct mad_mtl_dxgi_device *, IDXGIAdapter **);
    HRESULT (STDMETHODCALLTYPE *CreateSurface)(struct mad_mtl_dxgi_device *, const DXGI_SURFACE_DESC *, UINT, DXGI_USAGE, const DXGI_SHARED_RESOURCE *, IDXGISurface **);
    HRESULT (STDMETHODCALLTYPE *QueryResourceResidency)(struct mad_mtl_dxgi_device *, IUnknown *const *, DXGI_RESIDENCY *, UINT);
    HRESULT (STDMETHODCALLTYPE *SetGPUThreadPriority)(struct mad_mtl_dxgi_device *, INT);
    HRESULT (STDMETHODCALLTYPE *GetGPUThreadPriority)(struct mad_mtl_dxgi_device *, INT *);
    HRESULT (STDMETHODCALLTYPE *SetMaximumFrameLatency)(struct mad_mtl_dxgi_device *, UINT);
    HRESULT (STDMETHODCALLTYPE *GetMaximumFrameLatency)(struct mad_mtl_dxgi_device *, UINT *);
    HRESULT (STDMETHODCALLTYPE *OfferResources)(struct mad_mtl_dxgi_device *, UINT, IDXGIResource *const *, DXGI_OFFER_RESOURCE_PRIORITY);
    HRESULT (STDMETHODCALLTYPE *ReclaimResources)(struct mad_mtl_dxgi_device *, UINT, IDXGIResource *const *, BOOL *);
    HRESULT (STDMETHODCALLTYPE *EnqueueSetEvent)(struct mad_mtl_dxgi_device *, HANDLE);
    void (STDMETHODCALLTYPE *Trim)(struct mad_mtl_dxgi_device *);
    obj_handle_t *(STDMETHODCALLTYPE *GetMTLDevice)(struct mad_mtl_dxgi_device *, obj_handle_t *ret);
    UINT (STDMETHODCALLTYPE *GetLocalD3DKMT)(struct mad_mtl_dxgi_device *);
    HRESULT (STDMETHODCALLTYPE *CreateSwapChain)(struct mad_mtl_dxgi_device *, IDXGIFactory1 *, HWND,
                                                 const DXGI_SWAP_CHAIN_DESC1 *, const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *,
                                                 IDXGISwapChain1 **);
};
struct mad_mtl_dxgi_device {
    const struct mad_mtl_dxgi_device_vtbl *vtbl;
    LONG refs;
    struct mad_queue *queue;
};
static HRESULT STDMETHODCALLTYPE mdd_QI(struct mad_mtl_dxgi_device *T, REFIID riid, void **out) {
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, &IID_IMTLDXGIDevice)) {
        InterlockedIncrement(&T->refs); *out = T; return S_OK;
    }
    /* Anything else is the queue's business. */
    return T->queue->vtbl->QueryInterface((ID3D12CommandQueue *)T->queue, riid, out);
}
static ULONG STDMETHODCALLTYPE mdd_AddRef(struct mad_mtl_dxgi_device *T) { return (ULONG)InterlockedIncrement(&T->refs); }
static ULONG STDMETHODCALLTYPE mdd_Release(struct mad_mtl_dxgi_device *T) {
    LONG n = InterlockedDecrement(&T->refs);
    if (n == 0) { mad_pd_purge(T);   /* ml1143 */ ID3D12CommandQueue_Release((ID3D12CommandQueue *)T->queue); free(T); }
    return (ULONG)n;
}
static HRESULT STDMETHODCALLTYPE mdd_SetPrivateData(struct mad_mtl_dxgi_device *T, REFGUID g, UINT n, const void *d) { return mad_pd_set(T, g, n, d); }   /* ml1143 */
static HRESULT STDMETHODCALLTYPE mdd_SetPrivateDataInterface(struct mad_mtl_dxgi_device *T, REFGUID g, const IUnknown *d) { return mad_pd_set_iface(T, g, d); }
static HRESULT STDMETHODCALLTYPE mdd_GetPrivateData(struct mad_mtl_dxgi_device *T, REFGUID g, UINT *n, void *d) { return mad_pd_get(T, g, n, d); }
static HRESULT STDMETHODCALLTYPE mdd_GetParent(struct mad_mtl_dxgi_device *T, REFIID riid, void **out) { (void)T; (void)riid; if (out) *out = NULL; return E_NOINTERFACE; }
static HRESULT STDMETHODCALLTYPE mdd_GetAdapter(struct mad_mtl_dxgi_device *T, IDXGIAdapter **out) { (void)T; if (out) *out = NULL; d3d12_log("[madeira-d3d12] IDXGIDevice::GetAdapter is not implemented\n"); return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE mdd_CreateSurface(struct mad_mtl_dxgi_device *T, const DXGI_SURFACE_DESC *d, UINT n, DXGI_USAGE u, const DXGI_SHARED_RESOURCE *s, IDXGISurface **out) { (void)T; (void)d; (void)n; (void)u; (void)s; if (out) *out = NULL; return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE mdd_QueryResourceResidency(struct mad_mtl_dxgi_device *T, IUnknown *const *r, DXGI_RESIDENCY *st, UINT n) { UINT i; (void)T; (void)r; for (i = 0; st && i < n; i++) st[i] = DXGI_RESIDENCY_FULLY_RESIDENT; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_SetGPUThreadPriority(struct mad_mtl_dxgi_device *T, INT p) { (void)T; (void)p; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_GetGPUThreadPriority(struct mad_mtl_dxgi_device *T, INT *p) { (void)T; if (p) *p = 0; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_SetMaximumFrameLatency(struct mad_mtl_dxgi_device *T, UINT n) { (void)T; (void)n; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_GetMaximumFrameLatency(struct mad_mtl_dxgi_device *T, UINT *n) { (void)T; if (n) *n = 1; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_OfferResources(struct mad_mtl_dxgi_device *T, UINT n, IDXGIResource *const *r, DXGI_OFFER_RESOURCE_PRIORITY p) { (void)T; (void)n; (void)r; (void)p; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_ReclaimResources(struct mad_mtl_dxgi_device *T, UINT n, IDXGIResource *const *r, BOOL *discarded) { UINT i; (void)T; (void)r; for (i = 0; discarded && i < n; i++) discarded[i] = FALSE; return S_OK; }
static HRESULT STDMETHODCALLTYPE mdd_EnqueueSetEvent(struct mad_mtl_dxgi_device *T, HANDLE e) { (void)T; if (e) SetEvent(e); return S_OK; }
static void STDMETHODCALLTYPE mdd_Trim(struct mad_mtl_dxgi_device *T) { (void)T; }
static obj_handle_t * STDMETHODCALLTYPE mdd_GetMTLDevice(struct mad_mtl_dxgi_device *T, obj_handle_t *ret) { *ret = T->queue->device->mtl_device; return ret; }
static UINT STDMETHODCALLTYPE mdd_GetLocalD3DKMT(struct mad_mtl_dxgi_device *T) { (void)T; return 0; }
static HRESULT STDMETHODCALLTYPE mdd_CreateSwapChain(struct mad_mtl_dxgi_device *T, IDXGIFactory1 *factory, HWND hwnd,
        const DXGI_SWAP_CHAIN_DESC1 *desc, const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *fs, IDXGISwapChain1 **out) {
    return mad_swapchain_create(T->queue, factory, hwnd, desc, fs, out);
}
static const struct mad_mtl_dxgi_device_vtbl g_mdd_vtbl = {
    mdd_QI, mdd_AddRef, mdd_Release, mdd_SetPrivateData, mdd_SetPrivateDataInterface, mdd_GetPrivateData,
    mdd_GetParent, mdd_GetAdapter, mdd_CreateSurface, mdd_QueryResourceResidency, mdd_SetGPUThreadPriority,
    mdd_GetGPUThreadPriority, mdd_SetMaximumFrameLatency, mdd_GetMaximumFrameLatency, mdd_OfferResources,
    mdd_ReclaimResources, mdd_EnqueueSetEvent, mdd_Trim, mdd_GetMTLDevice, mdd_GetLocalD3DKMT, mdd_CreateSwapChain,
};

/* The queue's answer to the private query: a fresh tear-off holding the queue. */
static HRESULT mad_queue_dxgi_tearoff(struct mad_queue *q, void **out) {
    struct mad_mtl_dxgi_device *t = calloc(1, sizeof *t);
    if (!t) return E_OUTOFMEMORY;
    t->vtbl = &g_mdd_vtbl; t->refs = 1; t->queue = q;
    ID3D12CommandQueue_AddRef((ID3D12CommandQueue *)q);
    d3d12_log("[madeira-d3d12] dxgi asked the queue for its Metal device; swapchain bridge engaged\n");
    *out = t;
    return S_OK;
}

static void mad_swap_fill_vtbl(void) {
    g_swap_vtbl.QueryInterface = swap_QI; g_swap_vtbl.AddRef = swap_AddRef; g_swap_vtbl.Release = swap_Release;
    g_swap_vtbl.SetPrivateData = swap_SetPrivateData; g_swap_vtbl.SetPrivateDataInterface = swap_SetPrivateDataInterface;
    g_swap_vtbl.GetPrivateData = swap_GetPrivateData; g_swap_vtbl.GetParent = swap_GetParent; g_swap_vtbl.GetDevice = swap_GetDevice;
    g_swap_vtbl.Present = swap_Present; g_swap_vtbl.GetBuffer = swap_GetBuffer;
    g_swap_vtbl.SetFullscreenState = swap_SetFullscreenState; g_swap_vtbl.GetFullscreenState = swap_GetFullscreenState;
    g_swap_vtbl.GetDesc = swap_GetDesc; g_swap_vtbl.ResizeBuffers = swap_ResizeBuffers; g_swap_vtbl.ResizeTarget = swap_ResizeTarget;
    g_swap_vtbl.GetContainingOutput = swap_GetContainingOutput; g_swap_vtbl.GetFrameStatistics = swap_GetFrameStatistics;
    g_swap_vtbl.GetLastPresentCount = swap_GetLastPresentCount; g_swap_vtbl.GetDesc1 = swap_GetDesc1;
    g_swap_vtbl.GetFullscreenDesc = swap_GetFullscreenDesc; g_swap_vtbl.GetHwnd = swap_GetHwnd; g_swap_vtbl.GetCoreWindow = swap_GetCoreWindow;
    g_swap_vtbl.Present1 = swap_Present1; g_swap_vtbl.IsTemporaryMonoSupported = swap_IsTemporaryMonoSupported;
    g_swap_vtbl.GetRestrictToOutput = swap_GetRestrictToOutput; g_swap_vtbl.SetBackgroundColor = swap_SetBackgroundColor;
    g_swap_vtbl.GetBackgroundColor = swap_GetBackgroundColor; g_swap_vtbl.SetRotation = swap_SetRotation; g_swap_vtbl.GetRotation = swap_GetRotation;
    g_swap_vtbl.SetSourceSize = swap_SetSourceSize; g_swap_vtbl.GetSourceSize = swap_GetSourceSize;
    g_swap_vtbl.SetMaximumFrameLatency = swap_SetMaximumFrameLatency; g_swap_vtbl.GetMaximumFrameLatency = swap_GetMaximumFrameLatency;
    g_swap_vtbl.GetFrameLatencyWaitableObject = swap_GetFrameLatencyWaitableObject;
    g_swap_vtbl.SetMatrixTransform = swap_SetMatrixTransform; g_swap_vtbl.GetMatrixTransform = swap_GetMatrixTransform;
    g_swap_vtbl.GetCurrentBackBufferIndex = swap_GetCurrentBackBufferIndex; g_swap_vtbl.CheckColorSpaceSupport = swap_CheckColorSpaceSupport;
    g_swap_vtbl.SetColorSpace1 = swap_SetColorSpace1; g_swap_vtbl.ResizeBuffers1 = swap_ResizeBuffers1; g_swap_vtbl.SetHDRMetaData = swap_SetHDRMetaData;
}

/* ---- test presentation bridge -------------------------------------------
 *
 * Deliberately NOT DXGI. The design says not to make a full DXGI implementation
 * a prerequisite for a visible frame, and a swapchain carries format
 * negotiation, buffer counts, resize and fullscreen transitions that have
 * nothing to do with proving the D3D12 path draws. This is an explicit,
 * separately named bridge: acquire the layer's next drawable, hand it back as a
 * render target, present it. When DXGI arrives it replaces this rather than
 * building on it. */
struct mad_presenter {
    struct mad_device *dev;
    obj_handle_t view, layer, drawable;
    struct mad_resource back;
    UINT width, height;
};

__declspec(dllexport) void *MadeiraD3D12PresenterCreate(ID3D12Device *device, intptr_t hwnd,
                                                        UINT width, UINT height) {
    struct mad_device *d = (struct mad_device *)device;
    if (!d) return NULL;
    struct mad_presenter *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->dev = d; p->width = width; p->height = height;
    p->view = CreateMetalViewFromHWND(hwnd, d->mtl_device, &p->layer);
    if (!p->view || !p->layer) {
        d3d12_log("[madeira-d3d12] presenter: no Metal view for hwnd %p\n", (void *)hwnd);
        free(p);
        return NULL;
    }
    struct WMTLayerProps props;
    memset(&props, 0, sizeof props);
    MetalLayer_getProps(p->layer, &props);
    props.device = d->mtl_device;
    props.drawable_width = width;
    props.drawable_height = height;
    props.pixel_format = WMTPixelFormatRGBA8Unorm;
    props.framebuffer_only = false;   /* the cube test reads the target back */
    MetalLayer_setProps(p->layer, &props);
    d3d12_log("[madeira-d3d12] presenter: layer %ux%u ready\n", width, height);
    return p;
}

/* The returned resource borrows the drawable's texture and is valid only until
 * the next Present. Handing back something longer-lived would invite a caller to
 * keep using a texture the layer has already recycled. */
__declspec(dllexport) ID3D12Resource *MadeiraD3D12PresenterAcquire(void *ph) {
    struct mad_presenter *p = (struct mad_presenter *)ph;
    if (!p) return NULL;
    if (p->drawable) { NSObject_release(p->drawable); p->drawable = 0; }
    p->drawable = MetalLayer_nextDrawable(p->layer);
    if (p->drawable) NSObject_retain(p->drawable);   /* ml1056: +0 from the layer; held across calls, so own it */
    if (!p->drawable) { d3d12_log("[madeira-d3d12] presenter: no drawable\n"); return NULL; }
    memset(&p->back, 0, sizeof p->back);
    p->back.vtbl = &g_res_vtbl;
    p->back.refs = 1;
    p->back.iid = &IID_ID3D12Resource;
    p->back.name = "Backbuffer";
    p->back.texture = MetalDrawable_texture(p->drawable);
    p->back.width = p->width;
    p->back.height = p->height;
    p->back.borrowed = 1;
    return (ID3D12Resource *)&p->back;
}

__declspec(dllexport) void MadeiraD3D12PresenterPresent(void *ph, ID3D12CommandQueue *queue) {
    struct mad_presenter *p = (struct mad_presenter *)ph;
    struct mad_queue *q = (struct mad_queue *)queue;
    if (!p || !q || !p->drawable) return;
    /* Presentation rides its own command buffer, submitted after the frame's
     * work is already on the queue, so ordering comes from the queue itself. */
    obj_handle_t cb = MTLCommandQueue_commandBuffer(q->device->mtl_queue);
    if (!cb) return;
    MTLCommandBuffer_presentDrawable(cb, p->drawable);
    MTLCommandBuffer_commit(cb);
    NSObject_release(p->drawable);
    p->drawable = 0;
}

__declspec(dllexport) void MadeiraD3D12PresenterDestroy(void *ph) {
    struct mad_presenter *p = (struct mad_presenter *)ph;
    if (!p) return;
    if (p->drawable) NSObject_release(p->drawable);
    if (p->view) ReleaseMetalView(p->view);
    free(p);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) { build_vtables(); mad_swap_fill_vtbl(); }
    return TRUE;
}

/* ===========================================================================
 * The standard d3d12.dll surface (ml849).
 *
 * The first UE5 run that got past thread startup called D3D12CreateDevice in
 * Wine's d3d12.dll, which needs Vulkan and reported "Failed to load Vulkan
 * library". So this runtime now presents the ordinary entry points and ships
 * as d3d12.dll as well. The executable delay-loads two of them BY ORDINAL --
 * 101 D3D12CreateDevice and 102 D3D12GetDebugInterface -- so d3d12.def pins
 * those numbers to match Wine's and Microsoft's export tables.
 *
 * Everything unsupported is refused BY NAME and logged, never faked: the point
 * of this stage is to let the engine name its next requirement. */

/* ---- ID3DBlob: what the serializer entry points hand back ---------------- */
struct mad_blob { const ID3D10BlobVtbl *vtbl; LONG refs; void *data; SIZE_T size; };
static HRESULT STDMETHODCALLTYPE blob_QI(ID3D10Blob *T, REFIID riid, void **out) {
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, &IID_ID3D10Blob)) {
        InterlockedIncrement(&((struct mad_blob *)T)->refs); *out = T; return S_OK;
    }
    *out = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE blob_AddRef(ID3D10Blob *T) { return (ULONG)InterlockedIncrement(&((struct mad_blob *)T)->refs); }
static ULONG STDMETHODCALLTYPE blob_Release(ID3D10Blob *T) {
    struct mad_blob *b = (struct mad_blob *)T;
    LONG n = InterlockedDecrement(&b->refs);
    if (n == 0) { mad_pd_purge(T);   /* ml1143 */ free(b->data); free(b); }
    return (ULONG)n;
}
static void * STDMETHODCALLTYPE blob_GetBufferPointer(ID3D10Blob *T) { return ((struct mad_blob *)T)->data; }
static SIZE_T STDMETHODCALLTYPE blob_GetBufferSize(ID3D10Blob *T) { return ((struct mad_blob *)T)->size; }
static const ID3D10BlobVtbl g_blob_vtbl = { blob_QI, blob_AddRef, blob_Release, blob_GetBufferPointer, blob_GetBufferSize };

static HRESULT mad_make_blob(const void *bytes, SIZE_T n, ID3D10Blob **out) {
    struct mad_blob *b;
    if (!out) return E_POINTER;
    b = calloc(1, sizeof *b);
    if (!b) return E_OUTOFMEMORY;
    b->data = malloc(n ? n : 1);
    if (!b->data) { free(b); return E_OUTOFMEMORY; }
    memcpy(b->data, bytes, n);
    b->vtbl = &g_blob_vtbl; b->refs = 1; b->size = n;
    *out = (ID3D10Blob *)b;
    return S_OK;
}

/* A 1.0 description differs from 1.1 only by the absence of flags on ranges
 * and root descriptors, so it is lifted to 1.1 with default flags and
 * serialized through the one serializer this runtime has. Bounded: a layout
 * bigger than the parser's own limits is refused here rather than truncated. */
static HRESULT mad_serialize_any(const D3D12_VERSIONED_ROOT_SIGNATURE_DESC *v,
                                 ID3D10Blob **blob, ID3D10Blob **err) {
    D3D12_ROOT_PARAMETER1 params[MAD_ROOT_PARAM_MAX];
    /* ml1009: sized to the description. This was a fixed [32] and both bounds
     * below returned E_NOTIMPL with NO log line at all -- a silent refusal in
     * a path the application cannot see, which is the worst kind. */
    D3D12_DESCRIPTOR_RANGE1 *ranges = NULL;
    D3D12_ROOT_SIGNATURE_DESC1 d1;
    const D3D12_ROOT_SIGNATURE_DESC1 *use;
    unsigned char *out = NULL;
    SIZE_T out_cap = 0;
    SIZE_T n;
    HRESULT hr;

    if (err) *err = NULL;
    if (!v || !blob) return E_INVALIDARG;
    if (v->Version == D3D_ROOT_SIGNATURE_VERSION_1_1) {
        use = &v->Desc_1_1;
    } else if (v->Version == D3D_ROOT_SIGNATURE_VERSION_1_0) {
        const D3D12_ROOT_SIGNATURE_DESC *d0 = &v->Desc_1_0;
        UINT nr = 0, i, j, want = 0;
        if (d0->NumParameters > MAD_ROOT_PARAM_MAX) {
            d3d12_log("[madeira-d3d12] D3D12SerializeRootSignature: %u parameters exceeds the %u this build handles\n",
                      d0->NumParameters, (unsigned)MAD_ROOT_PARAM_MAX);
            return E_NOTIMPL;
        }
        for (i = 0; i < d0->NumParameters; i++)   /* ml1009: count, then allocate */
            if (d0->pParameters[i].ParameterType == D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE)
                want += d0->pParameters[i].DescriptorTable.NumDescriptorRanges;
        if (want > MAD_ROOT_RANGE_SANE) {
            d3d12_log("[madeira-d3d12] D3D12SerializeRootSignature: implausible descriptor range count %u\n", want);
            return E_NOTIMPL;
        }
        if (want) {
            ranges = calloc(want, sizeof *ranges);
            if (!ranges) return E_OUTOFMEMORY;
        }
        memset(&d1, 0, sizeof d1);
        d1.NumParameters = d0->NumParameters;
        d1.pParameters = params;
        d1.NumStaticSamplers = d0->NumStaticSamplers;
        d1.pStaticSamplers = d0->pStaticSamplers;
        d1.Flags = d0->Flags;
        for (i = 0; i < d0->NumParameters; i++) {
            const D3D12_ROOT_PARAMETER *p0 = &d0->pParameters[i];
            memset(&params[i], 0, sizeof params[i]);
            params[i].ParameterType = p0->ParameterType;
            params[i].ShaderVisibility = p0->ShaderVisibility;
            switch (p0->ParameterType) {
            case D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS:
                params[i].Constants = p0->Constants; break;
            case D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE:
                if (nr + p0->DescriptorTable.NumDescriptorRanges > want) {   /* ml1009: our bug if it trips */
                    d3d12_log("[madeira-d3d12] D3D12SerializeRootSignature: range count disagrees with the pre-count "
                              "(%u + %u > %u)\n", nr, p0->DescriptorTable.NumDescriptorRanges, want);
                    free(ranges);
                    return E_NOTIMPL;
                }
                params[i].DescriptorTable.NumDescriptorRanges = p0->DescriptorTable.NumDescriptorRanges;
                params[i].DescriptorTable.pDescriptorRanges = ranges + nr;
                for (j = 0; j < p0->DescriptorTable.NumDescriptorRanges; j++) {
                    const D3D12_DESCRIPTOR_RANGE *r0 = &p0->DescriptorTable.pDescriptorRanges[j];
                    memset(&ranges[nr], 0, sizeof ranges[nr]);
                    ranges[nr].RangeType = r0->RangeType;
                    ranges[nr].NumDescriptors = r0->NumDescriptors;
                    ranges[nr].BaseShaderRegister = r0->BaseShaderRegister;
                    ranges[nr].RegisterSpace = r0->RegisterSpace;
                    ranges[nr].OffsetInDescriptorsFromTableStart = r0->OffsetInDescriptorsFromTableStart;
                    ranges[nr].Flags = D3D12_DESCRIPTOR_RANGE_FLAG_NONE;
                    nr++;
                }
                break;
            default:
                params[i].Descriptor.ShaderRegister = p0->Descriptor.ShaderRegister;
                params[i].Descriptor.RegisterSpace = p0->Descriptor.RegisterSpace;
                params[i].Descriptor.Flags = D3D12_ROOT_DESCRIPTOR_FLAG_NONE;
                break;
            }
        }
        use = &d1;
    } else {
        d3d12_log("[madeira-d3d12] D3D12SerializeVersionedRootSignature: version %u is not supported\n",
                  (unsigned)v->Version);
        return E_NOTIMPL;
    }
    /* ml1009: ask for the size, then serialize into a buffer that fits, instead
     * of a fixed 4096 that a large signature silently outgrows. */
    n = 0;
    hr = MadeiraD3D12SerializeRootSignature(use, NULL, &n);
    if (FAILED(hr) && hr != E_NOT_SUFFICIENT_BUFFER) {
        d3d12_log("[madeira-d3d12] root signature serialization refused while sizing (%#lx)\n", (unsigned long)hr);
        free(ranges);
        return hr;
    }
    if (!n) n = 4096;
    out_cap = n;
    out = malloc(out_cap);
    if (!out) { free(ranges); return E_OUTOFMEMORY; }
    n = out_cap;
    hr = MadeiraD3D12SerializeRootSignature(use, out, &n);
    if (FAILED(hr)) {
        d3d12_log("[madeira-d3d12] root signature serialization refused (%#lx, %llu byte buffer)\n",
                  (unsigned long)hr, (unsigned long long)out_cap);
        free(out); free(ranges);
        return hr;
    }
    hr = mad_make_blob(out, n, blob);
    free(out); free(ranges);
    return hr;
}

HRESULT WINAPI D3D12SerializeRootSignature(
        const D3D12_ROOT_SIGNATURE_DESC *desc, D3D_ROOT_SIGNATURE_VERSION version,
        ID3D10Blob **blob, ID3D10Blob **err) {
    D3D12_VERSIONED_ROOT_SIGNATURE_DESC v;
    (void)version;   /* the description is 1.0-shaped regardless of the requested output version */
    if (!desc) return E_INVALIDARG;
    memset(&v, 0, sizeof v);
    v.Version = D3D_ROOT_SIGNATURE_VERSION_1_0;
    v.Desc_1_0 = *desc;
    return mad_serialize_any(&v, blob, err);
}

HRESULT WINAPI D3D12SerializeVersionedRootSignature(
        const D3D12_VERSIONED_ROOT_SIGNATURE_DESC *desc, ID3D10Blob **blob, ID3D10Blob **err) {
    return mad_serialize_any(desc, blob, err);
}

HRESULT WINAPI D3D12CreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL min_level,
                                                       REFIID riid, void **device) {
    /* A NULL out-pointer is the documented capability probe: answer it without
     * building a device, the way the real runtime does (S_FALSE on support). */
    d3d12_log("[madeira-d3d12] D3D12CreateDevice(adapter=%p, feature level %#x, %s)\n",
              adapter, (unsigned)min_level, device ? "create" : "probe");
    if (!device) return (min_level <= D3D_FEATURE_LEVEL_12_0) ? S_FALSE : E_INVALIDARG;
    return MadeiraD3D12CreateDevice(adapter, min_level, riid, device);
}

HRESULT WINAPI D3D12GetDebugInterface(REFIID riid, void **out) {
    (void)riid;
    if (out) *out = NULL;
    d3d12_log("[madeira-d3d12] D3D12GetDebugInterface: no debug layer on this runtime\n");
    return E_NOINTERFACE;
}

HRESULT WINAPI D3D12GetInterface(REFCLSID clsid, REFIID riid, void **out) {
    (void)clsid; (void)riid;
    if (out) *out = NULL;
    d3d12_log("[madeira-d3d12] D3D12GetInterface refused: no Agility SDK layering here\n");
    return E_NOINTERFACE;
}

HRESULT WINAPI D3D12EnableExperimentalFeatures(UINT n, const IID *iids,
                                                                     void *cfg, UINT *sizes) {
    (void)iids; (void)cfg; (void)sizes;
    d3d12_log("[madeira-d3d12] D3D12EnableExperimentalFeatures(%u) refused\n", n);
    return E_NOTIMPL;
}

/* ml1980: real deserializers (see mad_rsd_create next to the serializer). */
HRESULT WINAPI D3D12CreateRootSignatureDeserializer(
        const void *blob, SIZE_T n, REFIID riid, void **out) {
    return mad_rsd_create(blob, n, riid, out, 0);
}

HRESULT WINAPI D3D12CreateVersionedRootSignatureDeserializer(
        const void *blob, SIZE_T n, REFIID riid, void **out) {
    return mad_rsd_create(blob, n, riid, out, 1);
}

HRESULT WINAPI D3D12CoreCreateLayeredDevice(const void *a, DWORD b, const void *c, REFIID d, void **e) {
    (void)a; (void)b; (void)c; (void)d; if (e) *e = NULL; return E_NOTIMPL;
}
SIZE_T WINAPI D3D12CoreGetLayeredDeviceSize(const void *a, DWORD b) { (void)a; (void)b; return 0; }
HRESULT WINAPI D3D12CoreRegisterLayers(const void *a, DWORD b) { (void)a; (void)b; return E_NOTIMPL; }
