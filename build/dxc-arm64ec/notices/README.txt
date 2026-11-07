dxcompiler.dll (Madeira native DXC, ARM64EC)

- DirectX Shader Compiler 1.8.2407 (microsoft/DirectXShaderCompiler, tag
  v1.8.2407, commit 416fab6b), University of Illinois/NCSA Open Source
  License: DirectXShaderCompiler-LICENSE.TXT. Includes LLVM/Clang 3.7 under
  the same licence.
- MinGW build changes based on raedrizqie's patch set
  (microsoft/DirectXShaderCompiler pull request 8265), contributed under the
  project's licence.
- tools/clang/tools/dxcompiler/MachSiegbertVogtDXCSA.{cpp,h} from
  hexops/DirectXShaderCompiler (commit 4190bb0c9), Apache-2.0 or MIT at the
  user's choice; MIT chosen: hexops-mach-LICENSE-MIT.
- Linked statically with llvm-mingw's libc++/libunwind (Apache-2.0 WITH
  LLVM-exception) and mingw-w64 runtime libraries.

Patches: build/dxc-arm64ec/patches/. Build: build/dxc-arm64ec/build.sh.
