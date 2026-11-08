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
| `0002-d3d11-video-device-fallback.patch` | `env.MADEIRA_MF_CPU_VIDEO = 1` opts into CPU-backed Media Foundation video. DXMT declines devices explicitly requested with `VIDEO_SUPPORT`, and Wine defaults to the 64-bit parser and ARGB32 video. Ordinary rendering devices still work. `MADEIRA_D3D11_NO_VIDEO_DEVICE`, `MADEIRA_WG_64BIT` and `MADEIRA_WG_VIDEO_FORMAT` override the individual defaults. |

A patch must apply on the current `dxmt` pin. When the pin moves, rebase the
patches onto it (or drop a patch the new pin already covers).
