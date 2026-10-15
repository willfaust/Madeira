# DXVK patches

Applied in numeric order by `build/dxvk/build.sh` (`patch -p1`) to upstream DXVK
`v3.1.1` (`b1a1c99ab52b687cf950d62c88bc2fa316b41663`). Madeira's own (2026-10-13), zlib
licence like DXVK. Devices that have the features below take DXVK's upstream paths
unchanged; the patch only matters on a driver that lacks them.

| Patch | Summary |
|---|---|
| 0001-vulkan-on-metal-optional-features.patch | geometryShader, fillModeNonSolid, shaderCullDistance and VK_EXT_depth_clip_enable become optional (upstream refuses the device: "Device does not support required feature ..."). One `warn: Madeira: no ...` line per missing feature; D3D11 geometry shaders are not bound on a device without them; wireframe draws solid; depth clip is expressed through depthClampEnable in pipelines and pipeline libraries |

Why: DXVK 3.1.1's hard requirements (`src/dxvk/dxvk_device_info.cpp`, the
`ENABLE_*(..., true)` rows of the feature table, checked by
`DxvkDeviceCapabilities::checkDeviceCompatibility`) against the two Vulkan-on-Metal
drivers Madeira bundles:

- KosmicKrisp (Mesa 26.2.4, `src/kosmickrisp/vulkan/kk_physical_device.c`) has every
  other required feature and extension, Vulkan 1.4 and 256 bytes of push constants, but
  no `geometryShader`, no `fillModeNonSolid` and no `VK_EXT_depth_clip_enable` (it has
  `VK_EXT_depth_clip_control` only). Unpatched, DXVK skips it with "Device does not
  support required feature 'fillModeNonSolid'" (the first missing row in table order).
- MoltenVK 1.4.2 has no geometry shaders, no cull distances and no
  `VK_EXT_depth_clip_enable` (the extension name is absent from the bundled dylib; it
  does name `VK_EXT_robustness2`, `VK_KHR_maintenance5/6` and
  `VK_KHR_load_store_op_none`). Whether its feature bits satisfy every other row is not
  verified here (no MoltenVK source on this PC): the DXVK log names the first missing one.

Not patched (already optional upstream): transform feedback (neither driver has it:
`CreateGeometryShaderWithStreamOutput` returns DXGI_ERROR_INVALID_CALL), custom border
colours, graphics pipeline libraries, extended dynamic state 3. DXVK queries no
layered-API properties and has no texel-buffer alignment requirement, so the
vkd3d-proton patches 0001/0002 (build/vkd3d-proton/patches) have no DXVK counterpart.
