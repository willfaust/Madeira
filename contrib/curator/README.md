# Curator: on-device log triage and bug reporting (contributed from Triptych)

Curator is the troubleshooting assistant from [Triptych](https://github.com/RageMC/triptych), an iOS/iPadOS app that runs
Windows, macOS and Linux software. It's shared here because the same problems (JIT not enabled, missing boot disk,
full storage, driver crashes) show up in every emulator on iOS, and good reports save maintainers time.

## What it does
1. **Rule-based triage** (`Sources/Triage.swift`): scans logs for known error patterns and shows a plain-language finding
   with a fix right away. No model needed. Edit the patterns for your project.
2. **On-device model** (`CuratorModel.swift`, `CuratorFallbackModel.swift`): only when no rule matches, Apple's on-device
   Foundation Models (or a small fallback) describe the problem and pick a fix from a fixed list (`CuratorFixPack.swift`).
   It never invents commands.
3. **Scrubbing** (`LogScrubber.swift`): removes user names, paths, device names, emails and tokens before anything leaves the device.
4. **GitHub reports** (`GitHubReporter.swift`, `CuratorReport.swift`): the user reviews the report, then sends it either with
   their own GitHub account (device-flow sign-in) or anonymously through the relay in `relay/` (Cloudflare Worker with a
   GitHub App scoped to one tracker; duplicate crashes are matched to existing issues).
5. `Sources/TriptychLogs.swift` shows how Triptych gathered logs from each engine; replace it with your own log paths.

`Tests/` holds the unit and UI tests (131 passed in Triptych). `tools/curator-fixpack.swift` builds the fix list.

## Using it
Copy `Sources/` into your app target (Swift 5, iOS 17+; the Foundation Models path needs iOS 26 and is optional), set
`GitHubReporter.Config.defaultRepo` to your tracker, and adapt `Triage.swift` patterns and the fix pack to your app.
For anonymous reports, follow `relay/README.md`.

## Status
Taken from Triptych v0.1.0. It worked in the iPad Simulator; real-device use was limited. Triptych has ended and its
author won't maintain this, so adapt it freely. Contributed under this repository's license.
