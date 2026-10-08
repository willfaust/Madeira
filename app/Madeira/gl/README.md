# gl/ — desktop OpenGL backend (not tracked)

Filled by the build scripts; the binaries are git-ignored:

- `build/moltenvk-ios/build.sh` -> `libMoltenVK.dylib` (MoltenVK, Vulkan on Metal)
- `build/mesa-ios/build.sh` -> `libOSMesa.dylib` (Mesa OSMesa + Zink)

Without them the app still builds and runs; the GL driver
(`build/win32u-unix/opengl_ios.c`) uses its OpenGL ES backend instead.
The Xcode build phase signs whatever dylibs are here.
