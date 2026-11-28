/* madeira-duo xess-metalfx: MetalFX temporal upscaling recorded into a D3D12
 * command list. Shared by madeira_d3d12.dll (the exports) and Madeira's
 * libxess.dll, which answers a game's XeSS calls with it.
 *
 * MadeiraD3D12TemporalUpscale records one MetalFX temporal scale into the list,
 * in list order: when the list is replayed, the scaler reads color, depth and
 * motion (and the optional 1x1 exposure texture) and writes output, then the
 * replay goes on. Units are MetalFX's: jitter in input pixels, motion vectors
 * multiplied by motion_scale_* to give input pixels. */
#ifndef MADEIRA_FX_H
#define MADEIRA_FX_H

#include <d3d12.h>

#define MADEIRA_TU_RESET           0x1u   /* drop the history (camera cut, first frame) */
#define MADEIRA_TU_DEPTH_REVERSED  0x2u   /* 1.0 is near */
#define MADEIRA_TU_AUTO_EXPOSURE   0x4u   /* MetalFX computes the exposure itself */

struct madeira_temporal_upscale_args {
    UINT32 size;                       /* sizeof(struct madeira_temporal_upscale_args) */
    UINT32 flags;                      /* MADEIRA_TU_* */
    ID3D12Resource *color;             /* jittered input color */
    ID3D12Resource *depth;             /* input depth, same size as color */
    ID3D12Resource *motion;            /* motion vectors, same size as color */
    ID3D12Resource *exposure;          /* optional 1x1 exposure texture, or NULL */
    ID3D12Resource *output;            /* the upscaled image */
    UINT32 input_width, input_height;  /* the part of color that holds the frame (from 0,0) */
    float jitter_x, jitter_y;
    float motion_scale_x, motion_scale_y;
    float pre_exposure;                /* 0 or 1 = none */
};

typedef BOOL (WINAPI *PFN_MadeiraD3D12TemporalUpscaleSupported)(ID3D12Device *device);
typedef HRESULT (WINAPI *PFN_MadeiraD3D12TemporalUpscale)(ID3D12GraphicsCommandList *list,
                                                          const struct madeira_temporal_upscale_args *args);

#endif
