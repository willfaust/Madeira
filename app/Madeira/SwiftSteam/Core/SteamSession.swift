// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md): the session is
// suspended while a game runs, and the sign-in stays in SteamSignIn.

import Foundation

/// Manages the authenticated Steam session: login, heartbeat, reconnection, message routing.
@Observable
@MainActor
class SteamSession {
    // MARK: - Published State

    private(set) var connectionState: SteamConnectionState = .disconnected
    private(set) var steamID: UInt64 = 0
    private(set) var accountName: String = ""
    private(set) var personaName: String = ""
    private(set) var cellID: UInt32 = 0
    /// While true the session neither connects nor reconnects: a game session
    /// runs, and Valve's own client must be the only one logged on with this
    /// account (see `suspend()`).
    private(set) var isSuspended = false

    // MARK: - Internal State

    private let connection = SteamConnection()
    let serverList = CMServerList()
    private var sessionID: Int32 = 0
    private var heartbeatInterval: Int32 = 30  // seconds
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var idleDisconnectTask: Task<Void, Never>?
    /// How long to stay connected after the last activity before auto-disconnecting (seconds)
    private let idleTimeout: TimeInterval = 60
    private var jobIDCounter: UInt64 = 0
    private var pendingJobs: [UInt64: CheckedContinuation<SteamMessageCodec.IncomingMessage, Error>] = [:]
    private var messageHandlers: [UInt32: (SteamMessageCodec.IncomingMessage) -> Void] = [:]

    private struct PICSAccumulator {
        var messages: [SteamMessageCodec.IncomingMessage]
        var continuation: CheckedContinuation<[SteamMessageCodec.IncomingMessage], Error>
    }
    private var pendingPICSJobs: [UInt64: PICSAccumulator] = [:]
    private let licenseListBox = LicenseListBox()

    /// SteamID used for pre-logon messages.
    /// Universe=Public(1), Type=Individual(1), Instance=Desktop(1), AccountID=0
    /// → 76561197960265728. Using raw 0 causes EResult 5 (InvalidPassword) on
    /// some CM servers.
    private static let preLogonSteamID: UInt64 = 76561197960265728

    // MARK: - Lifecycle

    /// Connect and authenticate using stored tokens (auto-login)
    func connectAndLogin() async throws {
        guard !isSuspended else { throw SteamError.disconnected }
        guard connectionState == .disconnected || connectionState == .reconnecting else { return }

        connectionState = .connecting

        do {
            // Set up message and disconnect handlers
            await connection.setMessageHandler { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.handleMessage(data)
                }
            }
            await connection.setDisconnectHandler { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleDisconnect(error: error)
                }
            }

            // Capture the license list Steam pushes right after logon.
            // Registered before connecting so the handler can never miss it.
            licenseListBox.reset()
            registerHandler(for: .clientLicenseList) { [weak self] message in
                guard let self else { return }
                do {
                    let list = try CMsgClientLicenseList.deserialize(from: message.body)
                    let packageIDs = list.licenses.map { $0.packageID }
                    SteamLog.trace("ClientLicenseList: parsed \(packageIDs.count) packages (body \(message.body.count)B, eresult=\(list.eresult))")
                    self.licenseListBox.set(packageIDs)
                } catch {
                    SteamLog.trace("ClientLicenseList deserialize FAILED (body \(message.body.count)B): \(error)")
                }
            }

            // Connect via WebSocket (wss://) — TLS handles encryption, no ChannelEncrypt needed
            try await connection.connect()
            connectionState = .connected

            // Send ClientHello — required after channel encryption is established.
            let helloData = SteamMessageCodec.encodeClientMessage(
                eMsg: .clientHello,
                body: CMsgClientHello().serialize(),
                steamID: Self.preLogonSteamID,
                sessionID: 0
            )
            try await connection.send(helloData)
            SteamLog.trace("Sent ClientHello (\(helloData.count) bytes)")

