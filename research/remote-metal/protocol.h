/* Remote Metal transport -- shared wire protocol.
 *
 * Forwards winemetal's semantic seam to a real Metal device on a macOS host,
 * so a virtualised iOS guest can render on hardware its own paravirtual Metal
 * cannot reach (no mesh shaders, no BC, no GPU family reported at all).
 *
 * ⚠️ winemetal is a SEMANTIC seam, not a wire protocol. Two things it does
 * today are only legal because guest and host share one address space:
 *
 *   1. obj_handle_t is a raw Objective-C pointer CAST to uint64_t --
 *      `params->ret = (obj_handle_t)[array objectAtIndex:i]`. Across a machine
 *      boundary that is meaningless and unsafe, so this protocol never puts a
 *      host pointer on the wire. Handles are generation-tagged table indices.
 *   2. wmtcmd_* command lists are LINKED THROUGH GUEST POINTERS and carry
 *      further pointers for inline bytes, viewports and scissors. Those must
 *      become contiguous records with offsets before command encoding can be
 *      forwarded. This spike deliberately stops short of that.
 *
 * Synchronous request/response by design. Async completion handlers across a
 * machine boundary are how you get non-deterministic hangs, and correctness
 * comes before throughput here.
 */
#ifndef REMOTE_METAL_PROTOCOL_H
#define REMOTE_METAL_PROTOCOL_H

#include <stdint.h>

#define RM_MAGIC   0x4C544D52u   /* 'RMTL' little-endian */
/* v2: handles carry a tag bit. A v1 peer would read a tagged handle as a wild
 * table index, so the versions are not interoperable and must not silently
 * connect. */
/* 3: NEW_COMMAND_QUEUE carries maxCommandBufferCount, and RETAIN returns
 *    the same handle. An older client that sent the 8-byte queue payload
 *    got an error it ignored and then used a device as a queue, which
 *    terminated the host. Refuse the version rather than misread it. */
#define RM_VERSION 14u
#define RM_PORT    47821

enum rm_op {
    RM_OP_PING = 1,          /* latency floor, no Metal work        */
    RM_OP_COPY_ALL_DEVICES,  /* -> handle to NSArray<MTLDevice>     */
    RM_OP_ARRAY_COUNT,       /* handle -> u64                       */
    RM_OP_ARRAY_OBJECT,      /* handle, index -> handle             */
    RM_OP_DEVICE_NAME,       /* handle -> utf8 bytes                */
    RM_OP_SUPPORTS_FAMILY,   /* handle, family -> u64 (bool)        */
    RM_OP_SUPPORTS_BC,       /* handle -> u64 (bool)                */
    RM_OP_ALLOCATED_SIZE,    /* handle -> u64                       */
    RM_OP_RETAIN,            /* handle -> status                    */
    RM_OP_RELEASE,           /* handle -> status                    */
    RM_OP_STATS,             /* -> live handle count                */

    /* --- offscreen render milestone ------------------------------------ */
    RM_OP_NEW_COMMAND_QUEUE, /* device -> handle                          */
    RM_OP_NEW_BUFFER,        /* device, len, [inline bytes] -> handle     */
    RM_OP_NEW_TEXTURE,       /* device, fmt, w, h -> handle               */
    RM_OP_NEW_LIBRARY,       /* device, [utf8 source] -> handle           */
    RM_OP_NEW_FUNCTION,      /* library, [utf8 name] -> handle            */
    RM_OP_NEW_RENDER_PIPELINE, /* device, vfn, ffn, fmt -> handle         */
    RM_OP_SUBMIT_RENDER_PASS,  /* one round trip: encode, commit, wait    */
    RM_OP_TEXTURE_GETBYTES,    /* texture -> raw pixels                   */

    /* --- presentation ------------------------------------------------- */
    RM_OP_NEXT_DRAWABLE,       /* -> drawable+texture, or RM_ERR_NO_DRAWABLE */
    RM_OP_LAYER_SIZE,          /* -> current host layer size                 */
    RM_OP_DISCARD_DRAWABLE,    /* acquired but never submitted -- give it back */

