/* Shared ABI between the ARM64EC D3D12 runtime and the native shader-converter
 * service, crossed exactly once per pipeline creation via winemetal's unix call.
 *
 * Why this lives in its own header rather than inside either side: the two ends
 * are compiled by different toolchains (mingw ARM64EC PE, and Apple clang for
 * the Mach-O side), so a struct described twice would drift silently and the
 * first symptom would be a misread field rather than a build error.
 *
 * Every field is fixed-width and the struct is explicitly padded, because the
 * two compilers only agree on layout if nothing is left to their discretion.
 *
 * Pointers cross as uint64_t. Both sides are 64-bit and share one address
 * space, but writing them as pointers would make the layout depend on each
 * compiler's pointer type, which is exactly what this header exists to avoid. */
#ifndef MADEIRA_IR_ABI_H
#define MADEIRA_IR_ABI_H

#include <stdint.h>

#define MADEIRA_IR_ENTRY_MAX 256

/* Deliberately NOT the D3D12 enum values. The unix side must not include d3d12.h
 * and the converter has its own enum; naming our own constants means the mapping
 * is written out once, in one place, instead of relying on two vendors happening
 * to agree. */
enum madeira_ir_param_type {
    MADEIRA_IR_PARAM_TABLE     = 0,
    MADEIRA_IR_PARAM_CONSTANTS = 1,
    MADEIRA_IR_PARAM_CBV       = 2,
    MADEIRA_IR_PARAM_SRV       = 3,
    MADEIRA_IR_PARAM_UAV       = 4,
};

enum madeira_ir_range_type {
    MADEIRA_IR_RANGE_SRV     = 0,
    MADEIRA_IR_RANGE_UAV     = 1,
    MADEIRA_IR_RANGE_CBV     = 2,
    MADEIRA_IR_RANGE_SAMPLER = 3,
};

enum madeira_ir_visibility {
    MADEIRA_IR_VIS_ALL      = 0,
    MADEIRA_IR_VIS_VERTEX   = 1,
    MADEIRA_IR_VIS_HULL     = 2,
    MADEIRA_IR_VIS_DOMAIN   = 3,
    MADEIRA_IR_VIS_GEOMETRY = 4,
    MADEIRA_IR_VIS_PIXEL    = 5,
};

enum madeira_ir_os { MADEIRA_IR_OS_IOS = 0, MADEIRA_IR_OS_MACOS = 1 };

/* Each distinct failure gets its own code so a device log says which step gave
 * way. A single generic failure code would make "the converter is missing" and
 * "this shader does not compile" indistinguishable, and those need opposite
 * responses. */
enum madeira_ir_status {
    MADEIRA_IR_OK              = 0,
    MADEIRA_IR_NO_DYLIB        = 1,  /* the converter could not be loaded at all */
    MADEIRA_IR_NO_SYMBOL       = 2,  /* loaded, but an entry point is missing */
    MADEIRA_IR_BAD_DXIL        = 3,  /* the converter rejected the bytecode */
    MADEIRA_IR_BAD_ROOTSIG     = 4,  /* the converter rejected the root signature */
    MADEIRA_IR_COMPILE_FAILED  = 5,
    MADEIRA_IR_NO_METALLIB     = 6,  /* compiled, but produced no library */
    MADEIRA_IR_BUFFER_TOO_SMALL= 7,  /* ret_len holds the size actually needed */
    MADEIRA_IR_EMPTY_ENTRY     = 8,  /* reflection gave no name: see below */
    MADEIRA_IR_UNSUPPORTED     = 9,  /* a root parameter we do not model yet */
    MADEIRA_IR_NO_MEMORY       = 10,
    /* ml1008: the DXBC/SM5.x backend. A container that is neither DXIL nor a
     * shader-model-5 program, and a declaration shape the backend would have
     * to guess at, are different failures and get different codes. */
    MADEIRA_IR_BAD_CONTAINER     = 11, /* not a DXBC container, or self-inconsistent */
    MADEIRA_IR_UNSUPPORTED_RANGE = 12, /* non-singleton range, or a register space we do not map */
    MADEIRA_IR_TOO_MANY_RANGES   = 13, /* more declaration ranges than the caller's buffer holds */
};

/* ml1008: which compiler produced a stage. A shader's bindings, reflection and
 * cache identity all differ between the two, so this is recorded per stage and
 * never inferred from whichever shader a pipeline compiled first. */
