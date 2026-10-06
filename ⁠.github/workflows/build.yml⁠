<p align="center">
  <img src="docs/assets/banner.png" alt="Madeira — Bringing PC gaming to your iPhone." width="100%">
</p>

<p align="center">
  <a href="https://discord.gg/4t5mNjwCn7"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Finvites%2F4t5mNjwCn7%3Fwith_counts%3Dtrue&query=%24.approximate_member_count&suffix=%20members&label=Discord&logo=discord&logoColor=white&color=5865F2&style=for-the-badge" alt="Join the Madeira Discord"></a>
  &nbsp;&nbsp;&nbsp;
  <a href="https://github.com/willfaust/Madeira/releases"><img src="https://img.shields.io/github/v/release/willfaust/Madeira?label=Release&style=for-the-badge&color=brightgreen" alt="Latest release"></a>
  &nbsp;&nbsp;&nbsp;
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0--or--later-yellow?style=for-the-badge" alt="License: GPL-3.0-or-later"></a>
</p>

Madeira runs Windows PC games on an iPhone, with no jailbreak. Games run as they
are, unmodified, inside a single iOS app.

> [!NOTE]
> Madeira is an active research project. Many games start and some play well,
> but performance and compatibility vary from game to game, and things change
> quickly. Expect rough edges.

## How it works