    /* --- resource control plane -----------------------------------------
     *
     * Ordered as the API census observed a real workload creating them:
     *   shader-cache path -> device -> queries -> queue -> event listener
     *   -> DispatchData blob -> library -> function -> PSO
     *   -> buffers / textures / DSSO / sampler
     *
     * This is a COLD path: 88 creations across an entire cube run against
     * 32,929 command encodings. A synchronous round trip per creation is
     * invisible, so correctness beats cleverness here.
     *
     * ⚠️ Libraries come from a DispatchData blob of precompiled AIR, not from
     * source. An earlier spike used newLibraryWithSource because that is what a
     * hand-written test does; it is not the path DXMT takes. */
    RM_OP_DISPATCH_DATA,       /* [inline blob] -> handle                     */
    RM_OP_NEW_LIBRARY_DATA,    /* device, data -> handle                      */
    RM_OP_NEW_COMPUTE_PSO,     /* device, [WMTComputePipelineInfo] -> handle  */
    RM_OP_NEW_DEPTH_STENCIL,   /* device, [WMTDepthStencilInfo] -> handle     */
    RM_OP_NEW_SAMPLER,         /* device, [WMTSamplerInfo] -> handle          */
    RM_OP_NEW_TEXTURE_INFO,    /* device, [WMTTextureInfo] -> handle          */

    /* --- CPU-visible buffers, transferred in RANGES ---------------------
     *
     * WMTBufferInfo.memory is an inout guest pointer, which works today only
     * because guest and host share an address space. Across machines the guest
     * keeps a shadow copy and ships ranges.
     *
     * Chunked deliberately: a single inline upload is bounded by the payload
     * cap, and AAA resources are far larger than that. Ranges also make dirty
     * tracking possible -- uploading only what changed is the difference
     * between a debugging rig and something usable. */
    RM_OP_BUFFER_CREATE,       /* device, length, options -> handle           */
    RM_OP_BUFFER_WRITE,        /* handle, offset, [inline chunk] -> status    */
    RM_OP_BUFFER_READ,         /* handle, offset, length -> [chunk]           */
    RM_OP_SUBMIT_WMT_BATCH,    /* prologue + packed wmtw batch -> replayed     */

    /* Device capability reporting. These gate everything downstream: the guest
     * compiles shaders and picks formats from what the DEVICE says it can do,
     * so until they answer for the HOST gpu the guest is deciding using the
     * capabilities of a machine that will not run the work. Appended at the end
     * so existing opcode numbers do not move. */
    RM_OP_DEVICE_REGISTRY_ID,  /* device -> u64                               */
    RM_OP_DEVICE_UNIFIED_MEM,  /* device -> u64 (bool)                        */
    RM_OP_DEVICE_MAX_WORKING_SET, /* device -> u64 bytes                      */
    RM_OP_OS_VERSION,          /* -> major, minor, patch                      */
    RM_OP_DEVICE_SET_MAXCC,    /* device, bool -> status                      */

    /* Descriptor calls carry the guest's WMT*Info struct VERBATIM, plus a
     * sidecar for whatever a WMTConstMemoryPointer inside it referenced.
     *
     * Copying descriptors field-by-field into a parallel schema is exactly how
     * the earlier render-pipeline path became a toy: eight colour attachments,
     * blend factors, write masks, topology and tessellation were simply not
     * carried, and nothing said so. Both sides compile the same winemetal.h, so
     * sending the real struct means a field added upstream cannot be silently
     * dropped -- at worst the host ignores something it does not yet read. */
    RM_OP_NEW_RENDER_PSO_INFO,   /* device, WMTRenderPipelineInfo, [archives]  */
    RM_OP_NEW_COMPUTE_PSO_INFO,  /* device, WMTComputePipelineInfo, [archives] */
    RM_OP_NEW_DSS_INFO,          /* device, WMTDepthStencilInfo                */
    RM_OP_NEW_SAMPLER_INFO,      /* device, WMTSamplerInfo -> handle, gpu id   */
    RM_OP_NEW_FUNCTION_CONSTS,   /* library, name, [constants + values]        */

    /* Buffers. The guest is handed a RAW POINTER by MTLBuffer.contents and
     * writes through it with no further calls, so remotely it must write into
     * guest shadow memory and the host copy has to be refreshed from it.
     * updateContents announces some writes; nothing guarantees it announces
     * all of them, hence the pessimistic flush before submission. */
    RM_OP_NEW_BUFFER_INFO,       /* device, WMTBufferInfo -> handle, gpu_address */
    RM_OP_BUFFER_UPLOAD,         /* handle, offset, [inline bytes] -> status     */
    RM_OP_NEW_SHARED_EVENT,      /* device -> handle                             */
    RM_OP_SHARED_EVENT_VALUE,    /* event -> u64 signalled value                 */

