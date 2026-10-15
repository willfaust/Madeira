# gl/ — desktop OpenGL backend (not tracked)

Filled by the build scripts; the binaries are git-ignored:

- `build/moltenvk-ios/build.sh` -> `libMoltenVK.dylib` (MoltenVK, Vulkan on Metal)
- `build/mesa-ios/build.sh` -> `libOSMesa.dylib` (Mesa OSMesa + Zink)
- `build/mesa-ios/build-kosmickrisp.sh` -> `libvulkan_kosmickrisp.dylib` (Mesa KosmicKrisp, Vulkan on Metal 4; optional second Vulkan driver, docs/KOSMICKRISP.md)

Without them the app still builds and runs; the GL driver
(`build/win32u-unix/opengl_ios.c`) uses its OpenGL ES backend instead.
The Xcode build phase signs whatever dylibs are here.