            // Try to log in with stored tokens, retrying up to 2 different servers on timeout/redirect
            if let tokens = SteamSignIn.credentialsForDock() {
                var lastError: Error = SteamError.connectionTimeout
                var loggedIn = false
                for attempt in 1...2 {
                    do {
                        if attempt > 1 {
                            SteamLog.trace("Logon attempt \(attempt)/2 — reconnecting to different CM server")
                            try await connection.reconnect()
                            connectionState = .connected
                            let helloRetry = SteamMessageCodec.encodeClientMessage(
                                eMsg: .clientHello,
                                body: CMsgClientHello().serialize(),
                                steamID: Self.preLogonSteamID,
                                sessionID: 0
                            )
                            try await connection.send(helloRetry)
                            SteamLog.trace("Sent ClientHello to new server (attempt \(attempt))")
                        }
                        guard !isSuspended else { throw SteamError.disconnected }
                        try await loginWithToken(accessToken: tokens.refreshToken, accountName: tokens.accountName)
                        loggedIn = true
                        break
                    } catch SteamError.connectionFailed(let reason) where reason == "TryAnotherCM" {
                        SteamLog.trace("TryAnotherCM on attempt \(attempt) — will try different server")
                        lastError = SteamError.connectionFailed("TryAnotherCM")
                    } catch SteamError.connectionTimeout {
                        SteamLog.trace("Timeout on attempt \(attempt) — will try different server")
                        lastError = SteamError.connectionTimeout
                    }
                }
                if !loggedIn {
                    throw lastError
                }
            }
        } catch {
            connectionState = .disconnected
            throw error
        }
    }

    /// Connect on demand if not already connected/authenticated.
    /// Call this before any operation that needs the CM connection.
    func ensureConnected() async throws {
        guard !isSuspended else { throw SteamError.disconnected }
        guard connectionState != .authenticated else {
            resetIdleTimer()
            return
        }
        guard connectionState != .connecting else {
            // Already connecting — wait briefly for it to finish
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if connectionState == .authenticated { return }
                if connectionState == .disconnected { break }
            }
            if connectionState != .authenticated {
                throw SteamError.connectionTimeout
            }
            return
        }
        try await connectAndLogin()
        resetIdleTimer()
    }

    /// The owned package IDs from the license list Steam pushes after logon.
    /// Waits for the push if it hasn't landed yet.
    func awaitLicenseList(timeout: TimeInterval = 15) async throws -> [UInt32] {
        try await licenseListBox.value(timeout: timeout)
    }

    /// Reset the idle disconnect timer — called after each activity
    private func resetIdleTimer() {
        idleDisconnectTask?.cancel()
        idleDisconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.idleTimeout ?? 60) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.connectionState == .authenticated else { return }
            SteamLog.trace("Idle timeout — disconnecting to release the server-side session")
            await self.disconnectGracefully()
        }
    }

    /// Send `ClientLogOff` so Steam servers release the session cleanly,
    /// then tear down the WebSocket. Prefer this over plain `disconnect()`
    /// whenever another session for the same account may log in next —
    /// a raw socket close leaves the session hanging on the server for
    /// several minutes, which can make the next login look like a
    /// duplicate/already-online session.
    ///
    /// Safe to call from any state — only sends logoff when authenticated;
    /// always tears down so a half-connected session can still be cleaned
    /// up.
    func disconnectGracefully() async {
        if connectionState == .authenticated {
            let logoffData = SteamMessageCodec.encodeClientMessage(
                eMsg: .clientLogOff,
                body: Data(),
                steamID: steamID,
                sessionID: sessionID
            )
            try? await connection.send(logoffData)
        }
        disconnect()
    }

    /// Stops the session for the length of a game session: logs off, closes the
    /// socket (awaited, so the account is free before Valve's client signs in)
    /// and refuses to connect until `resume()`. A second logon for the same
    /// account would otherwise log one of the two out.
    func suspend() async {
        isSuspended = true
        await disconnectGracefully()
        await connection.disconnect()
    }

    func resume() { isSuspended = false }

    /// Log in using the refresh token from the auth flow.
    /// NOTE: Despite the parameter name, CM logon requires the *refresh* token (audience: "renew"),
    /// not the access token (audience: "web"). The CMsgClientLogon.access_token field accepts both,
    /// but only the refresh token establishes a CM session.
    /// Single-resume guard for the logon continuation. The logon response,
    /// ClientLoggedOff, the send-error path, and the 20s timeout can each reach
    /// the continuation; without this the timeout double-resumed and crashed
    /// (CheckedContinuation traps on a second resume). Exactly one resume wins.
    private final class LogonResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    func loginWithToken(accessToken: String, accountName: String) async throws {
        guard await connection.isConnected else {
            throw SteamError.disconnected
        }

        self.accountName = accountName

        // Build logon message
        var logon = CMsgClientLogon()
        logon.accountName = accountName
        logon.accessToken = accessToken
        logon.machineName = SteamDevice.name
        logon.clientOSType = -102  // macOS

        let logonData = SteamMessageCodec.encodeClientMessage(
            eMsg: .clientLogon,
            body: logon.serialize(),
            steamID: Self.preLogonSteamID,
            sessionID: 0
        )

        // No logon bytes, token fragments or token claims are logged.

        // ClientLogonResponse (EMsg 5515) is NOT job-correlated — it's an unsolicited push.
        // Register a one-time handler that resolves the continuation when the response arrives.
        // Also handle legacy EMsg 751 (old CMsgClientLogOnResponse numbering).
        let resumeOnce = LogonResumeGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // All resume paths funnel through these so the continuation resumes
            // at most once, even if a handler and the timeout fire together.
            let resumeReturning: () -> Void = {
                if resumeOnce.claim() { continuation.resume(returning: ()) }
            }
            let resumeThrowing: (Error) -> Void = { error in
                if resumeOnce.claim() { continuation.resume(throwing: error) }
            }

            let cleanupHandlers = { [weak self] in
                self?.messageHandlers.removeValue(forKey: EMsg.clientLogonResponse.rawValue)
                self?.messageHandlers.removeValue(forKey: 751)
                self?.messageHandlers.removeValue(forKey: EMsg.clientLoggedOff.rawValue)
            }

            let handleLogonResponse: (SteamMessageCodec.IncomingMessage) -> Void = { [weak self] message in
                guard let self else { return }
                cleanupHandlers()

                let eResultCode: UInt32
                let heartbeatSecs: Int32
                let outCellID: UInt32

                if message.isProtobuf {
                    // EMsg 5515: standard protobuf ClientLogonResponse
                    do {
                        let logonResponse = try CMsgClientLogonResponse.deserialize(from: message.body)
                        eResultCode = UInt32(logonResponse.eresult)
                        heartbeatSecs = logonResponse.heartbeatSeconds > 0 ? logonResponse.heartbeatSeconds : 30
                        outCellID = logonResponse.cellID
                    } catch {
                        resumeThrowing(error)
                        return
                    }
                } else {
                    // EMsg 751: legacy non-protobuf format. Body = [4 bytes EResult as UInt32 LE][...]
                    guard message.body.count >= 4 else {
                        resumeThrowing(SteamError.invalidMessage)
                        return
                    }
                    eResultCode = message.body.withUnsafeBytes {
                        UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
                    }
                    heartbeatSecs = 30
                    outCellID = 0
                }

                SteamLog.trace("ClientLogonResponse: eresult=\(eResultCode)")

                // TryAnotherCM (48): server is overloaded, need to connect to a different server
                if eResultCode == EResult.tryAnotherCM.rawValue {
                    SteamLog.trace("Server says TryAnotherCM — will reconnect to different CM server")
                    resumeThrowing(SteamError.connectionFailed("TryAnotherCM"))
                    return
                }

                guard let result = EResult(rawValue: eResultCode), result.isSuccess else {
                    resumeThrowing(SteamError.logonDenied(eResultCode))
                    return
                }

                // A game session took the account while this logon was on its way
                // (suspend() ran): log straight off again instead of staying online
                // next to Valve's client.
                if self.isSuspended {
                    let logoff = SteamMessageCodec.encodeClientMessage(eMsg: .clientLogOff, body: Data(),
                                                                      steamID: message.header.steamid,
                                                                      sessionID: message.header.clientSessionid)
                    Task { [connection = self.connection] in
                        try? await connection.send(logoff)
                        await connection.disconnect()
                    }
                    SteamLog.trace("Logon completed during a game session: logged off again")
                    resumeThrowing(SteamError.disconnected)
                    return
                }

                self.steamID = message.header.steamid
                self.sessionID = message.header.clientSessionid
                self.heartbeatInterval = heartbeatSecs
                self.cellID = outCellID
                self.connectionState = .authenticated
                self.reconnectAttempts = 0
                SteamLog.trace("Authenticated")
                self.startHeartbeat()
                self.resetIdleTimer()
                resumeReturning()
            }

            messageHandlers[EMsg.clientLogonResponse.rawValue] = handleLogonResponse
            messageHandlers[751] = handleLogonResponse  // Legacy EMsg numbering

            // Also catch immediate rejection via ClientLoggedOff
            messageHandlers[EMsg.clientLoggedOff.rawValue] = { _ in
                cleanupHandlers()
                SteamLog.trace("Got ClientLoggedOff during logon")
                resumeThrowing(SteamError.authenticationFailed("Server sent ClientLoggedOff during logon"))
            }

            Task {
                do {
                    try await connection.send(logonData)
                    SteamLog.trace("Sent ClientLogon, waiting for response")
                } catch {
                    cleanupHandlers()
                    resumeThrowing(error)
                }
            }

            // 20-second timeout — if server doesn't respond after 20s, try different CM.
            // The resume guard (not a messageHandlers TOCTOU check) is what prevents a
            // double-resume if the logon response landed at the same moment.
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                cleanupHandlers()
                if resumeOnce.claim() {
                    SteamLog.trace("ClientLogon timed out after 20s: no response from the server")
                    continuation.resume(throwing: SteamError.connectionTimeout)
                }
            }
        }
    }

    /// Disconnect and clean up
    func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        idleDisconnectTask?.cancel()
        idleDisconnectTask = nil

        // Cancel all pending jobs
        for (_, continuation) in pendingJobs {
            continuation.resume(throwing: SteamError.disconnected)
        }
        pendingJobs.removeAll()
        for (_, acc) in pendingPICSJobs {
            acc.continuation.resume(throwing: SteamError.disconnected)
        }
        pendingPICSJobs.removeAll()

        Task {
            await connection.disconnect()
        }

        connectionState = .disconnected
        steamID = 0
        sessionID = 0
        SteamLog.trace("Session disconnected")
    }

    /// Log off and disconnect. The stored sign-in is left alone: signing out
    /// goes through `SteamSignIn.signOut()`.
    func logoff() {
        // Send logoff message (best-effort)
        if connectionState == .authenticated {
            let logoffData = SteamMessageCodec.encodeClientMessage(
                eMsg: .clientLogOff,
                body: Data(),
                steamID: steamID,
                sessionID: sessionID
            )
            Task {
                try? await connection.send(logoffData)
            }
        }

        disconnect()
        accountName = ""
        personaName = ""
    }

    // MARK: - Message Sending

    /// Get a unique job ID for request/response correlation
    func nextJobID() -> UInt64 {
        jobIDCounter += 1
        return jobIDCounter
    }

    /// Send a message and wait for a specific response
    func sendAndWait(
        eMsg: EMsg,
        body: Data,
        responseEMsg: EMsg,
        timeout: TimeInterval = 10
    ) async throws -> SteamMessageCodec.IncomingMessage {
        resetIdleTimer()
        let jobID = nextJobID()

        let data = SteamMessageCodec.encodeClientMessage(
            eMsg: eMsg,
            body: body,
            steamID: steamID,
            sessionID: sessionID,
            jobID: jobID
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingJobs[jobID] = continuation

            Task {
                do {
                    try await connection.send(data)
                } catch {
                    if pendingJobs.removeValue(forKey: jobID) != nil {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cont = pendingJobs.removeValue(forKey: jobID) {
                    cont.resume(throwing: SteamError.connectionTimeout)
                }
            }
        }
    }

    /// Send a PICSProductInfo request and collect all response messages until pendingResponseCount == 0.
    /// Steam splits large PICS responses across multiple messages with the same jobidTarget.
    func sendAndWaitPICS(
        eMsg: EMsg,
        body: Data,
        timeout: TimeInterval = 30
    ) async throws -> [SteamMessageCodec.IncomingMessage] {
        resetIdleTimer()
        let jobID = nextJobID()

        let data = SteamMessageCodec.encodeClientMessage(
            eMsg: eMsg,
            body: body,
            steamID: steamID,
            sessionID: sessionID,
            jobID: jobID
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingPICSJobs[jobID] = PICSAccumulator(messages: [], continuation: continuation)

            Task {
                do {
                    try await connection.send(data)
                } catch {
                    if pendingPICSJobs.removeValue(forKey: jobID) != nil {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Timeout — return partial results if any arrived, otherwise error
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let acc = pendingPICSJobs.removeValue(forKey: jobID) {
                    if acc.messages.isEmpty {
                        acc.continuation.resume(throwing: SteamError.connectionTimeout)
                    } else {
                        acc.continuation.resume(returning: acc.messages)
                    }
                }
            }
        }
    }

    /// Send a service method call and wait for response
    func callServiceMethod(
        method: SteamServiceMethod,
        body: Data,
        timeout: TimeInterval = 10
    ) async throws -> Data {
        resetIdleTimer()
        let jobID = nextJobID()

        var header = CMsgProtoBufHeader()
        header.steamid = steamID
        header.clientSessionid = sessionID
        header.targetJobName = method.rawValue
        header.jobidSource = jobID

        let data = SteamMessageCodec.encode(
            eMsg: .serviceMethodCallFromClient,
            header: header,
            body: body
        )

        let response: SteamMessageCodec.IncomingMessage = try await withCheckedThrowingContinuation { continuation in
            pendingJobs[jobID] = continuation

            Task {
                do {
                    try await connection.send(data)
                } catch {
                    // disconnect(), the response or the timeout may have resumed it already.
                    if let cont = pendingJobs.removeValue(forKey: jobID) {
                        cont.resume(throwing: error)
                    }
                }
            }

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cont = pendingJobs.removeValue(forKey: jobID) {
                    cont.resume(throwing: SteamError.connectionTimeout)
                }
            }
        }

        if response.header.eresult != 1 {
            SteamLog.trace("\(method.rawValue) header eresult=\(response.header.eresult)")
        }
        return response.body
    }

    /// Send a message without waiting for response
    func sendMessage(eMsg: EMsg, body: Data) async throws {
        let data = SteamMessageCodec.encodeClientMessage(
            eMsg: eMsg,
            body: body,
            steamID: steamID,
            sessionID: sessionID
        )
        try await connection.send(data)
    }

    /// Register a handler for a specific message type
    func registerHandler(for eMsg: EMsg, handler: @escaping (SteamMessageCodec.IncomingMessage) -> Void) {
        messageHandlers[eMsg.rawValue] = handler
    }

    // MARK: - Message Handling

    private func handleMessage(_ data: Data) {
        let message: SteamMessageCodec.IncomingMessage
        do {
            message = try SteamMessageCodec.decode(data)
        } catch {
            SteamLog.trace("Failed to decode message (\(data.count) bytes): \(error)")
            return
        }

        // Every received message, when tracing.
        SteamLog.trace("← \(Self.messageName(message.rawEMsg)) (\(message.body.count) bytes)" +
              (message.header.jobidTarget != UInt64.max ? " jobTarget=\(message.header.jobidTarget)" : "") +
              (!message.header.targetJobName.isEmpty ? " method=\(message.header.targetJobName)" : ""))

        // Handle multi-message containers
        if message.rawEMsg == EMsg.multi.rawValue {
            handleMultiMessage(message)
            return
        }

        // Accumulate multi-part PICSProductInfoResponse messages.
        // Steam sends several responses per request; pendingResponseCount counts down to 0.
        if message.rawEMsg == EMsg.clientPICSProductInfoResponse.rawValue,
           message.header.jobidTarget != UInt64.max,
           var acc = pendingPICSJobs[message.header.jobidTarget] {
            acc.messages.append(message)
            let pending = (try? CMsgClientPICSProductInfoResponse.deserialize(from: message.body))?.pendingResponseCount ?? 0
            if pending == 0 {
                pendingPICSJobs.removeValue(forKey: message.header.jobidTarget)
                acc.continuation.resume(returning: acc.messages)
            } else {
                pendingPICSJobs[message.header.jobidTarget] = acc
            }
            return
        }

        // Check for pending job response (jobidTarget matches our jobidSource)
        if message.header.jobidTarget != UInt64.max,
           let continuation = pendingJobs.removeValue(forKey: message.header.jobidTarget) {
            continuation.resume(returning: message)
            return
        }

        // Log unmatched service method responses for debugging
        if message.rawEMsg == EMsg.serviceMethodResponse.rawValue {
            SteamLog.trace("ServiceMethodResponse not matched: jobTarget=\(message.header.jobidTarget), pending=\(Array(pendingJobs.keys))")
        }

        // Dispatch to registered handlers
        if let handler = messageHandlers[message.rawEMsg] {
            handler(message)
            return
        }

        // Handle known unsolicited messages
        handleUnsolicitedMessage(message)
    }

    private static func messageName(_ raw: UInt32) -> String {
        switch raw {
        case EMsg.multi.rawValue: return "Multi"
        case EMsg.clientLogon.rawValue: return "ClientLogon"
        case EMsg.clientLogonResponse.rawValue: return "ClientLogonResponse"
        case 751: return "ClientLogOnResponse(legacy)"
        case EMsg.clientLoggedOff.rawValue: return "ClientLoggedOff"
        case EMsg.clientHeartBeat.rawValue: return "ClientHeartBeat"
        case EMsg.clientHello.rawValue: return "ClientHello"
        case EMsg.serviceMethodResponse.rawValue: return "ServiceMethodResponse"
        default: return "EMsg\(raw)"
        }
    }

    private func handleMultiMessage(_ message: SteamMessageCodec.IncomingMessage) {
        do {
            let multi = try CMsgMulti.deserialize(from: message.body)
            var payload = multi.messageBody

            // If sizeUnzipped > 0, the payload is gzip compressed
            if multi.sizeUnzipped > 0 {
                guard let decompressed = payload.gunzip(expectedSize: Int(multi.sizeUnzipped)) else {
                    SteamLog.trace("Failed to decompress multi message")
                    return
                }
                payload = decompressed
            }

            // Parse sub-messages: each is [4 bytes length][message data]
            var offset = 0
            while offset + 4 <= payload.count {
                let subLen = payload.withUnsafeBytes { ptr -> UInt32 in
                    ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                }
                let length = Int(UInt32(littleEndian: subLen))
                offset += 4

                guard offset + length <= payload.count else { break }
                let subData = payload.subdata(in: offset..<offset + length)
                offset += length

                handleMessage(subData)
            }
        } catch {
            SteamLog.trace("Failed to parse multi message: \(error)")
        }
    }

    private func handleUnsolicitedMessage(_ message: SteamMessageCodec.IncomingMessage) {
        switch message.rawEMsg {
        case EMsg.clientLoggedOff.rawValue:
            SteamLog.trace("Received ClientLoggedOff")
            handleDisconnect(error: nil)
        case 751:
            // Late-arriving ClientLogOnResponse (handlers already cleaned up by timeout).
            // Parse eresult so we can log it accurately.
            if !message.isProtobuf, message.body.count >= 4 {
                let eResult = message.body.withUnsafeBytes {
                    UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
                }
                let label = eResult == EResult.tryAnotherCM.rawValue ? " (TryAnotherCM — handled by retry logic)" : ""
                SteamLog.trace("Late ClientLogOnResponse: eresult=\(eResult)\(label)")
            }
        default:
            SteamLog.trace("Unhandled EMsg \(message.rawEMsg) (\(message.body.count) bytes)")
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.heartbeatInterval ?? 30)) * 1_000_000_000)
                guard !Task.isCancelled else { break }

                do {
                    try await self?.sendMessage(eMsg: .clientHeartBeat, body: Data())
                } catch {
                    SteamLog.trace("Heartbeat failed: \(error)")
                    break
                }
            }
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect(error: Error?) {
        guard connectionState != .disconnected else { return }

        let wasAuthenticated = connectionState == .authenticated
        connectionState = .reconnecting
        heartbeatTask?.cancel()

        SteamLog.trace("Connection lost\(error.map { ": \($0.localizedDescription)" } ?? "")")

        if wasAuthenticated && reconnectAttempts < maxReconnectAttempts {
            attemptReconnect()
        } else {
            connectionState = .disconnected
        }
    }

    private func attemptReconnect() {
        reconnectTask = Task { [weak self] in
            guard let self else { return }

            // Exponential backoff: 1s, 2s, 4s, 8s, 16s
            let delay = pow(2.0, Double(reconnectAttempts))
            reconnectAttempts += 1

            SteamLog.trace("Reconnecting in \(Int(delay))s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard !Task.isCancelled else { return }

            do {
                try await connectAndLogin()
                SteamLog.trace("Reconnected successfully")
            } catch {
                SteamLog.trace("Reconnection failed: \(error)")
                if reconnectAttempts < maxReconnectAttempts {
                    attemptReconnect()
                } else {
                    connectionState = .disconnected
                    SteamLog.trace("Max reconnection attempts reached")
                }
            }
        }
    }

}

extension SteamSession: SteamCMSession {}

// MARK: - Data Extensions

import Compression

extension Data {
    /// Decompress gzip data using the Compression framework
    /// `expectedSize` is the sender's declared inflated length (CMsgMulti
    /// size_unzipped). A fixed 10x estimate silently truncated
    /// highly compressible PICS batches; the declared size is used, bounded.
    func gunzip(expectedSize: Int = 0) -> Data? {
        guard count > 10 else { return nil }

        // Check for gzip magic number
        guard self[startIndex] == 0x1f && self[startIndex + 1] == 0x8b else {
            return nil  // Not gzipped
        }

        // Skip the gzip header (RFC 1952: FEXTRA, FNAME, FCOMMENT, FHCRC).
        let bytes = [UInt8](self)
        let flags = bytes[3]
        var pos = 10
        if flags & 0x04 != 0 {
            guard pos + 2 <= bytes.count else { return nil }
            pos += 2 + (Int(bytes[pos]) | Int(bytes[pos + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while pos < bytes.count && bytes[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flags & 0x02 != 0 { pos += 2 }
        guard pos + 8 < bytes.count else { return nil }

        let compressedPayload = Data(bytes[pos..<(bytes.count - 8)]) // Remove header and trailer (CRC32 + size)
        guard compressedPayload.count > 0 else { return nil }

        // Decompress using raw deflate (COMPRESSION_ZLIB)
        let outputSize = expectedSize > 0 && expectedSize <= 256 * 1024 * 1024 ? expectedSize : count * 10
        var outputBuffer = Data(count: outputSize)

        let decompressedSize = compressedPayload.withUnsafeBytes { srcPtr -> Int in
            outputBuffer.withUnsafeMutableBytes { dstPtr -> Int in
                guard let src = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dst = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }

                let result = compression_decode_buffer(
                    dst, outputSize,
                    src, compressedPayload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
                return result > 0 ? result : 0
            }
        }

        guard decompressedSize > 0 else { return nil }
        outputBuffer.count = decompressedSize
        return outputBuffer
    }
}