    /* Presentation. The HWND stays guest-local: there is no host window for a
     * guest window handle, and the surface actually presented is the host's own
     * CAMetalLayer. This call validates the device and hands back a view token
     * plus that layer, so the drawable path can flow through machinery the host
     * already owns. */
    RM_OP_CREATE_VIEW,           /* device -> view token, layer handle           */
    RM_OP_RELEASE_VIEW,          /* view token -> status                         */

    /* Frame path with PERSISTENT host objects. The earlier SUBMIT_WMT_BATCH
     * built and completed an entire pass per RPC, which cannot express what the
     * census shows: one command buffer, two encoders and twelve packed batches
     * per frame. Metal state has to survive between batches, so the encoder is
     * a real host handle the batches replay into. */
    RM_OP_COMMAND_BUFFER,        /* queue -> command buffer handle               */
    RM_OP_RENDER_ENCODER,        /* cmdbuf, WMTRenderPassInfo -> encoder handle  */
    RM_OP_ENCODE_INTO,           /* encoder + packed wmtw batch -> replayed count */
    RM_OP_END_ENCODING,          /* encoder -> status                            */
    RM_OP_PRESENT_DRAWABLE,      /* cmdbuf, drawable -> status                   */
    RM_OP_COMMIT,                /* cmdbuf -> status                             */
    RM_OP_WAIT_COMPLETED,        /* cmdbuf -> status                             */
    RM_OP_CMDBUF_STATUS,         /* cmdbuf -> u64                                */
    RM_OP_ENCODE_SIGNAL,         /* cmdbuf, event, value -> status               */
    RM_OP_ENCODE_WAIT,           /* cmdbuf, event, value -> status               */
    RM_OP_TEXTURE_DIMS,          /* texture -> width, height                     */

    /* Textures. Until these exist on the host a render pass has a colour
     * attachment and no depth, while the pipeline declares a depth format --
     * and building the encoder makes Metal compile a framebuffer background
     * program that ABORTS the process on that mismatch. */
    RM_OP_NEW_TEXTURE_FULL,      /* device, WMTTextureInfo -> handle, gpu id     */
    RM_OP_TEXTURE_REPLACE,       /* texture, region, [inline bytes] -> status    */
    RM_OP_NEW_TEXTURE_VIEW,      /* texture, fmt, type, levels, slices -> handle */

    /* Layer properties. The host was overwriting drawableSize with its own
     * window backing size on every acquisition, so a guest asking for 1024x768
     * drew into the top-left of a 1280x960 drawable and the rest stayed clear
     * -- the black padding on the right and bottom. */
    RM_OP_LAYER_SET_PROPS,       /* layer, WMTLayerProps -> status               */
    RM_OP_LAYER_GET_PROPS,       /* layer -> WMTLayerProps                       */

    /* Device queries a real title needs. minimumLinearTextureAlignment in
     * particular must NOT be answered with zero: the caller divides by it, and
     * a zero alignment produced a zero-sized allocation and a memcpy into a
     * null destination. */
    RM_OP_MIN_LINEAR_ALIGN,      /* device, pixel format -> u64 alignment        */
    RM_OP_SUPPORTS_SAMPLE_COUNT, /* device, count -> u64 (bool)                  */
    RM_OP_BLIT_ENCODER,          /* cmdbuf -> blit encoder handle                */
    RM_OP_BLIT_INTO,             /* encoder + packed blit batch -> replayed      */
    RM_OP_SET_LABEL,             /* encoder, [utf8 label] -> status              */
    RM_OP_BUFFER_NEW_TEXTURE,    /* buffer, WMTTextureInfo, offset, bpr -> handle */

