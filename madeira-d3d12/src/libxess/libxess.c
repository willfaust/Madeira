/* madeira-duo xess-metalfx: Madeira's libxess.dll.
 *
 * A Wine builtin that answers a game's XeSS 2.x calls with MetalFX temporal
 * upscaling. The game's own libxess.dll stays untouched on disk; with
 * WINEDLLOVERRIDES libxess=b Wine loads this one instead. The game keeps
 * doing what it does for XeSS -- it renders jittered at the input
 * resolution, hands over color, depth and motion vectors, and gets the
 * upscaled image back in its output texture -- and madeira_d3d12 records a
 * MetalFX temporal scale into the command list (MadeiraD3D12TemporalUpscale,
 * madeira_fx.h).
 *
 * The API is XeSS SDK 2.0's (intel/xess, inc/xess/xess.h and xess_d3d12.h):
 * the structures below repeat its layouts. Every export of Intel's 2.0.2
 * libxess is present, so a game that links against it loads; what MetalFX
 * cannot stand in for (D3D11, Vulkan, debug dumps, Intel driver hooks) answers
 * XESS_RESULT_ERROR_UNSUPPORTED. */
#include <windows.h>
#include <d3d12.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../pe/madeira_fx.h"

typedef enum {
    XESS_RESULT_WARNING_NONEXISTING_FOLDER = 1,
    XESS_RESULT_WARNING_OLD_DRIVER = 2,
    XESS_RESULT_SUCCESS = 0,
    XESS_RESULT_ERROR_UNSUPPORTED_DEVICE = -1,
    XESS_RESULT_ERROR_UNSUPPORTED_DRIVER = -2,
    XESS_RESULT_ERROR_UNINITIALIZED = -3,
    XESS_RESULT_ERROR_INVALID_ARGUMENT = -4,
    XESS_RESULT_ERROR_DEVICE_OUT_OF_MEMORY = -5,
    XESS_RESULT_ERROR_DEVICE = -6,
    XESS_RESULT_ERROR_NOT_IMPLEMENTED = -7,
    XESS_RESULT_ERROR_INVALID_CONTEXT = -8,
    XESS_RESULT_ERROR_OPERATION_IN_PROGRESS = -9,
    XESS_RESULT_ERROR_UNSUPPORTED = -10,
    XESS_RESULT_ERROR_CANT_LOAD_LIBRARY = -11,
    XESS_RESULT_ERROR_WRONG_CALL_ORDER = -12,
    XESS_RESULT_ERROR_UNKNOWN = -1000,
} xess_result_t;

typedef enum {
    XESS_QUALITY_SETTING_ULTRA_PERFORMANCE = 100,
    XESS_QUALITY_SETTING_PERFORMANCE = 101,
    XESS_QUALITY_SETTING_BALANCED = 102,
    XESS_QUALITY_SETTING_QUALITY = 103,
    XESS_QUALITY_SETTING_ULTRA_QUALITY = 104,
    XESS_QUALITY_SETTING_ULTRA_QUALITY_PLUS = 105,
    XESS_QUALITY_SETTING_AA = 106,
} xess_quality_settings_t;

enum {
    XESS_INIT_FLAG_HIGH_RES_MV = 1 << 0,
    XESS_INIT_FLAG_INVERTED_DEPTH = 1 << 1,
    XESS_INIT_FLAG_EXPOSURE_SCALE_TEXTURE = 1 << 2,
    XESS_INIT_FLAG_RESPONSIVE_PIXEL_MASK = 1 << 3,
    XESS_INIT_FLAG_USE_NDC_VELOCITY = 1 << 4,
    XESS_INIT_FLAG_EXTERNAL_DESCRIPTOR_HEAP = 1 << 5,
    XESS_INIT_FLAG_LDR_INPUT_COLOR = 1 << 6,
    XESS_INIT_FLAG_JITTERED_MV = 1 << 7,
    XESS_INIT_FLAG_ENABLE_AUTOEXPOSURE = 1 << 8,
};

typedef enum {
    XESS_LOGGING_LEVEL_DEBUG = 0,
    XESS_LOGGING_LEVEL_INFO = 1,
    XESS_LOGGING_LEVEL_WARNING = 2,
    XESS_LOGGING_LEVEL_ERROR = 3,
} xess_logging_level_t;

