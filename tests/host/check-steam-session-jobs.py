#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Host check for SteamSession's pending jobs; never contacts Steam.

Each request (callServiceMethod, sendAndWait, sendAndWaitPICS) parks a
CheckedContinuation in a dictionary. Whoever removes it from the dictionary
resumes it, exactly once: the response, the timeout, disconnect() or a failed
send. A second resume traps the app.

This builds the production SteamSession.swift with a stand-in SteamConnection
whose send() parks until the check releases it and then fails, the way a write
fails on a socket that is closing. For each request the check runs the order
that crashed the app: the send is in flight, disconnect() fails the request,
then the send fails too.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
steam = root / 'app/Madeira/SwiftSteam'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


# The gzip helper at the end of the file needs Apple's Compression; no job path uses it.
session = (steam / 'Core/SteamSession.swift').read_text()
session = 'import Observation\n' + session[:session.index('// MARK: - Data Extensions')]

stubs = r'''
import Foundation
enum SteamLog { static func trace(_ m: @autoclosure () -> String) {}; static func event(_ m: String) {} }
enum SteamDevice { static let name = "host" }
enum SteamSignIn { static func credentialsForDock() -> (accountName: String, refreshToken: String)? { nil } }
actor CMServerList {}
extension Data { func gunzip(expectedSize: Int = 0) -> Data? { nil } }

/// Stand-in for the WebSocket. send() parks until release(), then fails.
actor SteamConnection {
    nonisolated(unsafe) static var last: SteamConnection?
    private var parked: CheckedContinuation<Void, Never>?
    init() { Self.last = self }
    var isConnected: Bool { true }
    var isSending: Bool { parked != nil }
    func setMessageHandler(_ handler: @escaping (Data) -> Void) {}
    func setDisconnectHandler(_ handler: @escaping (Error?) -> Void) {}
    func connect() async throws {}
    func reconnect() async throws {}
    func disconnect() {}
    func send(_ data: Data) async throws {
        await withCheckedContinuation { parked = $0 }
        throw SteamError.disconnected
    }
    func release() { parked?.resume(); parked = nil }
}
'''

checks = r'''
import Foundation
var failures = 0
@MainActor func require(_ condition: Bool, _ label: String) {
    if condition { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}

/// Sends a request, disconnects while its send is in flight, then fails the send.
@MainActor func disconnectDuringSend(_ label: String, _ request: @escaping @MainActor (SteamSession) async throws -> Void) async throws {
    let session = SteamSession()
    let connection = SteamConnection.last!
    let call = Task { @MainActor () -> String in
        do { try await request(session); return "returned" } catch { return "\(error)" }
    }
    while !(await connection.isSending) { try await Task.sleep(nanoseconds: 1_000_000) }
    session.disconnect()
    let outcome = await call.value
    require(outcome == "disconnected", "\(label): disconnect() fails the request in flight (\(outcome))")
    await connection.release()
    // The send's failure reaches the main actor next; a second resume would trap here.
    try await Task.sleep(nanoseconds: 200_000_000)
    require(true, "\(label): the send failing afterwards does not resume the request again")
}

@main struct Checks {
    @MainActor static func main() async throws {
        try await disconnectDuringSend("callServiceMethod") { session in
            _ = try await session.callServiceMethod(method: .getOwnedGames, body: Data(), timeout: 60)
        }
        try await disconnectDuringSend("sendAndWait") { session in
            _ = try await session.sendAndWait(eMsg: .clientPICSAccessTokenRequest, body: Data(),
                                              responseEMsg: .clientPICSAccessTokenResponse, timeout: 60)
        }
        try await disconnectDuringSend("sendAndWaitPICS") { session in
            _ = try await session.sendAndWaitPICS(eMsg: .clientPICSProductInfoRequest, body: Data(), timeout: 60)
        }
        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all SteamSession job checks")
    }
}
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'session.swift').write_text(session)
    (tmp / 'stubs.swift').write_text(stubs)
    (tmp / 'checks.swift').write_text(checks)
    sources = [tmp / 'session.swift', tmp / 'stubs.swift', tmp / 'checks.swift',
               steam / 'Proto/SteamProtoMessages.swift', steam / 'Core/SteamError.swift', steam / 'Core/SteamProtocol.swift',
               steam / 'Core/SteamMessageCodec.swift', steam / 'Core/SteamCMSession.swift', steam / 'Core/LicenseListBox.swift']
    exe = tmp / 'swift-checks'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-o', str(exe)] + [str(s) for s in sources],
                           capture_output=True, text=True)
    require(build.returncode == 0, 'production SteamSession.swift compiles on the host with a stand-in connection')
    if build.returncode:
        sys.stdout.write(build.stderr[-6000:])
    else:
        # The Swift crash handler would sit on the pipes after a trap; the trap message is enough.
        run = subprocess.run([str(exe)], env=dict(os.environ, SWIFT_BACKTRACE='enable=no'), capture_output=True, text=True, timeout=120)
        sys.stdout.write(run.stdout)
        if run.returncode:
            sys.stdout.write(run.stderr[-3000:])
        require(run.returncode == 0, 'Swift checks exit cleanly (no continuation resumed twice)')

if failures:
    print(f'FAILURES: {failures}')
    sys.exit(1)
print('PASS: all SteamSession job host checks')