    /* Compute. A modern engine does much of its frame here, so an unrouted
     * compute encoder is not a missing corner -- it is most of the work
     * silently not happening. Commands travel verbatim like the blit stream,
     * with one exception: SetBytes carries a guest pointer, so its payload is
     * inlined after the struct. */
    RM_OP_COMPUTE_ENCODER,       /* cmdbuf -> compute encoder handle             */
    RM_OP_COMPUTE_INTO,          /* encoder + packed compute batch -> replayed   */
    RM_OP_TEXTURE_MIPLEVELS,     /* texture -> u64 mip count                     */
    RM_OP_NEW_MESH_PSO_INFO,     /* device, WMTMeshRenderPipelineInfo -> handle  */

    /* ml821: coalesced messages. ROUND-TRIP COUNT, not bytes, is what bounds
     * the frame rate. One late gameplay interval spent 369 ms of a 524 ms frame
     * on 2,197 serialized calls; 1,153 were buffer uploads averaging 1,179
     * bytes against an 8 MB cap. These carry many operations per round trip and
     * differ in NO other way from the single-operation forms. */
    RM_OP_BUFFER_UPLOAD_MULTI,   /* header, data, range descriptors -> status    */
    RM_OP_RELEASE_MULTI,         /* header, handles -> status                    */

    /* ml880: residency sets. A D3D12 title reaches most of its resources
     * through descriptors, i.e. indirectly; declaring them per draw with
     * useResource was capped at 256 and the GPU faulted on the first
     * compute dispatch that touched an undeclared buffer. One set on the
     * queue, every allocation added once, committed when it changes. */
    RM_OP_NEW_RESIDENCY_SET,     /* device, u64 capacity -> handle              */
    RM_OP_RESIDENCY_ADD,         /* set, allocation -> status                    */
    RM_OP_RESIDENCY_COMMIT,      /* set -> status                                */
    RM_OP_QUEUE_ADD_RESIDENCY,   /* queue, set -> status                         */
    RM_OP_NEW_GEOM_PSO_INFO,     /* ml927: device, WMTMeshRenderPipelineInfo + WMTGeometryEmulationInfo -> handle (converter geometry emulation) */
    RM_OP_RESIDENCY_BATCH,       /* validated add/remove/all; action 0 probes support */
    RM_OP_COMMAND_BUFFER_PROPERTY, /* command buffer timestamp in nanoseconds */
    RM_OP_HEAP_BUFFER_SIZE,        /* device, buffer size and options -> size and alignment */
    RM_OP_HEAP_TEXTURE_SIZE,       /* device, texture descriptor -> size and alignment */
};

struct rm_heap_buffer_size { uint64_t device, length, options; };
struct rm_size_and_align { uint64_t size, align; };

struct rm_buf_texture { uint64_t buffer; uint64_t offset; uint64_t bytes_per_row; };

struct rm_tex_replace {
    uint64_t texture;
    uint32_t x, y, z, w, h, d;
    uint32_t level, slice;
    uint32_t bytes_per_row, bytes_per_image;
};
struct rm_tex_view {
    uint64_t texture;
    uint32_t format, texture_type;
    uint32_t level_start, level_count, slice_start, slice_count, swizzle;
};

struct rm_encode_sig { uint64_t cmdbuf; uint64_t event; uint64_t value; };
struct rm_present    { uint64_t cmdbuf; uint64_t drawable; };

struct rm_ret_view { uint64_t view; uint64_t layer; };

/* owner = the device, or the library for the function-constants call. */
struct rm_wmt_info {
    uint64_t owner;
    uint32_t info_len;      /* bytes of WMT*Info immediately following   */
    uint32_t extra_count;   /* u64 handles (archives) following the info */
};

/* One specialisation constant. The guest resolves its VALUE and inlines it;
 * the pointer inside WMTFunctionConstant cannot cross. */
struct rm_fn_const { uint16_t type; uint16_t index; uint32_t value_len; };

struct rm_ret_handle_u64 { uint64_t handle; uint64_t value; };

struct rm_os_version { uint32_t major, minor, patch, pad; };

#define RM_CHUNK_BYTES (8u << 20)   /* per-message ceiling for a range */

struct rm_buffer_create { uint64_t device; uint64_t length; uint32_t options; uint32_t pad; };
struct rm_buffer_range  { uint64_t handle; uint64_t offset; uint64_t length; };

/* ml821 coalesced upload. Layout is: this header, then `data_bytes` of packed
 * payload, then `count` rm_buffer_range descriptors whose lengths sum to
 * data_bytes and whose data appears in the SAME ORDER.
 *
 * Descriptors trail the data so a sender can append payload as it walks its
 * buffers without ever moving what it already wrote. */