enum madeira_ir_ps_flag {
    MADEIRA_IR_PS_DUAL_SOURCE_BLEND = 1u << 0,
    MADEIRA_IR_PS_DISABLE_DEPTH     = 1u << 1,
};

enum madeira_ir_backend {
    MADEIRA_IR_BACKEND_MSC     = 0,  /* Apple's Metal Shader Converter, DXIL only */
    MADEIRA_IR_BACKEND_AIRCONV = 1,  /* our in-tree DXBC -> AIR compiler, SM 5.x */
};

/* ml1008: one declaration range from the DXBC backend, joined with the
 * reflected argument it describes.
 *
 * `range_id` is the declaration handle, NOT the register: under SM 5.1 a shader
 * can declare range id 0 at b17, and 22 of the 24 measured shaders do exactly
 * that. `lower_bound` is the register the root signature must be searched for.
 * `ptr_offset` is a 64-BIT WORD index into the argument table, not a byte
 * offset. `flags` selects the encoding and mirrors MTL_SM50_SHADER_ARGUMENT. */
/* ml1010: 64 was my own guess and RDR2's pixel shaders need 65-67, which the
 * self-calibrating refusal reported exactly ("67 declaration ranges, this
 * build carries 64"). 256 is sized from that evidence plus headroom; the
 * refusal still prints the count, so the next wall names itself too. */
#define MADEIRA_IR_AIR_RANGE_MAX 256
enum madeira_ir_air_type {
    MADEIRA_IR_AIR_CBV     = 0,
    MADEIRA_IR_AIR_SAMPLER = 1,
    MADEIRA_IR_AIR_SRV     = 2,
    MADEIRA_IR_AIR_UAV     = 3,
};
/* The subset of MTL_SM50_SHADER_ARGUMENT_FLAG the encoder actually branches on.
 * Written out here so the PE side does not include the compiler's header. */
enum madeira_ir_air_flag {
    MADEIRA_IR_AIR_F_BUFFER         = 1u << 0,
    MADEIRA_IR_AIR_F_TEXTURE        = 1u << 1,
    MADEIRA_IR_AIR_F_ELEMENT_WIDTH  = 1u << 2,
    MADEIRA_IR_AIR_F_UAV_COUNTER    = 1u << 3,
    MADEIRA_IR_AIR_F_MINLOD_CLAMP   = 1u << 4,
    MADEIRA_IR_AIR_F_TBUFFER_OFFSET = 1u << 5,
    MADEIRA_IR_AIR_F_TEXTURE_ARRAY  = 1u << 6,
    MADEIRA_IR_AIR_F_READ           = 1u << 10,
    MADEIRA_IR_AIR_F_WRITE          = 1u << 11,
};
struct madeira_ir_air_range {
    uint32_t type;          /* madeira_ir_air_type */
    uint32_t range_id;      /* the declaration handle, not the register */
    uint32_t space;         /* register space */
    uint32_t lower_bound;   /* the D3D register: 17 for b17 */
    uint32_t size;          /* 1 == singleton; 0xffffffff == unbounded */
    uint32_t ptr_offset;    /* 64-bit WORD index into the argument table */
    uint32_t flags;         /* madeira_ir_air_flag */
    uint32_t cb_table;      /* 1 = lives in the constant-buffer table, not the argument table */
};

struct madeira_ir_root_param {
    uint32_t type;              /* madeira_ir_param_type */
    uint32_t shader_register;
    uint32_t register_space;
    uint32_t num_constants;     /* MADEIRA_IR_PARAM_CONSTANTS only */
    uint32_t visibility;        /* madeira_ir_visibility */
    uint32_t num_ranges;        /* MADEIRA_IR_PARAM_TABLE only */
    uint32_t first_range;       /* index into the ranges array */
    uint32_t reserved;
};

struct madeira_ir_root_range {
    uint32_t range_type;        /* madeira_ir_range_type */
    uint32_t num_descriptors;
    uint32_t base_register;
    uint32_t register_space;
    uint32_t table_offset;
    uint32_t reserved;
};

/* One conversion: one DXIL blob, one entry point, one target.
 *
 * The caller supplies the output buffer. The service allocating and handing
 * back converter-owned memory would put a free() across the PE/unix boundary,
 * and the lifetime rule that avoids is the same one the canary follows: nothing
 * the converter owns escapes the call that created it. */
struct madeira_ir_convert_args {
    uint64_t dxil;              /* in: bytecode the application supplied */
    uint64_t dxil_len;          /* in */
    uint64_t entry_point;       /* in: const char *, the D3D-side entry name */

