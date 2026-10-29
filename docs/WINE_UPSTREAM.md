# Wine 11.20 integration

This source update pairs with Wine's `codex/wine-11.20-mobile` branch. It is
stacked on Madeira #444 and Wine #64. The existing PR chain remains separate.

## Source changes

Rebase the native window, class, message, display and server copies onto Wine
11.20 while keeping Madeira's process, input, memory and compositor behavior.
Adapt GDI 110, OpenGL driver 41, Vulkan driver 48 and server protocol 964.
The ARM64 protocol now omits x18 from transmitted integer registers. Preserve
that iOS thread register in both context conversion and Mach resume paths.

The mobile loader, process, virtual memory, signal and thread implementation
keep their existing kernel interface. `loadorder_ios.c` keeps the matching
loader policy. Wine selects the retained private header under `WINE_IOS`.
This does not import every new upstream native loader or signal-stack feature.

The OpenGL adapter uses the new context and drawable API for EAGL and OSMesa.
Framebuffers keep their context alive and cleanup uses that context's object
namespace. If another thread still owns that context, cleanup keeps the prior
teardown fallback. Concurrent surface migration still needs owner-thread cleanup.
The Vulkan adapter uses Wine-owned client surfaces and balances the retained
Metal layer on create failure and destruction.

Update the FFmpeg parser flags and format size, certificate export call-table
entry, static GnuTLS symbol table and server object tables. Full server builds
compile every source again to prevent protocol mixing with an old archive.
The ntdll build stops before packaging if any source fails to compile. Keep
the ulock fallback before iOS 17.4 and the pipe/fcntl fallback on iOS.

Remove 19 old ARM64EC DLL copies whose Wine 11.20 Makefiles now enable only
i386. The CI build still builds their supported 32-bit versions. The 64-bit
package must not retain DLLs from the older Wine revision.

## Checks performed

With Xcode 27.1, the iPhoneOS 27.1 SDK and iOS 17 deployment target:

- 41 ntdll/native adapter units compiled and formed `libntdll_unix.a`.
- 47 win32u units compiled and formed `libwin32u_unix.a`.
- The complete wineserver source build and symbol rename step formed
  `libwineserver.a`.
- Rebuilt the pinned iOS FreeType, GnuTLS/GMP/Nettle and FFmpeg dependencies.
- Built aarch64 Wine ntdll, wow64, wow64win, XInput, DirectInput and bcrypt.
  Built ARM64EC ntdll, XInput, DirectInput and bcrypt with the restored crypto
  backend. These checks do not rebuild every DLL in the app package.
- The Objective-C EAGL bridge passed its iOS syntax check.
- Wine's seven focused host suites passed. Madeira's 19 focused host suites
  passed, including controller transport, hardware input, foreground, child
  desktop, window geometry/visibility, storage, WoW64 context, server requests,
  shared-object alignment, WMA audio, Vulkan lifetime, OpenGL cleanup and the
  new ARM64 protocol round-trip, WoW64 certificate-export and iOS 17 fallback checks. Several use ASan and UBSan.

## Required before merge or release

Rebuild and package all shipped Wine PE modules from this exact Wine revision,
including aarch64 WoW64 support and all x86 DLLs. Rebuild the matching DXMT
integration against the changed Wine interfaces. Run the full app link and
package checks. Do not combine the new native archives with the tracked old DLL
package. CI produces the matching DLL package; native archives are not checked in.

No current iPad, GPU, gameplay, standalone or LiveContainer run has been
performed for this update. Check those paths before marking the drafts ready.
Use Wine's `documentation/madeira-upstream-sync.md` for the test matrix and
mobile compatibility exceptions. Roll back the Wine pin, native archives and
DLL package together if a device check fails.