struct rm_buffer_multi { uint32_t count; uint32_t data_bytes; };
struct rm_release_multi { uint32_t count; uint32_t reserved; };
#define RM_MULTI_MAX_RANGES  512u
#define RM_MULTI_MAX_HANDLES 256u

/* THE framing validator for a coalesced upload. Both sides call this one
 * function: a host that walks the message its own way would only prove that the
 * host works. Checks self-consistency -- descriptor area present, lengths
 * summing to data_bytes, nothing overflowing -- in 64-bit arithmetic, because
 * 32-bit sums of attacker-controlled lengths wrap. Handle validity and buffer
 * bounds need the host registry and are NOT checked here. */
static inline int rm_multi_ok(const void *payload, uint32_t payload_len,
                              const struct rm_buffer_range **ranges_out,
                              const uint8_t **data_out) {
    if (payload_len < sizeof(struct rm_buffer_multi)) return 0;
    const struct rm_buffer_multi *m = (const struct rm_buffer_multi *)payload;
    if (m->count == 0 || m->count > RM_MULTI_MAX_RANGES) return 0;
    uint64_t need = (uint64_t)sizeof *m + (uint64_t)m->data_bytes
                  + (uint64_t)m->count * sizeof(struct rm_buffer_range);
    if (need != (uint64_t)payload_len) return 0;
    const uint8_t *data = (const uint8_t *)payload + sizeof *m;
    const struct rm_buffer_range *r = (const struct rm_buffer_range *)(data + m->data_bytes);
    uint64_t sum = 0;
    for (uint32_t i = 0; i < m->count; i++) {
        if (r[i].length == 0 || r[i].length > RM_CHUNK_BYTES) return 0;
        sum += r[i].length;
        if (sum > (uint64_t)m->data_bytes) return 0;
    }
    if (sum != (uint64_t)m->data_bytes) return 0;
    if (ranges_out) *ranges_out = r;
    if (data_out) *data_out = data;
    return 1;
}

static inline int rm_release_multi_ok(const void *payload, uint32_t payload_len,
                                     const uint64_t **handles_out) {
    if (payload_len < sizeof(struct rm_release_multi)) return 0;
    const struct rm_release_multi *m = (const struct rm_release_multi *)payload;
    if (m->count == 0 || m->count > RM_MULTI_MAX_HANDLES) return 0;
    uint64_t need = (uint64_t)sizeof *m + (uint64_t)m->count * sizeof(uint64_t);
    if (need != (uint64_t)payload_len) return 0;
    if (handles_out) *handles_out = (const uint64_t *)((const uint8_t *)payload + sizeof *m);
    return 1;
}

/* Submit a REAL packed winemetal batch: this prologue, then the wmtw_batch
 * payload the guest packer produced. The host validates it with the same
 * wmtw_validate_batch the tests use, then replays it onto a Metal encoder.
 * Nothing is replayed before validation -- the batch is untrusted input. */
struct rm_wmt_submit {
    uint64_t queue;
    uint64_t color_texture;
    uint64_t present_drawable;      /* 0 for offscreen */
    double   clear_r, clear_g, clear_b, clear_a;
    uint32_t batch_bytes;
    uint32_t reserved;
};

/* The info structs are pointer-free, so they cross as flat bytes with no
 * fixup -- verified against winemetal.h rather than assumed. Only the handle
 * fields need translating, and those are already tagged. */
struct rm_arg_device_blob { uint64_t device; };   /* + inline struct/blob */

/* Descriptors are IN/OUT, not flat input. The reply carries the updated struct
 * back, because the caller reads fields the host fills in:
 *   WMTSamplerInfo.gpu_resource_id   out
 *   WMTTextureInfo.gpu_resource_id   out
 *   WMTTextureInfo.mach_port         in/out
 *
 * ⛔ mach_port CANNOT cross machines. A Mach port name is meaningful only
 * within one task on one kernel, so a texture shared by port is unsupported
 * remotely; the host returns 0 and the guest must not treat it as valid. This
 * is a real capability gap, not an omission. */
struct rm_ret_descriptor { uint64_t handle; /* + updated descriptor bytes */ };

