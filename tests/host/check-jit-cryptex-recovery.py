#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Run the production JIT request handler with scripted StikJIT responses."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/MadeiraJITHelper/MadeiraJITHelper.swift').read_text()
messages = (root / 'app/Madeira/JITBuiltInMessages.swift').read_text()
start = source.index('private enum MadeiraJITWork {')
opening = source.index('{', start)
depth, end = 1, opening + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
handler = source[start:end]
# Keep all request/recovery logic; redirect only its on-device storage root.
storage = 'manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]'
assert handler.count(storage) == 1
handler = handler.replace(storage, 'URL(fileURLWithPath: CommandLine.arguments[1])')
swift = r'''
import Foundation
struct DDIPaths { static func `default`(in directory: URL) -> Self { Self() } }
enum StikJIT {
    enum Script { case customBase64(String) }
    enum PreparationStage { case checkingDDI }
    struct DeviceSecurityState { let isTXMPresent: Bool? }
    enum JITReadiness {
        case ready(DeviceSecurityState)
        case unreachable(reason: String)
        case preparationFailed(reason: String)
    }
    static var isTXMPresent: Bool? { nil }
    static var results: [JITReadiness] = []
    static var enableErrors: [String?] = []
    static var mounted = false
    static var queryError = false
    static var prepares = 0, enables = 0, queries = 0
    static func reset() {
        results = []; enableErrors = []; mounted = false; queryError = false
        prepares = 0; enables = 0; queries = 0
    }
    static func error(_ message: String) -> NSError {
        NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func prepareDevice(pairingFile: URL, paths: DDIPaths,
                              progress: (PreparationStage) -> Void) -> JITReadiness {
        prepares += 1
        return results.removeFirst()
    }
    static func isDDIMounted(pairingFile: URL) throws -> Bool {
        queries += 1
        if queryError { throw error("query failed") }
        return mounted
    }
    static func enableJIT(targetPID: Int32, pairingFile: URL, ddiPaths: DDIPaths,
                          script: Script, forceScript: Bool,
                          preparationProgress: (PreparationStage) -> Void,
                          progress: (String) -> Void) throws {
        enables += 1
        precondition(forceScript && targetPID == 42)
        if case .customBase64(let data) = script { precondition(data == "fixture") }
        if let message = enableErrors.removeFirst() { throw error(message) }
    }
    static func resetCachedDDI(at paths: DDIPaths) throws {}
}
''' + messages + '\n' + handler + r'''
let duplicate = #"Cryptexd(RoutineFailed { routine: "install", detail: "system: cryptex already exists: <private> (com.apple.security.cryptex: 17)" }) (idevice code 110/1)."#
let ready = StikJIT.JITReadiness.ready(.init(isTXMPresent: true))
let prepare = MadeiraJITRequest.prepare(pairingData: Data([1]))
let enable = MadeiraJITRequest.enable(targetPID: 42, pairingData: Data([1]), scriptBase64: "fixture")
var failed = 0
func expect(_ condition: Bool, _ label: String) {
    print((condition ? "PASS: " : "FAIL: ") + label)
    if !condition { failed += 1 }
}
StikJIT.reset(); StikJIT.results = [ready]
expect(MadeiraJITWork.handle(prepare).success && StikJIT.prepares == 1 && StikJIT.queries == 0,
       "normal preparation does not query or retry")
StikJIT.reset(); StikJIT.results = [.preparationFailed(reason: duplicate), ready]; StikJIT.mounted = true
let recovered = MadeiraJITWork.handle(prepare)
expect(recovered.success && recovered.txmPresent == true && StikJIT.prepares == 2 && StikJIT.queries == 1,
       "duplicate install recovers only after mounted verification and successful preparation")
StikJIT.reset(); StikJIT.enableErrors = ["The device is not ready for JIT: " + duplicate, nil]; StikJIT.mounted = true
expect(MadeiraJITWork.handle(enable).success && StikJIT.enables == 2 && StikJIT.queries == 1,
       "Enable JIT retries its normal script path after verified duplicate install")
StikJIT.reset(); StikJIT.results = [.preparationFailed(reason: duplicate)]
let unmounted = MadeiraJITWork.handle(prepare)
expect(!unmounted.success && unmounted.message == duplicate && StikJIT.prepares == 1,
       "unmounted duplicate preserves the original failure")
StikJIT.reset(); StikJIT.results = [.preparationFailed(reason: duplicate)]; StikJIT.queryError = true
let queryFailed = MadeiraJITWork.handle(prepare)
expect(!queryFailed.success && queryFailed.message == duplicate && StikJIT.prepares == 1,
       "failed verification preserves the original error")
for message in ["File already exists (17)", duplicate.replacingOccurrences(of: "cryptex: 17)", with: "cryptex: 16)"),
                duplicate.replacingOccurrences(of: #"routine: "install""#, with: #"routine: "uninstall""#)] {
    StikJIT.reset(); StikJIT.results = [.preparationFailed(reason: message)]; StikJIT.mounted = true
    let response = MadeiraJITWork.handle(prepare)
    expect(!response.success && response.message == message && StikJIT.queries == 0 && StikJIT.prepares == 1,
           "other domains, codes and operations do not recover")
}
StikJIT.reset(); StikJIT.results = [.preparationFailed(reason: duplicate), .preparationFailed(reason: duplicate)]; StikJIT.mounted = true
let repeated = MadeiraJITWork.handle(prepare)
expect(!repeated.success && repeated.message == duplicate && StikJIT.prepares == 2 && StikJIT.queries == 1,
       "repeated duplicate stops after one retry")
StikJIT.reset(); StikJIT.enableErrors = [duplicate, "debugger attach failed"]; StikJIT.mounted = true
let attachFailed = MadeiraJITWork.handle(enable)
expect(!attachFailed.success && attachFailed.message == "debugger attach failed" && StikJIT.enables == 2,
       "a later debugger failure is still reported")
StikJIT.reset(); StikJIT.results = [.unreachable(reason: "VPN unreachable")]
let unreachable = MadeiraJITWork.handle(prepare)
expect(!unreachable.success && unreachable.message == "VPN unreachable" && StikJIT.queries == 0,
       "unreachable device is not treated as installed")
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("StikJIT")
expect((try! FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty,
       "temporary pairing files are removed after every request")
exit(failed == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix='madeira-jit-cryptex-') as temporary:
    folder = Path(temporary)
    program = folder / 'recovery.swift'
    program.write_text(swift)
    subprocess.run(['swift', str(program), str(folder)], check=True)
print('check-jit-cryptex-recovery: PASS')
