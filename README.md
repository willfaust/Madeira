# Madeira

Run Windows PC games on a non-jailbroken iPhone.

Madeira combines [Wine](https://www.winehq.org/) (Aarch64),
[FEX-Emu](https://github.com/FEX-Emu/FEX) (ARM64EC) for x86-64 → ARM64 translation, and
[DXMT](https://github.com/3Shain/DXMT) for D3D11 → Metal, running as a single
Mach process on iOS with wineserver as a thread rather than a separate process.

## Status

Thumper and ULTRAKILL are playable. Marvel Cosmic Invasion has reached
gameplay, though a run has also ended in an unexplained termination and its
controls are not yet reliable. Others reach gameplay at low frame rates. This
is a research project, not a product: expect rough edges, per-title quirks and
breaking changes.

## Requirements

- A non-jailbroken iPhone. Development has been on an A15 (iPhone 13 Pro).
- JIT, which on iOS requires a debugger to attach —
  [StikDebug](https://github.com/0-Blu/StikJIT) is what this project uses.
- An Apple ID for signing. A free account works; its provisioning profiles
  expire after 7 days, so the app must be rebuilt and reinstalled weekly. The
  app's container survives reinstall, so prefixes and saves are preserved.

Because JIT requires debugger attach, this app cannot be distributed through the
App Store. It is installed by sideloading.

## Building

The build is split across several chains — the unix-side Wine libraries, the
ARM64EC PE modules, FEX, DXMT and the iOS app itself. `build/*/build.sh` covers
the native pieces; the app is built with `xcodebuild`.

```sh
git clone --recurse-submodules <this repo>
```

Note that `FEX`, `wine` and `research/dxmt` are submodules pointing at forks
containing the iOS work; upstream clones will not build here.

## License

**GPL-3.0-or-later** — see [`LICENSE`](LICENSE). Derivatives that are
distributed must remain open source.

### Upstream licenses vs. this project's forks

Those are the licenses of the **upstream projects**: Wine and GnuTLS
LGPL-2.1-or-later, GMP and Nettle LGPL-3.0-or-later, FEX-Emu and DXMT MIT,
rpmalloc 0BSD. Their texts are in [`LICENSES/`](LICENSES), and upstream code
remains available under them **from upstream**.

**The forks used here are not licensed identically to their upstreams.** Each
carries its own `LICENSE-MADEIRA.md` saying exactly what applies:

| Fork | Terms |
|---|---|
| [`wine`](https://github.com/willfaust/wine) | relicensed to **GPL-3.0-or-later** under LGPL-2.1 §3 |
| [`FEX`](https://github.com/willfaust/FEX), [`dxmt`](https://github.com/willfaust/dxmt) | upstream MIT preserved; modifications **GPL-3.0-or-later** |
| [`rpmalloc`](https://github.com/willfaust/rpmalloc) | upstream 0BSD preserved; Will Faust's modifications **GPL-3.0-or-later** |

This is not retroactive: those forks were public beforehand, so anything
already obtained under a permissive license stays available under it.

[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) has the per-component
breakdown. Note in particular that the Microsoft Visual C++ runtime DLLs are
not distributed here and must be supplied yourself — see
[`tools/fetch-vcruntime.md`](tools/fetch-vcruntime.md).

## A note on upstream contributions

The forks here contain substantial AI-assisted work. FEX-Emu's contribution
policy states that AI must not be used to generate code for contributions to
that project, so **do not submit AI-generated changes from this fork upstream**.
The MIT license permits the fork itself; the policy governs contributions back.
Check each upstream's contribution policy before proposing changes to it.
