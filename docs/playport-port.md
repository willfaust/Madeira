# Playport game browser port

Source: [Playport 412de5f](https://github.com/playportdev/playport/tree/412de5f8c0bdd26d84e0127eb5776ba992e3b152). Original source headers and license notices are retained. Playport's Madeira Converter Exception covers the imported app code. This work has no dependency on the upcoming BCD port.

Allows a running game to request an HTTP or HTTPS page inside Madeira. The user first confirms the host. The page opens in a private web view with Back and Done. The existing game menu holds input during the prompt and page. Known Epic activation requests can receive a fresh exchange code from the current Epic session.

Uses Playport's URL classification and Epic activation policy. Madeira supplies a small Windows URL helper, a per-session loopback endpoint and bounded HTTP parser. Only the Wine HTTP/HTTPS registry defaults are updated, with a first-write backup. Custom handlers and other protocols stay intact. The dedicated helper does not replace winebrowser.exe. Helper source and ARM64EC, ARM64 and i386 builds are included. The WebKit-only ATS setting permits requested HTTP pages; native networking policy is unchanged.

Validation: all eight URL, request-parser and registry tests passed. The package builds for iOS 17 and all 101 production Swift files typecheck together. All three Windows helpers compiled. In an isolated simulator app, a real loopback request displayed the confirmation, Open loaded example.com, and Done returned to the app. The simulator check found and fixed a prompt-to-page transition bug.

Draft: the isolated test stubs the game runtime. Real Wine ShellExecute, game input restoration, Epic activation and a full device build remain to be tested. No Wine fork or BCD port dependency is required.
