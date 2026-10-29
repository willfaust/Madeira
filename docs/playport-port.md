# Playport gog port

Source: [Playport 412de5f](https://github.com/playportdev/playport/tree/412de5f8c0bdd26d84e0127eb5776ba992e3b152). Original source headers and license notices are retained. Playport's Madeira Converter Exception covers the imported app code. This work has no dependency on the upcoming BCD port.

Adds GOG account and owned-library access in Settings. Games can be installed, updated, verified, repaired and launched from the existing Madeira library. The native client stages game data and dependencies. A small Windows helper runs dependency/support setup before the game, keeps command arguments literal, and applies the store's working folder. Existing library IDs and user settings survive updates. Galaxy services start and stop with the game session.

This vendors Playport's GOGClient and shared ContentKit as local packages. Session secrets use Keychain. The new launch manifest has bounded lengths, safe relative paths and no shell expansion. Original dependencies and setup support remain intact. The GOG helper is built from included C source.

Validation: 41 GOG tests, 15 ContentKit tests, iOS 17 package build and the 101-file production Swift typecheck passed. The native manifest parser passed AddressSanitizer and UndefinedBehaviorSanitizer checks. The ARM64EC helper compiled. The actual GOG page and private sign-in view loaded in an isolated simulator UI app; Cancel worked.

Draft: no account credentials were entered. Authenticated downloads, real setup programs, Galaxy/game behaviour and a full Madeira device build still need validation. This is separate from the BCD port.
