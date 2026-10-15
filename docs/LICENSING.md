# Madeira licensing: the assembled iOS app (working document of 2026-09-16, updated 2026-09-24; not legal advice)

This is a working document by the Madeira author, not legal advice. It
records what the shipped app contains, under which terms, and which
obligations follow. It must be reviewed by an open-source licensing lawyer
before any public release.

## What one built app contains

Statically linked into the main executable (`Madeira` / `Madeira.debug.dylib`):

| Component | Upstream licence | Madeira changes | Notes |
|---|---|---|---|
| Wine unix side (ntdll, wineserver, win32u, wineios.drv) from the `wine` fork (branch `madeira-lgpl`) and `build/*-unix` | LGPL-2.1-or-later | LGPL-2.1-or-later (rebuilt from upstream wine-11.4, see `docs/wine-lgpl-provenance.md`); the earlier GPL-converted branch is retired | statically linked |
| FEXCore and helpers (`FEX/build-ios/*.a`), including the rpmalloc fork under FEX/External | MIT (rpmalloc: 0BSD) | GPL-3.0-or-later + additional permission (Will Faust commits; Ryan Houdek rpmalloc commits stay 0BSD) | statically linked |
| DXMT unix side + airconv (`libdxmt_combined.a`) | MIT | GPL-3.0-or-later + additional permission | statically linked |
| LLVM (inside `libdxmt_combined.a`) | Apache-2.0 with LLVM exception | none | statically linked |
| gnutls 3.8.9, nettle 3.10.1, hogweed 3.10.1, gmp 6.3.0 | LGPL-2.1+ / dual LGPL-3+ or GPL-2+ / dual LGPL-3+ or GPL-2+ | none; Madeira elects LGPL-3.0-or-later for the dual-licensed three | statically linked; LGPL obligations apply; sources tracked in build/gnutls-ios/src |
| FFmpeg 7.1.1 (libavformat, libavcodec, libavutil, libswresample) | LGPL-2.1-or-later (built `--disable-gpl --disable-nonfree --disable-version3`) | none | statically linked, winegstreamer's unix side only; LGPL obligations apply; the unmodified release tarball is tracked in `build/ffmpeg/src` with its SHA-256 and built by `build/ffmpeg/build.sh` |
| Madeira app (Swift/ObjC), native D3D12 runtime (`madeira_d3d12.dll`, PE) | GPL-3.0-or-later + additional permission | author-owned | |
| Steam sign-in, owned library and downloads (`app/Madeira/SwiftSteam/`) | derived from Jfishin's Madeira Steam client | GPL-3.0-or-later + additional permission, Copyright 2026 Jfishin, 125hz | Jfishin's permission: Madeira Discord server, 2026-09-22 ("do whatever you want with it"), seen by Will Faust in that server; he also confirmed that he wrote the depot downloader himself; per-file audit in `docs/STEAM_SIGNIN.md` and `docs/STEAM_LIBRARY.md` |
| Zstandard educational decoder (`app/Madeira/SwiftSteam/zstd_edu.c`) | BSD-3-Clause or GPL-2.0 (Meta Platforms) | BSD-3-Clause selected; wrapper by Jfishin | licence text in `LICENSES/ZSTD-BSD.txt` |

Dynamically loaded at runtime (dlopen; this is NOT a GPL-compatibility
exemption, the combination is still a combined work, see the GNU FAQ on
plugins):

| Component | Licence | Notes |
|---|---|---|
| `libmetalirconverter.dylib` (Apple Metal Shader Converter) | Apple proprietary; agreement s.2.B permits distribution solely for shader conversion; tracked in the repository (decision 2026-09-16) with the agreement and NOTICE beside it | loaded with dlopen by the DXMT/Madeira unix side; used only to convert DXIL to Metal libraries |
| Apple system frameworks (Metal, Foundation, UIKit, VideoToolbox, CoreMedia, CoreVideo, AudioToolbox, ...) | Apple OS components | GPL-3 "System Library" |
| `gl/libOSMesa.dylib`: Mesa 25.0.7 OSMesa + Zink + softpipe (desktop OpenGL backend) | MIT and other permissive licences (`licenses/Mesa-license.rst`) | built by `build/mesa-ios/build.sh`; Madeira's patches to Mesa (`build/mesa-ios/patches`) are offered under MIT |
| `gl/libMoltenVK.dylib`: MoltenVK 1.4.2, containing SPIRV-Cross, SPIRV-Tools, cereal | Apache-2.0 (cereal BSD-3-Clause); texts in `licenses/` | built by `build/moltenvk-ios/build.sh`, unmodified; Apache-2.0 is compatible with GPL-3.0 |
| PE DLLs in `arm64ec-windows/` (Wine builtins, FEX `libarm64ecfex.dll`, `d3d12.dll`, `winemetal.dll`) | as their sources above | separate files in the bundle; `opengl32.dll` is built with `patches/wine-opengl-winios.patch` applied |
| `arm64ec-windows/dockhost.exe` (Madeira Dock, when built) | GPL-3.0-or-later + additional permission, Copyright 2026 125hz; statically linked LLVM/MinGW-w64 runtime under their own notices | separate program run inside Wine; built from the `madeira-dock` submodule by `build/madeira-dock/build.sh`, which also writes `dock-notices.txt` beside it; not committed as a binary |