typedef void (*xess_app_log_callback_t)(const char *message, xess_logging_level_t level);

#pragma pack(push, 8)
typedef struct { uint16_t major, minor, patch, reserved; } xess_version_t;
typedef struct { uint32_t x, y; } xess_2d_t;
typedef xess_2d_t xess_coord_t;
typedef struct {
    uint32_t requiredDescriptorCount;
    uint64_t tempBufferHeapSize;
    uint64_t tempTextureHeapSize;
} xess_properties_t;
typedef struct {
    xess_2d_t outputResolution;
    xess_quality_settings_t qualitySetting;
    uint32_t initFlags;
    uint32_t creationNodeMask;
    uint32_t visibleNodeMask;
    ID3D12Heap *pTempBufferHeap;
    uint64_t bufferHeapOffset;
    ID3D12Heap *pTempTextureHeap;
    uint64_t textureHeapOffset;
    ID3D12PipelineLibrary *pPipelineLibrary;
} xess_d3d12_init_params_t;
typedef struct {
    ID3D12Resource *pColorTexture;
    ID3D12Resource *pVelocityTexture;
    ID3D12Resource *pDepthTexture;
    ID3D12Resource *pExposureScaleTexture;
    ID3D12Resource *pResponsivePixelMaskTexture;
    ID3D12Resource *pOutputTexture;
    float jitterOffsetX;
    float jitterOffsetY;
    float exposureScale;
    uint32_t resetHistory;
    uint32_t inputWidth;
    uint32_t inputHeight;
    xess_coord_t inputColorBase;
    xess_coord_t inputMotionVectorBase;
    xess_coord_t inputDepthBase;
    xess_coord_t inputResponsiveMaskBase;
    xess_coord_t reserved0;
    xess_coord_t outputColorBase;
    ID3D12DescriptorHeap *pDescriptorHeap;
    uint32_t descriptorHeapOffset;
} xess_d3d12_execute_params_t;
#pragma pack(pop)

#define CTX_MAGIC 0x4d465843u   /* "CXFM" */
struct xess_ctx {
    uint32_t magic;
    ID3D12Device *device;
    xess_d3d12_init_params_t init;
    int initialized;
    int legacy_ratios;
    float jitter_scale[2], velocity_scale[2];
    float exposure_multiplier, max_responsive_mask;
    xess_app_log_callback_t log_cb;
    xess_logging_level_t log_level;
    LONG executes, refused;
};
typedef struct xess_ctx *xess_context_handle_t;

#define XESS_EXPORT __declspec(dllexport)

/* ---- logging: the same path as madeira_d3d12's d3d12_log ---- */
static void xlog(const char *fmt, ...) {
    typedef int (__cdecl *dbg_output_fn)(const char *);
    static dbg_output_fn dbg_output;
    static int looked;
    char buf[900];
    size_t len;
    va_list ap;
    memcpy(buf, "[xess-metalfx] ", 15);
    va_start(ap, fmt);
    vsnprintf(buf + 15, sizeof buf - 17, fmt, ap);
    va_end(ap);
    len = strlen(buf);
    if (!len || buf[len - 1] != '\n') { buf[len] = '\n'; buf[len + 1] = 0; }
    if (!looked) {
        HMODULE nt = GetModuleHandleA("ntdll.dll");
        if (nt) dbg_output = (dbg_output_fn)GetProcAddress(nt, "__wine_dbg_output");
        looked = 1;
    }
    if (dbg_output) dbg_output(buf);
}

/* ---- madeira_d3d12's exports ---- */
static PFN_MadeiraD3D12TemporalUpscaleSupported p_supported;
static PFN_MadeiraD3D12TemporalUpscale p_upscale;
static int bridge_ready(void) {
    static int state;   /* 0 not looked, 1 found, -1 missing */
    if (!state) {
        const char *names[] = { "d3d12.dll", "madeira_d3d12.dll" };
        unsigned i;
        for (i = 0; i < 2 && !p_upscale; i++) {
            HMODULE m = GetModuleHandleA(names[i]);
            if (!m) continue;
            p_supported = (PFN_MadeiraD3D12TemporalUpscaleSupported)GetProcAddress(m, "MadeiraD3D12TemporalUpscaleSupported");
            p_upscale = (PFN_MadeiraD3D12TemporalUpscale)GetProcAddress(m, "MadeiraD3D12TemporalUpscale");
        }
        state = p_supported && p_upscale ? 1 : -1;
        xlog("Madeira libxess (XeSS 2.0 API over MetalFX temporal): madeira_d3d12 bridge %s",
             state > 0 ? "found" : "MISSING -- XeSS reports an unsupported device");
    }
    return state > 0;
}