/* Descriptors as SEMANTIC fields, not native layouts.
 *
 * Copying winemetal's structs byte-for-byte would tie the wire to a header the
 * host does not include and to enum values that are Metal's, not ours. Naming
 * the fields explicitly means a winemetal layout change breaks a compile on the
 * guest translation rather than silently shifting values on the wire. All
 * fixed-width; enums travel as uint32 and are validated host-side.
 */
struct rm_stencil_desc {
    uint32_t enabled, depth_stencil_pass_op, stencil_fail_op, depth_fail_op;
    uint32_t compare_function, write_mask, read_mask, pad;
};
struct rm_dss_desc {
    uint64_t device;
    uint32_t depth_compare_function, depth_write_enabled;
    struct rm_stencil_desc front, back;
};
struct rm_sampler_desc {
    uint64_t device;
    uint32_t min_filter, mag_filter, mip_filter;
    uint32_t r_address, s_address, t_address;
    uint32_t border_color, compare_function, max_anisotropy;
    float    lod_min_clamp, lod_max_clamp;
    uint32_t normalized_coords, lod_average, support_argument_buffers, pad;
};
struct rm_texture_desc {
    uint64_t device;
    uint32_t pixel_format, width, height, depth, array_length;
    uint32_t type, mipmap_level_count, sample_count, usage, options;
};
/* Reply for an in/out descriptor: the handle plus the fields the host filled.
 * mach_port is ALWAYS 0 -- a Mach port name is meaningful only within one task
 * on one kernel, so texture sharing by port cannot work remotely. */
struct rm_ret_resource { uint64_t handle; uint64_t gpu_resource_id; uint32_t mach_port; uint32_t pad; };

/* WMTComputePipelineInfo, flattened. binary_archives_for_lookup is a guest
 * pointer in the original and travels here as a sidecar array of handles
 * following this struct. */
struct rm_compute_pso {
    uint64_t device;
    uint64_t function;
    uint64_t archive_for_serialization;
    uint32_t immutable_buffers;
    uint8_t  num_archives;
    uint8_t  fail_on_archive_miss;
    uint8_t  tgsize_multiple_of_sgwidth;
    uint8_t  pad;
};

struct rm_ret_drawable { uint64_t drawable; uint64_t texture; uint64_t width; uint64_t height; };

/* ---- contiguous command stream -----------------------------------------
 *
 * winemetal's wmtcmd_* lists are linked through GUEST POINTERS and carry
 * further pointers for inline bytes, viewports and scissors -- none of which
 * can cross a machine boundary. This is the shape they have to become: a
 * self-describing contiguous byte stream where every record states its own
 * size, and variable-length data is inline rather than referenced.
 *
 * Walk it with `off += rec->size`, never by following a pointer. */
enum rm_enc {
    RM_ENC_SET_PIPELINE = 1,   /* handle                               */
    RM_ENC_SET_VERTEX_BUFFER,  /* handle, offset, index                */
    RM_ENC_SET_VERTEX_BYTES,   /* index, len, inline bytes             */
    RM_ENC_SET_VIEWPORT,       /* x, y, w, h, znear, zfar (inline)     */
    RM_ENC_DRAW,               /* primitive, start, count              */
};

struct rm_enc_hdr { uint16_t type; uint16_t pad; uint32_t size; };   /* size covers hdr+body */

struct rm_enc_pipeline { struct rm_enc_hdr h; uint64_t pipeline; };
struct rm_enc_vbuf     { struct rm_enc_hdr h; uint64_t buffer; uint64_t offset; uint64_t index; };
struct rm_enc_draw     { struct rm_enc_hdr h; uint64_t primitive; uint64_t start; uint64_t count; };
struct rm_enc_viewport { struct rm_enc_hdr h; double x, y, w, h_, znear, zfar; };

/* Render pass: descriptor, then `cmd_bytes` of the stream above. One round
 * trip encodes, commits and waits -- which is where the batching win is. */
struct rm_render_pass {
    uint64_t queue;
    uint64_t color_texture;
    /* When non-zero, presentDrawable is encoded on the SAME command buffer
     * before commit -- which is Metal's intended sequencing. Presenting from a
     * separate call after the render buffer has already committed would be
     * wrong. The handle is consumed and invalidated by this submit, so a
     * drawable cannot leak or be presented twice. */
    uint64_t present_drawable;
    double   clear_r, clear_g, clear_b, clear_a;
    uint32_t cmd_bytes;
    uint32_t reserved;
};

