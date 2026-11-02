// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// What the library fetcher and the depot downloader need from a logged-on
/// Steam connection. `SteamSession` is the one implementation; the host tests
/// (tests/host/check-steam-library.py) use a scripted one, so the
/// download pipeline runs without a network connection to Steam.
@MainActor
protocol SteamCMSession: AnyObject {
    /// The content-server cell the CM assigned at logon (0 before).
    var cellID: UInt32 { get }
    /// The logged-on account, 0 when not logged on.
    var steamID: UInt64 { get }

    /// Connects and logs on when the session is not already.
    func ensureConnected() async throws
    /// The owned package IDs Steam pushes after logon.
    func awaitLicenseList(timeout: TimeInterval) async throws -> [UInt32]
    /// Sends a client message and waits for its response.
    func sendAndWait(eMsg: EMsg, body: Data, responseEMsg: EMsg, timeout: TimeInterval) async throws -> SteamMessageCodec.IncomingMessage
    /// Sends a product-info request and collects every part of its response.
    func sendAndWaitPICS(eMsg: EMsg, body: Data, timeout: TimeInterval) async throws -> [SteamMessageCodec.IncomingMessage]
    /// Calls a unified-service method and returns the response body.
    func callServiceMethod(method: SteamServiceMethod, body: Data, timeout: TimeInterval) async throws -> Data
    /// The same, with the response header's EResult (1 = OK).
    func callServiceMethodWithResult(method: SteamServiceMethod, body: Data, timeout: TimeInterval) async throws -> (eresult: Int32, body: Data)
    /// Sends a unified-service notification (a method without a response).
    func sendServiceNotification(method: SteamServiceMethod, body: Data) async throws
}

extension SteamCMSession {
    /// A connection that reports no EResults answers OK.
    func callServiceMethodWithResult(method: SteamServiceMethod, body: Data, timeout: TimeInterval) async throws -> (eresult: Int32, body: Data) {
        (1, try await callServiceMethod(method: method, body: body, timeout: timeout))
    }
    /// Sessions that never send notifications (scripted ones in tests) need not implement it.
    func sendServiceNotification(method: SteamServiceMethod, body: Data) async throws {}
}
