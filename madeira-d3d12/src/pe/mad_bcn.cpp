/* ml1310: DXMT's BCn block decoders (dxmt/src/dxmt/dxmt_bcn.hpp + dxmt_bcn.cpp),
 * reached from the C runtime. On a GPU without BC sampling (the iPad's A16:
 * supportsBCTextureCompression = NO) winemetal creates every BC texture with an
 * uncompressed format (remap_unsupported_bc), so an upload must carry decoded
 * texels, exactly as DXMT's D3D11 layer does (dxmt_resource_initializer.cpp). */
#include <cstddef>
#include <cstdint>
#include "dxmt_bcn.hpp"

extern "C" void mad_bcn_decode_image(const uint8_t *src, size_t src_pitch, uint8_t *dst, size_t dst_pitch,
                                     uint32_t width, uint32_t height, int kind) {
  dxmt::bcn_decode_image(src, src_pitch, dst, dst_pitch, width, height, kind);
}

extern "C" uint32_t mad_bcn_texel_size(int kind) { return dxmt::bcn_texel_size(kind); }
