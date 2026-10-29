# Experimental Playport KosmicKrisp profile

These are the Playport authors' Mesa patches 0001 through 0019 from
playportdev/playport@412de5f8c0bdd26d84e0127eb5776ba992e3b152.
The accidental `kk_shader.c.bak` diff in 0006 is omitted. Other patch contents
and authorship are preserved. See Playport's docs/LICENSING.md for its Mesa terms.

The required upstream Mesa commit is b39d173ca9369c19fda2635be6655d308067e52d
(26.3.0-devel). These patches do not apply unchanged to Madeira's Mesa 26.2.4.
`build/mesa-ios/build-playport-kosmickrisp.sh` selects this source and series.
The existing `build-kosmickrisp.sh` route still builds the release source by default.

The profile adds geometry shaders, line/point fill, transform feedback, texel-buffer
alignment, shader-key fixes, driver caches, texture-compression changes and the
iOS presentation fixes those depend on. It does not replace Madeira's native
Direct3D 12 path, import BCD code, or change the default rendering choice.

Validation must distinguish patch application and host compilation from iPhone GPU
execution. Before promoting this profile, run geometry/transform-feedback draws,
both cold and warm shader-cache launches, and background/resume on a supported device.
