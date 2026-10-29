# Additional permission for the Apple Metal Shader Converter (GPL-3.0 section 7)

This file attaches an additional permission to Playport's own code. It is in
effect from the adoption line below. While that line carries no date, the
permission is not in effect, and CI (`.github/workflows/checks.yml`) fails
every push. Distribution
begins with the first push to a public remote, not with a release tag, so the
line must be completed before any public push. See "Scope and authority" for
what this permission can and cannot cover.

Adopted on: 2026-09-24
By: The Playport authors

Playport is licensed under the GNU General Public License, version 3 or (at
your option) any later version (see `LICENSE`). The following additional
permission applies to the parts of Playport whose copyright is held by the
Playport authors (see "Scope and authority"). Its text is the Madeira
Converter Exception, version 1, as published by willfaust/Madeira, with only
the name of the Program changed. Playport adopts it for its own code; this
adoption is not Madeira's and does not change Madeira's.

### Madeira Converter Exception, version 1 (of 2026-09-16), as adopted by Playport (in effect from the adoption date above)

Additional permission under GNU GPL version 3 section 7.

If you modify this Program, or any covered work, by linking or combining it
with the Apple Metal Shader Converter dynamic library
(libmetalirconverter.dylib, in any version) or with Apple's Metal,
Foundation, CoreGraphics, QuartzCore, UIKit, AppKit and related system
frameworks, or with modified versions of those libraries, the licensors of
this Program grant you additional permission to convey the resulting work.
Corresponding Source for a non-source form of such a combination shall
include the source code for the parts of the Program used in the
combination, but need not include the source code of those Apple libraries.
This permission does not extend to those libraries, which remain subject to
Apple's own licence terms. You may remove this additional permission from
copies you convey, as GPL-3.0 section 7 allows.

## Scope and authority

An additional permission can be attached only by the copyright holder of
the code it covers. It therefore covers, and only covers, the code whose
copyright the Playport authors hold in this repository:

- the app, the build pipeline and the tools (`app/`, `build/`, `tools/`,
  `pp`), except the third-party material named below;
- the Playport-authored changes carried in `patches/madeira-unix`,
  `patches/madeira-winios`, `patches/fex` and `patches/dxmt`, as far as they
  are Playport's own lines (the code they change keeps its own licence).

It does NOT cover, and nothing here changes:

- Madeira and its FEX, DXMT and rpmalloc forks (`upstream/madeira`,
  Madeira's DXMT port carried in `patches/dxmt-port`, and everything built
  from them). Madeira adopted the same text for its own code on 2026-09-24
  (willfaust/Madeira `LICENSE-EXCEPTION.md`); upstream FEX code is MIT,
  upstream DXMT code (3Shain/dxmt) is LGPL-2.1-or-later and upstream rpmalloc
  is 0BSD, and none of them needs an exception;
- Wine (WineHQ wine-11.18, pinned in `pins.lock`), with Madeira's Wine fork
  carried in `patches/wine-port` and its ported Wine files in the
  `madeira-port` patches at the end of `patches/madeira-unix`, which is
  LGPL-2.1-or-later. The Playport changes in `patches/wine-pe`,
  `patches/wine-unix` and the Wine files of `patches/madeira-unix` are offered
  under LGPL-2.1-or-later, so the Wine tree stays LGPL and needs no exception;
- material Playport takes from others under their licences, such as the
  JavaSteam protocol schemas in `app/SteamClient` (MIT) and the statically
  linked GnuTLS, GMP, Nettle, FreeType and LLVM libraries (`docs/LICENSING.md`);
- the Apple libraries themselves, which are distributed only under Apple's
  own terms. Playport does not build or ship the converter library today;
  this permission keeps that option open without needing the consent of
  later contributors.

Contributions to Playport are accepted under GPL-3.0-or-later with this
permission (`docs/LICENSING.md`). This file is a licensing statement by the
copyright holder, not legal advice; the assembled application must be
reviewed before any public release (see `docs/LICENSING.md`).