static struct xess_ctx *ctx_of(xess_context_handle_t h) {
    return h && h->magic == CTX_MAGIC ? h : NULL;
}

/* Output/input ratio per quality setting: XeSS 1.3+ ratios, or the 1.2 ones
 * after xessForceLegacyScaleFactors. MetalFX is created for up to 3x. */
static float quality_ratio(xess_quality_settings_t q, int legacy) {
    switch (q) {
    case XESS_QUALITY_SETTING_ULTRA_PERFORMANCE: return 3.0f;
    case XESS_QUALITY_SETTING_PERFORMANCE: return legacy ? 2.0f : 2.3f;
    case XESS_QUALITY_SETTING_BALANCED: return legacy ? 1.7f : 2.0f;
    case XESS_QUALITY_SETTING_QUALITY: return legacy ? 1.5f : 1.7f;
    case XESS_QUALITY_SETTING_ULTRA_QUALITY: return legacy ? 1.3f : 1.5f;
    case XESS_QUALITY_SETTING_ULTRA_QUALITY_PLUS: return 1.3f;
    case XESS_QUALITY_SETTING_AA: return 1.0f;
    default: return 0.0f;
    }
}
static uint32_t scaled(uint32_t out, float ratio) {
    uint32_t v = (uint32_t)((float)out / ratio + 0.5f);
    return v ? v : 1;
}