| Layer | What it does |
|---|---|
| **[FEX-Emu](https://github.com/FEX-Emu/FEX)** | Translates the game's x86 and x86-64 code to ARM64 as it runs. |
| **[Wine](https://www.winehq.org/)** 11.4 | Provides Windows. It is built for ARM64EC, so Wine itself runs natively and only the game's own code is translated. 32-bit games run through WoW64. |
| **[DXMT](https://github.com/3Shain/DXMT)** | Draws Direct3D 9, 10 and 11 with Metal. |
| **[madeira-d3d12](madeira-d3d12)** | Madeira's own Direct3D 12 implementation on Metal, converting DXIL shaders at run time with Apple's Metal Shader Converter. |

iOS apps cannot start other programs, so everything runs in one process: even
Wine's server runs as a thread instead of a separate program.

## Features

- **Game library** with artwork, search and a Windows desktop session.
- **Steam**: sign in, browse the games you own, install and update them, and
  start them through Valve's own Windows Steam client (Madeira Dock).
- **Steam Cloud saves**: saves sync with Steam Cloud when Madeira starts and
  before a game starts, and **Upload saves and close Madeira** in the game
  menu sends them when you stop playing. Saves that
  changed on both sides are never overwritten without asking, and anything a
  sync replaces is backed up.
- **Controllers**: Bluetooth controllers through XInput, plus customisable
  on-screen touch controls.
- **Keyboard, mouse and trackpad** passed through to games as real input.
- **Video and audio** for cutscenes and music, through FFmpeg, VideoToolbox and AudioToolbox.

## Requirements

- An iPhone on **iOS 26 or later**, the only version Madeira currently runs
  on reliably. Development happens on recent Pro iPhones.
- **JIT**, which iOS only allows while a debugger is attached. Madeira can use
  [StikDebug](https://github.com/StikDebug/StikDebug) or its built-in StikJIT
  helper. On iOS 27 the built-in helper can pair the iPhone itself, without a
  computer.
- An **Apple ID** to sideload the app. A free account works; its signing
  expires after 7 days, so the app needs refreshing weekly. Your games and
  saves are kept across reinstalls.

Because JIT needs a debugger, Madeira cannot be offered on the App Store.

## Installing

1. Download the IPA from the [latest release](https://github.com/willfaust/Madeira/releases).
2. Sideload it with your own Apple ID using SideStore, AltStore, Sideloadly,
   Plume or a similar tool.
3. Open Madeira and enable JIT. Automatic mode uses StikDebug when installed,
   otherwise it guides you through the built-in setup; see
   [JIT setup](docs/JIT.md).
4. In **Settings**, check that **JIT** and **Memory+** both show a green check:
   Madeira then says **Ready to play**.

Some 64-bit games need Microsoft's Visual C++ runtime, which is not included
(see [Licensing](#licensing)).

## Building from source

```sh
git clone --recurse-submodules https://github.com/willfaust/Madeira.git
```

`FEX`, `wine`, `dxmt` and `madeira-dock` are submodules that point at Madeira's
own forks; upstream checkouts will not build here. The build has several parts
(the Wine unix libraries, the ARM64EC Windows modules, FEX, DXMT and the app)
and some inputs that are not in the repository, such as the toolchains.
[`docs/BUILDING.md`](docs/BUILDING.md) walks through all of it.

### Repository layout

| Path | Contents |
|---|---|
| [`app/`](app) | The iOS app: SwiftUI front end, Wine bridge and bundled resources |
| [`wine/`](https://github.com/willfaust/wine), [`FEX/`](https://github.com/willfaust/FEX), [`dxmt/`](https://github.com/willfaust/dxmt), [`madeira-dock/`](https://github.com/willfaust/madeira-dock) | Madeira's forks and the Steam client launcher (submodules) |
| [`madeira-d3d12/`](madeira-d3d12) | The native Direct3D 12 runtime |
| [`build/`](build) | Build scripts and iOS-side sources, one folder per component |
| [`tests/`](tests) | Host checks and x86, x86-64 and DXMT test programs |
| [`tools/`](tools) | Helper scripts |
| [`docs/`](docs) | Documentation |
| [`research/`](research) | Experiments that are not part of the app |

## Documentation

| Topic | Document |
|---|---|
| Building from a clean checkout | [`docs/BUILDING.md`](docs/BUILDING.md) |
| StikDebug and built-in JIT setup | [`docs/JIT.md`](docs/JIT.md) |
| The game library | [`docs/LIBRARY.md`](docs/LIBRARY.md) |
| Steam sign-in, library and downloads | [`docs/STEAM_SIGNIN.md`](docs/STEAM_SIGNIN.md), [`docs/STEAM_LIBRARY.md`](docs/STEAM_LIBRARY.md) |
| Steam Cloud saves | [`docs/STEAM_CLOUD.md`](docs/STEAM_CLOUD.md) |
| Madeira Dock (the Steam client) | [`docs/MADEIRA_DOCK.md`](docs/MADEIRA_DOCK.md) |
| 32-bit games (WoW64) | [`docs/WOW64.md`](docs/WOW64.md) |
| Controllers and touch controls | [`docs/CONTROLLERS.md`](docs/CONTROLLERS.md) |
| Keyboard, mouse and trackpad | [`docs/KEYBOARD_MOUSE.md`](docs/KEYBOARD_MOUSE.md) |
| Audio and video | [`docs/MEDIA.md`](docs/MEDIA.md) |
| Licensing in detail | [`docs/LICENSING.md`](docs/LICENSING.md) |

## Licensing

Madeira is licensed under **GPL-3.0-or-later** ([`LICENSE`](LICENSE)) with
the **Madeira Converter Exception** ([`LICENSE-EXCEPTION.md`](LICENSE-EXCEPTION.md)),
an additional permission that allows it to work with Apple's Metal Shader
Converter.

The projects it builds on keep their own licenses upstream, but Madeira's forks
are not all licensed the same way as their upstreams:

| Component | License |
|---|---|
| [Wine fork](https://github.com/willfaust/wine) | LGPL-2.1-or-later, like upstream Wine |
| [FEX-Emu fork](https://github.com/willfaust/FEX), [DXMT fork](https://github.com/willfaust/dxmt) | Upstream code stays MIT; Madeira's changes are GPL-3.0-or-later with the exception |
| [rpmalloc fork](https://github.com/willfaust/rpmalloc) | Upstream code stays 0BSD; Madeira's changes are GPL-3.0-or-later with the exception |
| [Madeira Dock](https://github.com/willfaust/madeira-dock) | GPL-3.0-or-later with the exception |

Anything obtained earlier under a permissive license stays available under it.
Per-component details, including GnuTLS, Nettle, GMP, FFmpeg and LLVM, are in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md); the license texts are in
[`LICENSES/`](LICENSES).

Microsoft's Visual C++ runtime DLLs are **not** distributed with Madeira. To
build with them, supply them yourself as described in
[`tools/fetch-vcruntime.md`](tools/fetch-vcruntime.md).

## Contributing

Contributions are welcome under GPL-3.0-or-later; see
[`CONTRIBUTING.md`](CONTRIBUTING.md).

Madeira's forks contain a lot of AI-assisted work. FEX-Emu does not accept
AI-generated code, so please **do not send changes from these forks upstream**
to FEX-Emu, and check each upstream project's contribution policy before
proposing anything to it.

## Credits

- **Will Faust** ([@willfaust](https://github.com/willfaust)): created Madeira
- **Nick** ([@125hz](https://github.com/125hz)): 32-bit game support, the game library and Madeira Dock
- **Jfishin** ([@Jfishin](https://github.com/Jfishin)): the original native Steam sign-in, library and downloads
- **Jesse** ([@JesseLovelace](https://github.com/JesseLovelace)): Steam Cloud saves, faster game launches, and fixes that let more games run
- **Dan Perks** ([@danperks](https://github.com/danperks)): in-app JIT without StikDebug, and pairing without a computer
- **bahacan16** ([@bahacan16](https://github.com/bahacan16)): Direct3D 12 and DXMT fixes, game launcher windows, per-game settings, PlayStation controllers, and save backups
- **spitefulowl** ([@spitefulowl](https://github.com/spitefulowl)): Wine and FEX runtime fixes, DXMT texture and memory fixes, audio, the swap tier, and library launch options
- **meshoklv** ([@meshoklv](https://github.com/meshoklv)): controller fixes for games that ship their own XInput or need focus, touch taps that stay off the mouse, and a crash-guard fix

Madeira is built on [Wine](https://www.winehq.org/), [FEX-Emu](https://github.com/FEX-Emu/FEX),
[DXMT](https://github.com/3Shain/DXMT) by Feifan He (3Shain) with the Direct3D 9
frontend by David Acevedo (dacevedo12), [rpmalloc](https://github.com/mjansson/rpmalloc)
by Mattias Jansson, [StikDebug](https://github.com/StikDebug/StikDebug),
[StikJIT](https://github.com/StikDebug/StikJIT) and
[idevice](https://github.com/jkcoxson/idevice) for enabling JIT. Thank you to everyone who contributes to them.

<p align="center">
  <a href="https://discord.gg/4t5mNjwCn7"><b>Join the community on Discord</b></a>
</p>