    uint64_t params;            /* in: const struct madeira_ir_root_param * */
    uint64_t num_params;        /* in */
    uint64_t ranges;            /* in: const struct madeira_ir_root_range * */
    uint64_t num_ranges;        /* in */
    uint64_t root_flags;        /* in: reserved, must be 0 */

    uint32_t target_os;         /* in: madeira_ir_os */
    uint32_t gpu_family;        /* in: IRGPUFamily, chosen from the real device */
    uint64_t os_version;        /* in: const char *, e.g. "17.0" */

    uint64_t out_buf;           /* in: where to write the metallib, may be 0 */
    uint64_t out_cap;           /* in: capacity of out_buf */
    uint64_t out_entry;         /* in: char[MADEIRA_IR_ENTRY_MAX] for the name */

    uint64_t ret_len;           /* out: metallib size, set even when too small */
    uint32_t ret_stage;         /* out: IRShaderStage the converter reported */
    uint32_t ret_status;        /* out: madeira_ir_status */
    uint32_t ret_error_code;    /* out: the converter's own code, when it gave one */
    uint32_t reserved;
    /* ml859: vertex-stage inputs from reflection, so a pipeline can map the
     * application's input layout onto the attribute indices the converted
     * vertex shader actually reads. Ignored for other stages. */
    uint64_t out_vs_inputs;     /* in: struct madeira_ir_vs_input[vs_input_cap], may be 0 */
    uint32_t vs_input_cap;      /* in */
    uint32_t ret_vs_input_count;/* out: how many the shader has (may exceed cap) */
    uint64_t samplers;          /* in: const struct madeira_ir_static_sampler *, may be 0 */
    uint32_t num_samplers;      /* in */
    uint32_t reserved2;
    uint32_t ret_tg_size[3];    /* out: compute threadgroup size from reflection */
    uint32_t reserved3;
    char ret_note[128];         /* out: a diagnostic sentence from the service, may be empty */
    /* ml882: where the converter placed each top-level resource in the
     * argument buffer (IRShaderReflectionGetResourceLocations). Ground truth
     * for the layout; the runtime's own computation is checked against it. */
    uint64_t out_locs;          /* in: struct madeira_ir_loc[loc_cap], may be 0 */
    uint32_t loc_cap;           /* in */
    uint32_t ret_loc_count;     /* out: how many the shader references (may exceed cap) */
    /* ml927: geometry-shader pipelines go through the converter's mesh
     * emulation. Every stage of such a pipeline is compiled with emulation on;
     * the vertex stage also gets a stage-in function synthesized from the
     * application's input layout (a second metallib), and reflection reports
     * the numbers the pipeline and the draws need. */
    uint32_t gs_emulation;      /* in: 1 = this stage belongs to a pipeline with a geometry shader */
    uint32_t input_topology;    /* in: D3D12_PRIMITIVE_TOPOLOGY_TYPE (1 point, 2 line, 3 triangle) */
    uint64_t layout;            /* in: const struct madeira_ir_input_layout *, vertex stage only */
    uint64_t out_buf2;          /* in: where the stage-in metallib goes, may be 0 */
    uint64_t out_cap2;          /* in */
    uint64_t ret_len2;          /* out: stage-in metallib size (0 = none produced) */
    uint32_t ret_vs_output_size;/* out: vertex-stage output size in bytes */
    uint32_t ret_gs_max_prims;  /* out: geometry stage: max input primitives per mesh threadgroup */
    uint32_t ret_gs_payload;    /* out: geometry stage: payload bytes */
    uint32_t ret_gs_passthrough;/* out: geometry stage: the converter calls it a passthrough */
    /* ml1008: the DXBC/SM5.x backend. RDR2 feeds D3D12 shader-model-5.1 DXBC,
     * which Apple's converter refuses outright (IRErrorCodeUnrecognizedDXILHeader,
     * code 14, on all 189 of its shaders). Those go to our in-tree compiler
     * instead, which binds through two argument buffers at fixed Metal indices
     * rather than the MSC top-level layout -- so the runtime needs to know which
     * backend ran and what the table shape is. */
    /* ml1023: the pixel-stage PSO facts the DXBC backend needs. DXMT's D3D11
     * path passes these for EVERY pixel shader; we passed nothing, and the host
     * rejected pipelines with "Fragment shader does not write to render target
     * color(0), index(1) that is required for blending" -- index(1) is the
     * second output of DUAL-SOURCE blending, which the compiler only emits when
     * told. unorm_output_reg_mask likewise changes output clamping. */
    uint32_t ps_sample_mask;         /* in: D3D12_GRAPHICS_PIPELINE_STATE_DESC::SampleMask */
    uint32_t ps_flags;               /* in: madeira_ir_ps_flag */
    uint32_t ps_unorm_output_mask;   /* in: bit i set = render target i has a UNORM format */
    uint32_t ps_valid;               /* in: 1 = the three fields above are meaningful */

