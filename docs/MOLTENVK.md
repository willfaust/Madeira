# MoltenVK

Optional 64-bit Windows Vulkan support using stock MoltenVK 1.4.1.

Follow [BUILDING.md](BUILDING.md), then run:

```sh
bash build/moltenvk-ios/build.sh
bash build/moltenvk-ios/build-pe.sh
MADEIRA_MOLTENVK=1 bash build/ntdll-unix/build.sh
MADEIRA_MOLTENVK=1 bash build/win32u-unix/build.sh
```

For Linux framework builds, see `python3 build/moltenvk-ios/build-xtool.py --help`.
Build the app normally; its embedding step copies the framework, licenses
and source receipt and uses the app's signing identity.

To disable, rebuild both Wine archives without `MADEIRA_MOLTENVK=1`, then the app.

Host lifecycle test:

```sh
bash build/host-tests/run-moltenvk-wsi.sh
```

WOW64 Vulkan is unsupported. ARM64EC device fixtures pass; x86-64 device
compatibility remains unverified.
