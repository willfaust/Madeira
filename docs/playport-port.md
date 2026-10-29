# Playport kosmickrisp port

Source: [Playport 412de5f](https://github.com/playportdev/playport/tree/412de5f8c0bdd26d84e0127eb5776ba992e3b152). Original source headers and license notices are retained. Playport's Madeira Converter Exception covers the imported app code. This work has no dependency on the upcoming BCD port.

Adds an opt-in build profile for the Playport KosmicKrisp improvements: geometry shaders, line/point fill, transform feedback, texel-buffer alignment, shader-key fixes, driver caches, texture compression and required iOS presentation fixes.

Playport's first 19 Mesa patches need Mesa b39d173ca9369c19fda2635be6655d308067e52d (26.3.0-devel). They do not apply unchanged to Madeira's release source. The new profile fetches that exact archive, checks SHA256, and uses a separate build directory. The existing release build route keeps its six patches and cache defaults. The app sets a bounded cache location when no override exists. This PR changes source/build routing, not the shipped driver binary.

Validation: all 19 patches applied to the pinned pristine source. The host routing test passed for the existing six-patch route and experimental 19-patch route, including hash mismatch refusal and preservation of unknown user directories. Shell syntax, Python compilation, diff checks outside the original patch payloads and the production app Swift typecheck passed.

Draft: the Mesa shader toolchain and physical GPU tests were not run. Before promotion, build the experimental driver and test geometry/transform feedback, cold/warm caches and background/resume on a supported device. This does not change the default renderer or native D3D12 path, and is separate from the BCD port.