    /* ml1031: the vertex stage this pixel shader will be paired with.
     *
     * D3D lets a PS read an interpolant the VS never writes (undefined value);
     * Metal rejects the whole pipeline for it ("Fragment input(s) `user(...)`
     * mismatching vertex shader output"). A rejected pipeline is a NULL pipeline
     * and its draws vanish -- 4 of RDR2's G-buffer pipelines died this way.
     * Given the vertex bytecode, the DXBC backend parses its output signature
     * and zero-fills any input the vertex stage does not provide.
     * 0 => no filtering. Ignored for non-pixel stages. */
    uint64_t vs_bytecode;            /* in: const void *, the paired VS container */
    uint64_t vs_bytecode_len;        /* in */
    uint64_t out_air_ranges;    /* in: struct madeira_ir_air_range[air_range_cap], may be 0 */
    uint32_t air_range_cap;     /* in */
    uint32_t ret_air_nranges;   /* out: how many the shader has (may exceed cap) */
    uint32_t ret_backend;       /* out: madeira_ir_backend */
    uint32_t ret_cb_table_bind; /* out: Metal buffer index of the constant-buffer table, ~0u if none */
    uint32_t ret_arg_table_bind;/* out: Metal buffer index of the argument table, ~0u if none */
    uint32_t ret_arg_qwords;    /* out: argument table size in 64-bit words */
    /* ml1011: the vertex-buffer slots the backend compiled its fetch against.
     * Its table is indexed by PACKED position within this mask, not by raw
     * slot, so the runtime must build the table against the same mask. */
    uint32_t ret_air_slot_mask;
    uint32_t reserved_ml1011b;
    /* ml1083: TESSELLATION through the DXBC backend's mesh-shader emulation.
     *
     * The hull/domain pair becomes an object/mesh pipeline: the OBJECT function
     * is the vertex and hull shaders fused (the vertex stage fetches through the
     * vertex-buffer table at 16, reads the draw arguments at 21 and the index
     * buffer at 20, binds ITS tables at 27/28, the hull's at 29/30); the MESH
     * function is the domain shader with its own tables at 29/30. Two requests:
     * tess_stage 1 compiles the object function (dxil = the vertex shader, plus
     * hs/ds bytecode; the domain shader is needed for the maximum potential
     * tessellation factor, which both functions must agree on), tess_stage 2
     * compiles the mesh function (dxil = the domain shader, plus hs bytecode).
     * The object function is specialised on the index format, exactly as the
     * D3D11 layer specialises it, so the caller compiles one per format used. */
    uint32_t tess_stage;            /* in: 0 none, 1 object (VS+HS), 2 mesh (DS) */
    uint32_t tess_index_format;     /* in: object stage: 0 non-indexed, 1 uint16, 2 uint32 */
    uint64_t hs_bytecode, hs_bytecode_len;   /* in: the hull shader container */
    uint64_t ds_bytecode, ds_bytecode_len;   /* in: the domain shader container (object stage) */
    uint32_t ret_threads_per_patch; /* out (object): object threadgroup width per patch */
    uint32_t ret_tess_out_prim;     /* out (object): 1 point, 2 line, 3 tri cw, 4 tri ccw */
    uint32_t ret_max_potential_factor; /* out: the factor both functions were built for */
    uint32_t ret_air_nranges2;      /* out (object): how many ranges the HULL has */
    uint64_t out_air_ranges2;       /* in (object): struct madeira_ir_air_range[air_range_cap2] for the hull */
    uint32_t air_range_cap2;        /* in */
    uint32_t ret_cb_table_bind2;    /* out (object): the hull's constant-buffer table index, ~0u if none */
    uint32_t ret_arg_table_bind2;   /* out (object): the hull's argument table index, ~0u if none */
    uint32_t ret_arg_qwords2;       /* out (object): the hull's argument table size in 64-bit words */
    /* ml1147: GEOMETRY SHADERS through the DXBC backend's mesh emulation, as
     * DXMT's D3D11 layer runs them (d3d11_shader.cpp ShaderVariantGeometry-
     * Vertex / ShaderVariantGeometry). The OBJECT function is the vertex shader
     * compiled against the geometry shader: vertex-buffer table 16, draw
     * arguments 21, index buffer 20, its own tables at 29/30. The MESH function
     * is the geometry shader compiled against the vertex shader, tables 29/30.
     * gs_stage 1: dxil = the vertex shader, gs_bytecode = the geometry shader
     * (object; specialised on tess_index_format too). gs_stage 2: dxil = the
     * geometry shader, gs_bytecode = the vertex shader (mesh). Both are
     * specialised on a list vs strip input topology. */
    uint32_t gs_stage;              /* in: 0 none, 1 object (VS for a GS), 2 mesh (GS) */
    uint32_t gs_strip;              /* in: 1 = the draw's topology is a strip */
    uint64_t gs_bytecode, gs_bytecode_len;   /* in: the other shader of the pair */
    /* DXIL TESSELLATION through the Metal Shader Converter's own emulation
     * (IRRuntimeNewGeometryTessellationEmulationPipeline). A DXIL hull or
     * domain shader converted with gs_emulation = 1 reports what the pipeline
     * (IRRuntimeTessellationPipelineConfig) and the draws need, from
     * IRShaderReflectionCopyHullInfo / CopyDomainInfo. 0 = not reported. */
    uint32_t ret_hs_patches_per_tg;     /* out (hull): max_patches_per_object_threadgroup */
    uint32_t ret_hs_threads_per_patch;  /* out (hull): max_object_threads_per_patch */
    uint32_t ret_hs_input_cps;          /* out (hull): input_control_point_count */
    uint32_t ret_hs_output_cps;         /* out (hull): output_control_point_count */
    uint32_t ret_hs_output_cp_size;     /* out (hull): output_control_point_size */
    uint32_t ret_hs_patch_const_size;   /* out (hull): patch_constants_size */
    uint32_t ret_hs_out_prim;           /* out (hull): IRTessellatorOutputPrimitive */
    uint32_t ret_hs_max_factor_bits;    /* out (hull): max_tessellation_factor, float bits */
    uint32_t ret_ds_prims_per_mesh_tg;  /* out (domain): max_input_prims_per_mesh_threadgroup */
    uint32_t ret_ds_input_cps;          /* out (domain): input_control_point_count */
    uint32_t ret_ds_input_cp_size;      /* out (domain): input_control_point_size */
    uint32_t ret_ds_patch_const_size;   /* out (domain): patch_constants_size */
};
struct madeira_ir_input_element {
    char semantic[32];
    uint32_t semantic_index, format /* DXGI_FORMAT == IRFormat numbering */, slot, offset, per_instance, step_rate;
    /* ml1011: the same element as a Metal ATTRIBUTE format. Apple's converter
     * takes DXGI numbering; the DXBC backend wants MTLAttributeFormat, which is
     * a different enum entirely. Mapped on the PE side, where the DXGI enum and
     * winemetal's WMTAttributeFormat are both in scope, so the conversion
     * service never has to guess at a format it cannot see. 0 = unmappable. */
    uint32_t attr_format;
    uint32_t reserved_ml1011;
};
struct madeira_ir_input_layout {
    uint32_t n, reserved;
    struct madeira_ir_input_element el[31];
};
struct madeira_ir_loc {
    uint32_t type;              /* IRResourceType: 0 table, 1 constant, 2 cbv, 3 srv, 4 uav, 5 sampler */
    uint32_t space, slot;       /* DXIL space / register */
    uint32_t offset;            /* byte offset in the top-level argument buffer */
    uint64_t size;              /* entry size in bytes */
};
/* ml861: a static sampler, field for field the D3D12 description. The
 * converter's enums carry the D3D12 numbering, so every value passes through
 * unchanged and is baked into the shader as a constant sampler. */
struct madeira_ir_static_sampler {
    uint32_t filter, address_u, address_v, address_w;
    float mip_lod_bias;
    uint32_t max_anisotropy, comparison, border_color;
    float min_lod, max_lod;
    uint32_t shader_register, register_space, visibility;
    uint32_t reserved;
};
struct madeira_ir_vs_input {
    char name[60];              /* the converter's name for the input */
    uint32_t attribute;         /* Metal vertex attribute index */
};

#endif /* MADEIRA_IR_ABI_H */
