/* Host check for bc-footprint (no Windows headers needed): the footprint code is
 * cut out of madeira_d3d12.c by check-bc-footprint.sh and built against the stub types below. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
typedef unsigned int UINT; typedef uint64_t UINT64; typedef uint16_t UINT16;
#define STDMETHODCALLTYPE
typedef int ID3D12Device;
enum { DXGI_FORMAT_UNKNOWN=0, DXGI_FORMAT_R32G32B32A32_TYPELESS=1, DXGI_FORMAT_R32G32B32A32_SINT=4, DXGI_FORMAT_R32G32B32_TYPELESS=5, DXGI_FORMAT_R32G32B32_SINT=8,
 DXGI_FORMAT_R16G16B16A16_TYPELESS=9, DXGI_FORMAT_R32G32_SINT=18, DXGI_FORMAT_R32G8X24_TYPELESS=19, DXGI_FORMAT_X32_TYPELESS_G8X24_UINT=22,
 DXGI_FORMAT_R10G10B10A2_TYPELESS=23, DXGI_FORMAT_X24_TYPELESS_G8_UINT=47, DXGI_FORMAT_R8G8_TYPELESS=48, DXGI_FORMAT_R16_SINT=59,
 DXGI_FORMAT_R8_TYPELESS=60, DXGI_FORMAT_A8_UNORM=65, DXGI_FORMAT_R9G9B9E5_SHAREDEXP=67, DXGI_FORMAT_R8G8_B8G8_UNORM=68, DXGI_FORMAT_G8R8_G8B8_UNORM=69,
 DXGI_FORMAT_BC1_TYPELESS=70, DXGI_FORMAT_BC1_UNORM=71, DXGI_FORMAT_BC1_UNORM_SRGB=72, DXGI_FORMAT_BC2_TYPELESS=73, DXGI_FORMAT_BC3_UNORM_SRGB=78,
 DXGI_FORMAT_BC4_TYPELESS=79, DXGI_FORMAT_BC4_SNORM=81, DXGI_FORMAT_BC5_TYPELESS=82, DXGI_FORMAT_BC5_SNORM=84, DXGI_FORMAT_B5G6R5_UNORM=85, DXGI_FORMAT_B5G5R5A1_UNORM=86,
 DXGI_FORMAT_B8G8R8A8_UNORM=87, DXGI_FORMAT_B8G8R8X8_UNORM_SRGB=93, DXGI_FORMAT_BC6H_TYPELESS=94, DXGI_FORMAT_BC7_UNORM_SRGB=99, DXGI_FORMAT_R8G8B8A8_UNORM=28 };
typedef int DXGI_FORMAT;
enum { D3D12_RESOURCE_DIMENSION_UNKNOWN, D3D12_RESOURCE_DIMENSION_BUFFER, D3D12_RESOURCE_DIMENSION_TEXTURE1D, D3D12_RESOURCE_DIMENSION_TEXTURE2D, D3D12_RESOURCE_DIMENSION_TEXTURE3D };
#define D3D12_TEXTURE_DATA_PITCH_ALIGNMENT 256
#define D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT 512
typedef struct { UINT Count, Quality; } SD;
typedef struct { int Dimension; UINT64 Alignment; UINT64 Width; UINT Height; UINT16 DepthOrArraySize; UINT16 MipLevels; DXGI_FORMAT Format; SD SampleDesc; } D3D12_RESOURCE_DESC;
typedef struct { DXGI_FORMAT Format; UINT Width, Height, Depth, RowPitch; } FP;
typedef struct { UINT64 Offset; FP Footprint; } D3D12_PLACED_SUBRESOURCE_FOOTPRINT;
static int cfg_val = 1;
static int mad_cfg_int_pe(const char *k, int d) { (void)k; (void)d; return cfg_val; }
#define d3d12_log printf
#include "extract.c"
static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)
int main(void) {
    D3D12_RESOURCE_DESC d; memset(&d, 0, sizeof d);
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT L[16]; UINT rows[16]; UINT64 rs[16], total, total_old;
    d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; d.Width = 64; d.Height = 32; d.DepthOrArraySize = 1; d.MipLevels = 7; d.Format = DXGI_FORMAT_BC1_UNORM; d.SampleDesc.Count = 1;
    device_GetCopyableFootprints(NULL, &d, 0, 7, 0, L, rows, rs, &total);
    for (int i = 0; i < 7; i++) {
        printf("BC1 mip%d %ux%u rows=%u rowbytes=%llu pitch=%u off=%llu\n", i, L[i].Footprint.Width, L[i].Footprint.Height, rows[i], (unsigned long long)rs[i], L[i].Footprint.RowPitch, (unsigned long long)L[i].Offset);
        CHECK(L[i].Footprint.Width % 4 == 0); CHECK(L[i].Footprint.Height % 4 == 0);
        CHECK(rows[i] == L[i].Footprint.Height / 4);
        CHECK(rs[i] == (UINT64)(L[i].Footprint.Width / 4) * 8);
    }
    CHECK(L[4].Footprint.Width == 4 && L[4].Footprint.Height == 4); /* 4x2 -> 4x4 */
    CHECK(L[6].Footprint.Width == 4 && L[6].Footprint.Height == 4); /* 1x1 -> 4x4 */
    /* non-multiple top level: 100x60 BC7 -> 100x60 (already), mip1 50x30 -> 52x32 */
    d.Width = 100; d.Height = 60; d.MipLevels = 2; d.Format = DXGI_FORMAT_BC7_UNORM_SRGB;
    device_GetCopyableFootprints(NULL, &d, 0, 2, 0, L, rows, rs, &total);
    CHECK(L[1].Footprint.Width == 52 && L[1].Footprint.Height == 32);
    /* total bytes unchanged vs gate off (rows/rowbytes never depended on rounding) */
    g_bc_fp_align = -1; cfg_val = 0;
    device_GetCopyableFootprints(NULL, &d, 0, 2, 0, L, rows, rs, &total_old);
    CHECK(total == total_old); CHECK(L[1].Footprint.Width == 50 && L[1].Footprint.Height == 30);
    /* uncompressed unaffected */
    g_bc_fp_align = -1; cfg_val = 1;
    d.Format = DXGI_FORMAT_R8G8B8A8_UNORM; d.Width = 3; d.Height = 3; d.MipLevels = 2;
    device_GetCopyableFootprints(NULL, &d, 0, 2, 0, L, rows, rs, &total);
    CHECK(L[0].Footprint.Width == 3 && L[1].Footprint.Width == 1);
    /* buffer unaffected */
    d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; d.Width = 1000; d.Height = 1; d.MipLevels = 1; d.Format = DXGI_FORMAT_UNKNOWN;
    device_GetCopyableFootprints(NULL, &d, 0, 1, 0, L, rows, rs, &total);
    CHECK(L[0].Footprint.Width == 1000);
    /* clip */
    { UINT w = 4, h = 4; mad_bc_clip(4, 2, 2, 0, 0, &w, &h); CHECK(w == 2 && h == 2); }
    { UINT w = 4, h = 4; mad_bc_clip(1, 2, 2, 0, 0, &w, &h); CHECK(w == 4 && h == 4); }
    { UINT w = 8, h = 4; mad_bc_clip(4, 50, 30, 44, 28, &w, &h); CHECK(w == 6 && h == 2); }
    { UINT w = 16, h = 16; mad_bc_clip(4, 64, 64, 0, 0, &w, &h); CHECK(w == 16 && h == 16); }
    printf(fails ? "FAILED %d\n" : "ALL PASS\n", fails);
    return fails != 0;
}