/* ---- the XeSS API ---- */
XESS_EXPORT xess_result_t xessGetVersion(xess_version_t *v) {
    if (!v) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    v->major = 2; v->minor = 0; v->patch = 2; v->reserved = 0;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessGetIntelXeFXVersion(xess_context_handle_t h, xess_version_t *v) {
    if (!ctx_of(h)) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    if (!v) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    memset(v, 0, sizeof *v);   /* no XeFX: not an Intel GPU */
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessD3D12CreateContext(ID3D12Device *device, xess_context_handle_t *out) {
    struct xess_ctx *c;
    if (!device || !out) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    *out = NULL;
    if (!bridge_ready() || !p_supported(device)) {
        xlog("xessD3D12CreateContext: %s", p_supported ? "this GPU has no MetalFX temporal scaler" : "no madeira_d3d12 bridge");
        return XESS_RESULT_ERROR_UNSUPPORTED_DEVICE;
    }
    c = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof *c);
    if (!c) return XESS_RESULT_ERROR_DEVICE_OUT_OF_MEMORY;
    c->magic = CTX_MAGIC;
    c->device = device;
    device->lpVtbl->AddRef(device);
    c->jitter_scale[0] = c->jitter_scale[1] = 1.0f;
    c->velocity_scale[0] = c->velocity_scale[1] = 1.0f;
    c->exposure_multiplier = 1.0f;
    c->max_responsive_mask = 1.0f;
    *out = c;
    xlog("xessD3D12CreateContext: context %p", (void *)c);
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessD3D12BuildPipelines(xess_context_handle_t h, ID3D12PipelineLibrary *lib, bool blocking, uint32_t flags) {
    (void)lib; (void)blocking; (void)flags;
    return ctx_of(h) ? XESS_RESULT_SUCCESS : XESS_RESULT_ERROR_INVALID_CONTEXT;
}
XESS_EXPORT xess_result_t xessGetPipelineBuildStatus(xess_context_handle_t h) {
    return ctx_of(h) ? XESS_RESULT_SUCCESS : XESS_RESULT_ERROR_INVALID_CONTEXT;
}
XESS_EXPORT xess_result_t xessD3D12Init(xess_context_handle_t h, const xess_d3d12_init_params_t *p) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    if (!p || !p->outputResolution.x || !p->outputResolution.y || !quality_ratio(p->qualitySetting, 0))
        return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    c->init = *p;
    c->initialized = 1;
    xlog("xessD3D12Init: output %ux%u, quality %d, flags %#x%s%s%s%s%s%s", p->outputResolution.x, p->outputResolution.y,
         (int)p->qualitySetting, p->initFlags,
         (p->initFlags & XESS_INIT_FLAG_HIGH_RES_MV) ? " HIGH_RES_MV(unsupported)" : "",
         (p->initFlags & XESS_INIT_FLAG_INVERTED_DEPTH) ? " INVERTED_DEPTH" : "",
         (p->initFlags & XESS_INIT_FLAG_EXPOSURE_SCALE_TEXTURE) ? " EXPOSURE_TEXTURE" : "",
         (p->initFlags & XESS_INIT_FLAG_USE_NDC_VELOCITY) ? " NDC_VELOCITY" : "",
         (p->initFlags & XESS_INIT_FLAG_LDR_INPUT_COLOR) ? " LDR" : "",
         (p->initFlags & XESS_INIT_FLAG_ENABLE_AUTOEXPOSURE) ? " AUTOEXPOSURE" : "");
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessD3D12GetInitParams(xess_context_handle_t h, xess_d3d12_init_params_t *p) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    if (!p) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    if (!c->initialized) return XESS_RESULT_ERROR_UNINITIALIZED;
    *p = c->init;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessGetProperties(xess_context_handle_t h, const xess_2d_t *out, xess_properties_t *props) {
    (void)out;
    if (!ctx_of(h)) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    if (!props) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    /* MetalFX keeps its own history; small non-zero sizes so a game that
     * creates the heaps it is told about still gets valid ones. */
    props->requiredDescriptorCount = 16;
    props->tempBufferHeapSize = 65536;
    props->tempTextureHeapSize = 65536;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessGetInputResolution(xess_context_handle_t h, const xess_2d_t *out, xess_quality_settings_t q, xess_2d_t *in) {
    struct xess_ctx *c = ctx_of(h);
    float r;
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    if (!out || !in || !(r = quality_ratio(q, c->legacy_ratios))) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    in->x = scaled(out->x, r); in->y = scaled(out->y, r);
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessGetOptimalInputResolution(xess_context_handle_t h, const xess_2d_t *out, xess_quality_settings_t q,
                                                        xess_2d_t *optimal, xess_2d_t *minimum, xess_2d_t *maximum) {
    struct xess_ctx *c = ctx_of(h);
    float r;
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    if (!out || !optimal || !(r = quality_ratio(q, c->legacy_ratios))) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    optimal->x = scaled(out->x, r); optimal->y = scaled(out->y, r);
    if (minimum) { minimum->x = scaled(out->x, 3.0f); minimum->y = scaled(out->y, 3.0f); }
    if (maximum) *maximum = *out;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessGetJitterScale(xess_context_handle_t h, float *x, float *y) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    if (!x || !y) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    *x = c->jitter_scale[0]; *y = c->jitter_scale[1];
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessSetJitterScale(xess_context_handle_t h, float x, float y) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    c->jitter_scale[0] = x; c->jitter_scale[1] = y;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessGetVelocityScale(xess_context_handle_t h, float *x, float *y) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    if (!x || !y) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    *x = c->velocity_scale[0]; *y = c->velocity_scale[1];
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessSetVelocityScale(xess_context_handle_t h, float x, float y) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    c->velocity_scale[0] = x; c->velocity_scale[1] = y;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessSetExposureMultiplier(xess_context_handle_t h, float scale) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    c->exposure_multiplier = scale;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessGetExposureMultiplier(xess_context_handle_t h, float *scale) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    if (!scale) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    *scale = c->exposure_multiplier;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessSetMaxResponsiveMaskValue(xess_context_handle_t h, float value) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    c->max_responsive_mask = value;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessGetMaxResponsiveMaskValue(xess_context_handle_t h, float *value) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    if (!value) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    *value = c->max_responsive_mask;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessSetLoggingCallback(xess_context_handle_t h, xess_logging_level_t level, xess_app_log_callback_t cb) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    c->log_level = level; c->log_cb = cb;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessIsOptimalDriver(xess_context_handle_t h) {
    return ctx_of(h) ? XESS_RESULT_SUCCESS : XESS_RESULT_ERROR_INVALID_CONTEXT;
}
XESS_EXPORT xess_result_t xessForceLegacyScaleFactors(xess_context_handle_t h, bool force) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    c->legacy_ratios = force;
    return XESS_RESULT_SUCCESS;
}
XESS_EXPORT xess_result_t xessSelectNetworkModel(xess_context_handle_t h, int model) {
    (void)model;
    return ctx_of(h) ? XESS_RESULT_SUCCESS : XESS_RESULT_ERROR_INVALID_CONTEXT;
}
XESS_EXPORT xess_result_t xessDestroyContext(xess_context_handle_t h) {
    struct xess_ctx *c = ctx_of(h);
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    xlog("xessDestroyContext: context %p after %ld executes (%ld refused)", (void *)c, (long)c->executes, (long)c->refused);
    c->magic = 0;
    if (c->device) c->device->lpVtbl->Release(c->device);
    HeapFree(GetProcessHeap(), 0, c);
    return XESS_RESULT_SUCCESS;
}

XESS_EXPORT xess_result_t xessD3D12Execute(xess_context_handle_t h, ID3D12GraphicsCommandList *list, const xess_d3d12_execute_params_t *p) {
    struct xess_ctx *c = ctx_of(h);
    struct madeira_temporal_upscale_args a;
    uint32_t flags;
    float mvx, mvy;
    HRESULT hr;
    LONG n;
    if (!c) return XESS_RESULT_ERROR_INVALID_CONTEXT;
    if (!c->initialized) return XESS_RESULT_ERROR_UNINITIALIZED;
    if (!list || !p || !p->pColorTexture || !p->pVelocityTexture || !p->pOutputTexture) return XESS_RESULT_ERROR_INVALID_ARGUMENT;
    flags = c->init.initFlags;
    if (!p->pDepthTexture || (flags & XESS_INIT_FLAG_HIGH_RES_MV)) {
        /* MetalFX needs depth, and motion vectors at the input size */
        if (InterlockedIncrement(&c->refused) <= 4)
            xlog("xessD3D12Execute refused: %s", !p->pDepthTexture ? "no depth texture" : "display-resolution motion vectors are not supported yet");
        return XESS_RESULT_ERROR_UNSUPPORTED;
    }
    /* XeSS motion vectors are in input pixels (or NDC with USE_NDC_VELOCITY),
     * multiplied by the velocity scale; MetalFX wants a factor to input pixels. */
    mvx = c->velocity_scale[0]; mvy = c->velocity_scale[1];
    if (flags & XESS_INIT_FLAG_USE_NDC_VELOCITY) {
        mvx *= 0.5f * (float)p->inputWidth;
        mvy *= -0.5f * (float)p->inputHeight;
    }
    memset(&a, 0, sizeof a);
    a.size = sizeof a;
    a.flags = (p->resetHistory ? MADEIRA_TU_RESET : 0) |
              ((flags & XESS_INIT_FLAG_INVERTED_DEPTH) ? MADEIRA_TU_DEPTH_REVERSED : 0) |
              ((flags & XESS_INIT_FLAG_ENABLE_AUTOEXPOSURE) ? MADEIRA_TU_AUTO_EXPOSURE : 0);
    a.color = p->pColorTexture;
    a.depth = p->pDepthTexture;
    a.motion = p->pVelocityTexture;
    a.exposure = (flags & XESS_INIT_FLAG_EXPOSURE_SCALE_TEXTURE) ? p->pExposureScaleTexture : NULL;
    a.output = p->pOutputTexture;
    a.input_width = p->inputWidth;
    a.input_height = p->inputHeight;
    a.jitter_x = p->jitterOffsetX * c->jitter_scale[0];
    a.jitter_y = p->jitterOffsetY * c->jitter_scale[1];
    a.motion_scale_x = mvx;
    a.motion_scale_y = mvy;
    /* exposureScale is logged, not applied: MetalFX's preExposure is a value
     * already multiplied into the color, a different contract. */
    a.pre_exposure = 1.0f;
    hr = p_upscale(list, &a);
    n = InterlockedIncrement(&c->executes);
    if (n <= 4)
        xlog("xessD3D12Execute #%ld: input %ux%u (color base %u,%u, output base %u,%u), jitter %.3f %.3f, velocity scale %.3f %.3f, "
             "exposure %.3f x %.3f, reset %u, responsive mask %s -> %#lx",
             (long)n, p->inputWidth, p->inputHeight, p->inputColorBase.x, p->inputColorBase.y, p->outputColorBase.x, p->outputColorBase.y,
             p->jitterOffsetX, p->jitterOffsetY, c->velocity_scale[0], c->velocity_scale[1], p->exposureScale, c->exposure_multiplier,
             p->resetHistory, p->pResponsivePixelMaskTexture ? "given (ignored)" : "none", (unsigned long)hr);
    else if (FAILED(hr) && InterlockedIncrement(&c->refused) <= 8)
        xlog("xessD3D12Execute #%ld failed: %#lx", (long)n, (unsigned long)hr);
    return SUCCEEDED(hr) ? XESS_RESULT_SUCCESS : XESS_RESULT_ERROR_INVALID_ARGUMENT;
}

/* ---- the rest of Intel's 2.0.2 exports: not available here ---- */
#define UNSUPPORTED(name) XESS_EXPORT xess_result_t name(void) { return XESS_RESULT_ERROR_UNSUPPORTED; }
UNSUPPORTED(xessD3D12GetProfilingData)
UNSUPPORTED(xessD3D12GetResourcesToDump)
UNSUPPORTED(xessGetProfilingData)
UNSUPPORTED(xessStartDump)
UNSUPPORTED(xessGetContextParameterP)
UNSUPPORTED(xessSetContextParameterF)
UNSUPPORTED(xessAILGetDecision)
UNSUPPORTED(xessAILGetVersion)
UNSUPPORTED(xessVKAILGetDecision)
UNSUPPORTED(xessTrinityCreateContext)
UNSUPPORTED(xessTrinityGetRequiredDeviceExtensions)
UNSUPPORTED(xessTrinityGetRequiredDeviceFeatures)
UNSUPPORTED(xessTrinityGetRequiredInstanceExtensions)
UNSUPPORTED(xessVKBuildPipelines)
UNSUPPORTED(xessVKCreateContext)
UNSUPPORTED(xessVKExecute)
UNSUPPORTED(xessVKGetInitParams)
UNSUPPORTED(xessVKGetRequiredDeviceExtensions)
UNSUPPORTED(xessVKGetRequiredDeviceFeatures)
UNSUPPORTED(xessVKGetRequiredInstanceExtensions)
UNSUPPORTED(xessVKGetResourcesToDump)
UNSUPPORTED(xessVKInit)
UNSUPPORTED(INTC_D3D11_XessCreateContext)
UNSUPPORTED(INTC_D3D11_XessDestroyContext)
UNSUPPORTED(INTC_D3D11_XessExecute)
UNSUPPORTED(INTC_D3D11_XessForceLegacyScaleFactors)
UNSUPPORTED(INTC_D3D11_XessGetExposureMultiplier)
UNSUPPORTED(INTC_D3D11_XessGetInitParams)
UNSUPPORTED(INTC_D3D11_XessGetInputResolution)
UNSUPPORTED(INTC_D3D11_XessGetIntelXeFXVersion)
UNSUPPORTED(INTC_D3D11_XessGetJitterScale)
UNSUPPORTED(INTC_D3D11_XessGetOptimalInputResolution)
UNSUPPORTED(INTC_D3D11_XessGetProfilingData)
UNSUPPORTED(INTC_D3D11_XessGetVelocityScale)
UNSUPPORTED(INTC_D3D11_XessGetVersion)
UNSUPPORTED(INTC_D3D11_XessInit)
UNSUPPORTED(INTC_D3D11_XessIsOptimalDriver)
UNSUPPORTED(INTC_D3D11_XessSelectNetworkModel)
UNSUPPORTED(INTC_D3D11_XessSetExposureMultiplier)
UNSUPPORTED(INTC_D3D11_XessSetJitterScale)
UNSUPPORTED(INTC_D3D11_XessSetLoggingCallback)
UNSUPPORTED(INTC_D3D11_XessSetVelocityScale)
UNSUPPORTED(INTC_D3D12_GetApplicationInfo)
UNSUPPORTED(INTC_D3D12_GetGpuCrashDumpBufferInfo)
UNSUPPORTED(INTC_D3D12_GpuCrashDumpOnCommandListCreate)
UNSUPPORTED(INTC_D3D12_GpuCrashDumpOnCommandListDestroy)
UNSUPPORTED(INTC_D3D12_GpuCrashDumpOnDeviceDestroy)
UNSUPPORTED(INTC_D3D12_RegisterDriverCallbacks)

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(inst);
    return TRUE;
}
