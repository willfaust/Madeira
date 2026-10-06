# x86_64-opengl

Desktop OpenGL for x64 games: OpenGL → D3D12 (Mesa) → madeira_d3d12 → Metal.

`build/mesa-d3d12/build.sh` writes these files here. They are not tracked:

| File | What it is | Licence |
|---|---|---|
| `opengl32.dll`, `libgallium_wgl.dll` | Mesa 26.2.4, Windows x64 D3D12 driver, built from pinned source with `build/mesa-d3d12/patches/` | MIT (`LICENSES/MIT-Mesa.txt`) |
| `dxil.dll` | Microsoft's DXIL validator from DirectXShaderCompiler v1.9.2609, unmodified | Microsoft (`LICENSE-dxil.txt`, written here by the script) |

At session start `WineProcessBridge.m` links each `*.dll` here into `system32`
over Wine's builtin `opengl32.dll`, a stub whose every call fails.
`env.MADEIRA_OPENGL = 0` keeps the builtin.
If this folder is empty, nothing changes.
