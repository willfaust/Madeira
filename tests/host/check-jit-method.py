#!/usr/bin/env python3
"""Static integration checks for StikDebug and the iOS 26 built-in JIT helper."""

from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[2]
app = root / "app/Madeira"
project = (root / "app/Madeira.xcodeproj/project.pbxproj").read_text()
stik = (app / "StikJITHelper.swift").read_text()
setup = (app / "JITSetup.swift").read_text()
host = (app / "JITBuiltInHost.swift").read_text()
messages = (app / "JITBuiltInMessages.swift").read_text()
helper = (root / "app/MadeiraJITHelper/MadeiraJITHelper.swift").read_text()
content = (app / "ContentView.swift").read_text()
library = (app / "Library.swift").read_text()


def require(condition, label):
    if not condition:
        raise AssertionError(label)
    print(f"PASS: {label}")


def function(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


# StikDebug must target this process, carry the one bundled script, and wait
# for a live debugger rather than accepting the sticky CS_DEBUGGED bit alone.
enable = function(stik, "static func enableJIT(")
require('components.scheme = "stikdebug"' in enable
        and 'components.host = "enable-jit"' in enable,
        "StikDebug uses the canonical enable-jit URL")
require('URLQueryItem(name: "bundle-id", value: bundleID)' in enable
        and 'URLQueryItem(name: "pid", value: String(getpid()))' in enable
        and 'URLQueryItem(name: "script-data", value: scriptData.base64EncodedString())' in enable,
        "StikDebug request targets the current PID and carries Madeira's script")
require('Bundle.main.url(forResource: "madeira-jit", withExtension: "js")' in stik
        and "private static let scriptBase64" not in stik,
        "the bundled JavaScript file is the single script source")
wait = function(stik, "static func waitForDebugger(")
require("timeout: TimeInterval = 90" in wait and "if ready {" in wait,
        "StikDebug attach has a finite 90-second readiness timeout")
ready = function(stik, "static var ready: Bool")
# ml1235 (local): `ready` reads CS_DEBUGGED through SigningStatus.current.debugged,
# the same csops query without jit_check_debugged's log line (the library polls
# `ready` every 2 s and waitForDebugger every 0.5 s).
require(("jit_check_debugged()" in ready or "SigningStatus.current.debugged" in ready)
        and "isDebuggerAttached()" in ready,
        "readiness requires CS_DEBUGGED and a live debugger")

# Automatic selection is deterministic: installed StikDebug first, otherwise
# the built-in helper. A failure never silently falls through to another method.
resolved = function(setup, "var resolvedMethod: JITMethod")
require("StikJITHelper.isAvailable ? .stikDebug : .builtIn" in resolved,
        "Automatic prefers installed StikDebug, then Built-in StikJIT")
coordinator_enable = function(setup, "func enable(completion:")
coordinator_route = function(setup, "private func enableResolved(")
require("ensureLoopback" in coordinator_enable and "self?.enableResolved" in coordinator_enable
        and "switch resolvedMethod" in coordinator_route
        and "enableBuiltIn(completion: completion)" in coordinator_route
        and setup.count("StikJITHelper.enableJIT") == 1,
        "the coordinator routes each selected JIT method once, after the loopback check")
require("JITSetupView()" in content and "JITSettingsSection()" in library,
        "JIT setup is reachable from the main flow and Settings")
require('dictionary["public_key"]' in setup
        and 'dictionary["private_key"]' in setup
        and 'dictionary["identifier"]' in setup,
        "pairing import rejects ordinary lockdown plists before invoking StikJIT")

# The debugger must run in a separate extension process. The request includes
# the target app PID and helper always forces Madeira's custom script.
# The helper is a classic app extension started by the bundle ID it has in this
# installation (LiveContainer's way), so a sideloader that renames Madeira's bundle ID
# (and the helper's with it) does not lose it; an ExtensionKit extension point did.
require("extensionWithIdentifier:error:" in host and "beginExtensionRequestWithInputItems:completion:" in host
        and "setRequestCompletionBlock:" in host and "setRequestInterruptionBlock:" in host
        and 'Bundle.main.builtInPlugInsURL?.appendingPathComponent(helperFile)' in host
        and "Bundle(url: url)?.bundleIdentifier" in host,
        "the app starts the helper extension by the helper's own bundle ID in this installation")
require("ExtensionFoundation" not in helper.replace("ExtensionFoundation.framework", "")
        and "AppExtensionPoint" not in host and "EX_ENABLE_EXTENSION_POINT_GENERATION" not in project
        and "extensionkit" not in project,
        "no ExtensionKit extension point is declared or looked up (iOS registers none for a renamed install)")
require("let targetPID: Int32?" in messages and "let pairingData: Data?" in messages
        and "let scriptBase64: String?" in messages
        and "item.userInfo = [MadeiraJITRequest.itemKey: data]" in host
        and "context.completeRequest(returningItems: [item], completionHandler: nil)" in helper
        and "@objc(MadeiraJITHelperHandler)" in helper,
        "the request (PID, pairing data, script) goes in the extension request, the answer in the item it completes with")
helper_enable = helper[helper.index("try StikJIT.enableJIT("):]
require("targetPID: targetPID" in helper_enable
        and "script: .customBase64(scriptBase64)" in helper_enable
        and "forceScript: true" in helper_enable,
        "the helper attaches to Madeira and forces its custom script")
require('getenv("LC_HOME_PATH")' in host,
        "built-in JIT is disabled under LiveContainer")

# Packaging: both targets share Codable messages; only the helper links the
# device-only StikJIT framework; the script and helper are embedded in the app.
for marker in [
    "MadeiraJITHelper.appex in Embed JIT Helper",
    "madeira-jit.js in Resources",
    "JITBuiltInMessages.swift in Helper Sources",
    "Frameworks/StikJIT.xcframework/ios-arm64",
]:
    require(marker in project, f"Xcode project contains {marker}")
require(project.count('"OTHER_LDFLAGS[sdk=iphoneos*]"') == 2
        and re.search(r"(?m)^\s*OTHER_LDFLAGS\s*=", project) is None
        and "#if targetEnvironment(simulator)" in helper,
        "StikJIT links on device only, with a simulator-safe helper stub")

with (app / "Info.plist").open("rb") as f:
    app_plist = plistlib.load(f)
require("stikdebug" in app_plist["LSApplicationQueriesSchemes"],
        "the app may detect the canonical StikDebug URL scheme")
with (root / "app/MadeiraJITHelper/Info.plist").open("rb") as f:
    helper_plist = plistlib.load(f)
extension_info = helper_plist.get("NSExtension", {})
require(helper_plist["CFBundlePackageType"] == "XPC!" and "EXAppExtensionAttributes" not in helper_plist
        and extension_info.get("NSExtensionPointIdentifier") == "com.apple.ar.viewer"
        and extension_info.get("NSExtensionPrincipalClass") == "MadeiraJITHelperHandler"
        and helper_plist["XPCService"]["_ProcessType"] == "App"
        and 'productType = "com.apple.product-type.app-extension";' in project
        and "dstSubfolderSpec = 13;" in project[project.index("/* Embed JIT Helper */ = {"):],
        "the helper is a classic app extension in PlugIns, as LiveContainer's LiveProcess")
project = (root / "app/Madeira.xcodeproj/project.pbxproj").read_text()
helper_source = (root / "app/MadeiraJITHelper/MadeiraJITHelper.swift").read_text()
require(project.count('PRODUCT_BUNDLE_IDENTIFIER = "$(MADEIRA_BUNDLE_IDENTIFIER)";') == 2
        and project.count('PRODUCT_BUNDLE_IDENTIFIER = "$(MADEIRA_BUNDLE_IDENTIFIER).JITHelper";') == 2
        and project.count("MADEIRA_BUNDLE_IDENTIFIER = com.willfaust.madeora;") == 2
        and "AppExtensionPoint" not in helper_source,
        "one setting, MADEIRA_BUNDLE_IDENTIFIER, names the app and the helper")

problem = setup[setup.index("enum ConnectionProblem"):setup.index("var message: String")]
require(problem.index('"connectionreset"') < problem.index("self = .pairing") < problem.index('"connectionrefused"')
        < problem.index('"timedout"') < problem.index("self = .vpn"),
        "a reset connection reads as a rejected pairing; refused, timed out or unreachable as LocalDevVPN")
require(setup.count("helperFailure(response.message)") == 2,
        "Check setup and Enable JIT both explain connection problems")
library_source = (app / "Library.swift").read_text()
require("if let jitProblem { jitConnectionActions(jitProblem, retry: enableJIT) { model.error = nil } }" in library_source,
        "the library's JIT error offers Pair Again and LocalDevVPN (or the shortcut)")
# The error alert hangs off LibraryView's tab view, so it presents from Settings too
# (an alert inside the Library page waited until that tab came back).
body = library_source[library_source.index('struct LibraryView: View {'):]
body = body[body.index('    var body: some View {'):body.index('    @ToolbarContentBuilder private var libraryToolbar')]
require('.alert(jitProblem == nil ? "Library" : "Couldn\'t Enable JIT"' in body,
        "the library's error alert is on the tab view, shown on the Settings tab as well")
require('URL(string: "localdevvpn://enable?scheme=madeira")' in setup
        and "localdevvpn" in app_plist["LSApplicationQueriesSchemes"]
        and any("madeira" in t.get("CFBundleURLSchemes", []) for t in app_plist.get("CFBundleURLTypes", [])),
        "LocalDevVPN opens to connect and returns to Madeira's own URL scheme")

# Play without JIT runs Enable JIT, then starts the game, once: only with the debugger
# attached (so the start cannot ask again), and never after a failure.
gate = function(content, "private func jitReadyForLaunch(")
require(gate.index("if StikJITHelper.ready { return true }") < gate.index("if inLibrary, let launch {")
        < gate.index("if StikJITHelper.flaggedWithoutDebugger {")
        and "launchAfterJIT = launch" in gate and "library.startingJIT = entry" in gate
        and "if jitStatus != .testing { enableJIT() }" in gate,
        "Play without JIT enables it (a second Play while it runs only replaces the game)")
ended = function(content, "private func launchAfterJITEnded(")
require("launchAfterJIT = nil" in ended
        and "guard started, StikJITHelper.ready, library.current == nil, wine_process_is_running() == 0 else {" in ended
        and ended.index("launchAfterJIT = nil") < ended.index("library.startingJIT = nil") < ended.index("launch()"),
        "the waiting game starts once, only when JIT came on and nothing else started")
require('if model.startingJIT == entry.id {' in library and 'Text("Starting JIT")' in library and 'ProgressView()' in library
        and "if selected?.id == entry.id, model.startingJIT != entry.id { selected = nil }" in library
        and ".onChange(of: jit.showSetup) { _, show in if show { selected = nil } }" in library,
        "the Play button reads Starting JIT with a spinner meanwhile; the details page stays up for it, "
        "and closes for JIT setup")
enable_jit = function(content, "private func enableJIT()")
require(enable_jit.count("launchAfterJITEnded(started: false)") == 2 and enable_jit.count("launchAfterJITEnded(started: true)") == 1,
        "every way Enable JIT ends settles the waiting game")
play = function(content, "private func launchLibraryEntry(")
require("guard jitReadyForLaunch(inLibrary: true, entry: entry.id, then: { startLibraryEntry(entry) }) else { return }" in play
        and play.index("cloudClear(") < play.index("jitReadyForLaunch(")
        and "then: { startDock(game, compactPool: compactPool, profile: profile) }) else { return }" in content,
        "Play and Dock starts continue after JIT without repeating the checks already passed")

print("check-jit-method: PASS")
