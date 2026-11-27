# Madeira's DXMT patches

Changes to DXMT (the `dxmt` submodule) that live in this repository until
they are in DXMT's own repository. `apply.sh` applies them, in file-name
order, to the `dxmt` working tree before `build/dxmt-ios/build.sh` (the
native Direct3D 9 frontend in `libdxmt_combined.a`),
`build/wine-i386/build.sh` (the 32-bit DLLs) and
`build/windows-runtime/build.sh` (the 64-bit DLLs) build DXMT; it skips a
patch that is already applied, and `apply.sh --revert` takes them out. The
`dxmt` submodule pin does not change.

| Patch | What it fixes |
|---|---|
| `0001-d3d9-index-range-per-draw.patch` | A 32-bit Direct3D 9 indexed draw copies only the index bytes it reads, instead of the whole index buffer before every draw after a lock (Call of Duty: Black Ops drew at 2 to 20 FPS). `env.MADEIRA_D3D9_INDEX_RANGE = 0` goes back to the whole copy. Checked by `tests/host/check-d3d9-index-range.py` |
| `0002-winemetal-ir-unix-wcp-override.patch` | `_madeira_ir_convert` resolves `libmadeira_ir_unix.dylib` from an enabled native `.wcp` via `madeira_wcp_dylib_path` before falling back to the statically linked `madeira_ir_convert`, so D3D12 shader-converter fixes ship without an app rebuild. Checked by `tests/host/check-wcp-native-overrides.py` |
| `0003-air-tessellation-metal-atomics-guard.patch` | `get_next_index` passes `__METAL_MEMORY_FLAGS_NONE__` to `__metal_atomic_fetch_add_explicit` when the Metal SDK defines it, so the tessellation mesh shader compiles on newer SDKs. Checked by `tests/host/check-patch-stacks.py` |

The whole stack equals the dxmt working tree this repository carries: nothing
ships in the tree with no patch and no patch is forgotten in the tree. Checked
by `tests/host/check-patch-stacks.py`.

A patch must apply on the current `dxmt` pin. When the pin moves, rebase the
patches onto it (or drop a patch the new pin already covers).