## Obligations that follow

1. **GPL-3.0 code combined with the proprietary converter.** Allowed only
   where the copyright holder grants an additional permission. Granted
   for author-owned code in `LICENSE-EXCEPTION.md` (adopted 2026-09-24,
   before the first public push). NOT grantable for upstream
   Wine code in the GPL-converted fork; hence the LGPL branch.
2. **LGPL components statically linked (Wine on the LGPL branch, gnutls,
   nettle, hogweed, gmp, FFmpeg).** LGPL-2.1 s.6 / LGPL-3 s.4 require, for the
   combined work: prominent notice that the library is used and covered by
   the LGPL; a copy of the LGPL; the complete corresponding source of the
   library and the means to relink the application with a modified library
   (source of the app can suffice ONLY if a recipient can actually rebuild,
   re-sign and install it; UNVERIFIED: this needs a clean-machine test
   covering dependencies, the converter fetch, free-Apple-ID signing,
   entitlements and installation, and its result recorded here. For the
   LGPL-3 components (nettle, hogweed, gmp if elected under LGPL-3),
   LGPL-3 s.4(e) requires "Installation Information" only under the
   conditions of GPL-3 s.6, i.e. when the combined work is conveyed in or
   with a User Product and installation in that product is otherwise
   possible; whether a sideloaded iOS app meets those conditions is a
   question for the legal review, not assumed either way here. The
   LGPL-2.1 s.6 relink requirement applies to Wine, gnutls and FFmpeg; object
   files of the app are the alternative to source); and permission to
   reverse engineer the combination for debugging modifications.
   Madeira's licence must not restrict that.
3. **Apple agreement s.2.D**: the converter may not be used on non-Apple
   devices or offered as a service. Madeira runs only on Apple devices.
4. **Notices**: keep upstream copyright and licence notices in every fork;
   ship `app/Madeira/d3d12/NOTICE.txt`, the Apple agreement text, the
   Apache text for the headers, `COPYING`, `LICENSE-EXCEPTION.md`.

## Open items before public release

- DONE 2026-09-16: the LGPL Wine branch `madeira-lgpl` is adopted (the wine
  submodule points at it; code-identical to the GPL branch apart from
  licence notices, checked by diff).
- Confirm every downstream Wine patch is author-owned (git authorship is
  evidence, not proof); note any patch adapted from third-party code.
- DONE 2026-09-16: election recorded in `app/Madeira/licenses/THIRD-PARTY-NOTICES.txt`:
  GnuTLS 3.8.9 LGPL-2.1-or-later; Nettle/Hogweed 3.10.1 and GMP 6.3.0 taken
  under LGPL-3.0-or-later. Their source tarballs and SHA-256 sums are
  tracked in `build/gnutls-ios/src`. The licence texts ship in the bundle.
- Steam sign-in: Jfishin's permission is a chat message, not a written
  licence. A public confirmation from him (for example a comment on the pull
  request that adds `app/Madeira/SwiftSteam/`) would make it verifiable by
  anyone; see `docs/STEAM_SIGNIN.md`.
- Clean-machine rebuild/relink/install test (see obligation 2): a fresh
  recursive clone was tried 2026-09-16 and does NOT build unaided; the
  missing inputs and the reconstructed recipes are in `docs/BUILDING.md`.
  Still open: re-executing every UNVERIFIED step there from scratch, then
  signing and installing.
- DONE 2026-09-16: the bundle carries `licenses/` (GPL-3.0, the
  exception, LGPL-2.1, LGPL-3.0, MIT, 0BSD, LLVM texts and
  THIRD-PARTY-NOTICES.txt); `build/stage-licenses.sh` refreshes the two
  generated copies and the Xcode build fails if they are stale.
- Lawyer review of this arrangement.