struct rm_new_buffer  { uint64_t device; uint64_t length; };  /* + inline bytes */
struct rm_new_texture { uint64_t device; uint64_t pixel_format; uint64_t width; uint64_t height; };
struct rm_new_pipeline{ uint64_t device; uint64_t vfn; uint64_t ffn; uint64_t pixel_format; };

enum rm_status {
    RM_OK = 0,
    RM_ERR_BAD_MAGIC,
    RM_ERR_BAD_VERSION,
    RM_ERR_BAD_OPCODE,
    RM_ERR_STALE_HANDLE,   /* generation mismatch: released, then reused */
    RM_ERR_BAD_HANDLE,     /* out of range / never allocated            */
    RM_ERR_WRONG_CLASS,    /* handle valid but not the expected class   */
    RM_ERR_SHORT_PAYLOAD,
    RM_ERR_NO_DRAWABLE,    /* nextDrawable timed out -- a distinct answer, not a hang */
};

/* Every frame, both directions. payload_len counts bytes AFTER this header. */
struct rm_hdr {
    uint32_t magic;
    uint16_t version;
    uint16_t opcode;
    uint32_t seq;          /* echoed, so a desync is detectable */
    uint32_t status;       /* request: 0. response: enum rm_status */
    uint32_t payload_len;
    uint32_t reserved;
};

/* A handle is TAG | (generation << 32) | slot, where the tag is bit 63.
 *
 * The tag exists so a local Objective-C pointer can never be mistaken for a
 * remote handle, or vice versa. winemetal's obj_handle_t is a raw pointer cast,
 * and user-space pointers on arm64 never set bit 63 -- so a tagged value is
 * unambiguously remote and an untagged one unambiguously local.
 *
 * This matters because the switch cannot be atomic across an entire process:
 * during bring-up some producers will be remote while some consumers are still
 * local. Without the tag that mixture renders a subtly wrong frame on another
 * machine with nothing pointing at the cause. With it, the first mixed use is
 * a named error at the exact call that mixed them.
 *
 * Generation increments on reuse, so a stale handle is REJECTED rather than
 * silently addressing a different object. */
#define RM_HANDLE_TAG   (1ull << 63)
#define RM_IS_REMOTE(h) (((h) & RM_HANDLE_TAG) != 0)
#define RM_IS_LOCAL(h)  ((h) != 0 && ((h) & RM_HANDLE_TAG) == 0)
#define RM_HANDLE(gen, slot) (RM_HANDLE_TAG | ((uint64_t)(gen) << 32) | (uint32_t)(slot))
#define RM_HANDLE_GEN(h)     ((uint32_t)(((h) & ~RM_HANDLE_TAG) >> 32))
#define RM_HANDLE_SLOT(h)    ((uint32_t)((h) & 0xffffffffu))
#define RM_NULL_HANDLE       0ull

struct rm_arg_handle       { uint64_t handle; };
struct rm_arg_handle_u64   { uint64_t handle; uint64_t arg; };

#define RM_RESIDENCY_BATCH_MAX 65536u
enum rm_residency_action { RM_RESIDENCY_PROBE, RM_RESIDENCY_ADD, RM_RESIDENCY_REMOVE, RM_RESIDENCY_REMOVE_ALL };
struct rm_residency_batch { uint64_t set; uint32_t action; uint32_t count; /* uint64_t handles follow */ };
static inline int rm_residency_batch_valid(const struct rm_residency_batch *a, uint32_t len) {
    if (len < sizeof(*a) || a->count > RM_RESIDENCY_BATCH_MAX ||
        len != sizeof(*a) + (uint64_t)a->count * sizeof(uint64_t)) return 0;
    if (a->action == RM_RESIDENCY_PROBE) return !a->set && !a->count;
    if (!a->set) return 0;
    if (a->action == RM_RESIDENCY_REMOVE_ALL) return !a->count;
    return a->action == RM_RESIDENCY_ADD || a->action == RM_RESIDENCY_REMOVE;
}
struct rm_ret_u64          { uint64_t value; };
struct rm_ret_handle       { uint64_t handle; };

#endif
