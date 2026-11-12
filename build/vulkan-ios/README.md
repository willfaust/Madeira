# Static Vulkan backend

This group uses one Wine Vulkan loader for the dynamic and static backends.
The default uses no Vulkan library until the session selects one. The retained
surface adapter releases its CAMetalLayer after Wine destroys the client surface.
The loader retains the setup reentry guard from PR353.

For a static build, run fetch.sh and build.sh in this folder. Rebuild the native
win32u and ntdll libraries with MADEIRA_MOLTENVK=1, and link the app with
MADEIRA_VULKAN_LDFLAGS=-lmadeira_vulkan. Set `vulkan = static` in madeira.cfg.
The app refuses that selection when the static backend is absent. Dynamic
`vulkan = moltenvk` and `vulkan = kosmickrisp` remain separate choices.

Wine's Unix thunk table comes from build/ntdll-unix for both routes. The static
archive contains the backend and MoltenVK, with no second Wine thunk table.
The backend keeps PR400's real result forwarding and required portability
extension handling. It does not add optional device features.

Host fixtures cover surface lifetime, failure propagation and backend selection.
They do not prove GPU presentation, driver compatibility or gameplay on iOS.

An optional, isolated MoltenVK v1.4.2 source backport for direct pipeline-cache
exports is documented in `patches/README.md`. `MADEIRA_MOLTENVK_LIBRARY` selects
its static archive at build time; omitting it keeps the official archive path.

The explicitly optional [broader experimental profile](experimental/README.md)
contains the complete historical Detroit study source diff, ten MoltenVK source
patches, build/config entry points, generic probes and the historical unsigned
IPA's download/hash record. It does not enable policies in ordinary builds or
establish current-main game compatibility.
