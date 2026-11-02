// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).
// Connection recovery adapted from kuscholar/iDeck; see docs/STEAM_LIBRARY.md.

import Foundation

// MARK: - WebSocket Delegate

/// Logs WebSocket lifecycle events: protocol negotiation, server-initiated close.
/// URLSession calls these on its internal delegate queue.
private final class SteamWebSocketDelegate: NSObject, URLSessionWebSocketDelegate,
    URLSessionTaskDelegate, @unchecked Sendable {

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // This is the ground truth — what protocol the server actually agreed to.
        // If nil, the server did not echo "steamdataport" in its 101 response.
        SteamLog.trace("WS handshake complete — server protocol: \(`protocol` ?? "(none, server did not echo)")")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        SteamLog.trace("WS server closed — code: \(closeCode.rawValue) reason: \"\(reasonStr)\"")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            SteamLog.trace("WS task completed with error: \(SteamCMTransportPolicy.sanitized(error))")
        }
    }
}

// MARK: - SteamConnection

/// WebSocket transport to a Steam CM server (wss://).
/// TLS handles all encryption — no ChannelEncrypt handshake required.
/// Each binary WebSocket frame is exactly one complete Steam protocol message.
actor SteamConnection {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let wsDelegate = SteamWebSocketDelegate()
    private let serverList = CMServerList()
    private var currentEndpoint: String?
    private var activeConnect: UUID?
    private var messageHandler: ((Data) -> Void)?
    private var disconnectHandler: ((Error?) -> Void)?

    var isConnected: Bool {
        webSocketTask?.state == .running
    }

    // MARK: - Connect

    func connect() async throws {
        disconnect()
        let generation = UUID()
        activeConnect = generation
        var tried = Set<String>()
        var lastFailure: Error?
        for attempt in 1...3 {
            try Task.checkCancellation()
            guard activeConnect == generation else { throw CancellationError() }
            let server: CMServerList.CMServer
            do { server = try await serverList.getServer(excluding: tried) }
            catch {
                try Task.checkCancellation()
                guard activeConnect == generation else { throw CancellationError() }
                throw lastFailure ?? error
            }
            try Task.checkCancellation()
            guard activeConnect == generation else { throw CancellationError() }
            tried.insert(server.endpoint)
            do {
                try await connect(to: server)
                try Task.checkCancellation()
                guard activeConnect == generation else { throw CancellationError() }
                await serverList.markSuccess(endpoint: server.endpoint)
                try Task.checkCancellation()
                guard activeConnect == generation else { throw CancellationError() }
                guard let task = webSocketTask else { throw CancellationError() }
                scheduleReceive(task)
                SteamLog.trace("WebSocket connected — ready for protocol messages")
                return
            } catch {
                guard activeConnect == generation else { throw CancellationError() }
                clearTransport()
                if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled && (error as NSError).domain == NSURLErrorDomain {
                    throw CancellationError()
                }
                await serverList.markFailed(endpoint: server.endpoint)
                guard activeConnect == generation else { throw CancellationError() }
                let failure = SteamCMTransportPolicy.sanitized(error)
                SteamLog.event("[steam-cm-transport] attempt=\(attempt) reason=\(failure)")
                lastFailure = failure
                guard attempt < 3, SteamCMTransportPolicy.canTryAnotherServer(error) else { throw failure }
            }
        }
        throw lastFailure ?? SteamError.noServersAvailable
    }

    private func connect(to server: CMServerList.CMServer) async throws {
        currentEndpoint = server.endpoint
        SteamLog.trace("Connecting to CM: \(server.url)")

        // Build a custom URLSession with our delegate so we can observe the WS handshake.
        // The delegate tells us what protocol the server actually negotiated.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        // Delegate queue nil → URLSession creates an internal serial queue (correct for our actor model)
        let session = URLSession(configuration: config, delegate: wsDelegate, delegateQueue: nil)
        urlSession = session

        // IMPORTANT: Sec-WebSocket-Protocol is a CONTROLLED HEADER in URLSessionWebSocketTask.
        // Setting it via request.setValue is silently ignored by URLSession.
        // The only supported way is the `protocols` parameter below.
        // Without "steamdataport", Steam CM servers accept the WebSocket but do not
        // initialize a Steam session handler, so they silently ignore all messages.
        let task = session.webSocketTask(with: server.url, protocols: ["steamdataport"])
        webSocketTask = task
        task.resume()

        // Verify the connection completed (WebSocket handshake + ping round-trip)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    // MARK: - Receive

    /// Continuously receive WebSocket binary frames.
    /// Each frame is one complete Steam protocol message — no TCP length/magic framing.
    nonisolated private func scheduleReceive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { await self?.received(result, from: task) }
        }
    }

    private func received(_ result: Result<URLSessionWebSocketTask.Message, Error>, from task: URLSessionWebSocketTask) {
        guard webSocketTask === task else { return }
        switch result {
        case .success(let message):
            switch message {
            case .data(let data): messageHandler?(data)
            case .string(let text): SteamLog.trace("unexpected text frame (\(text.utf8.count) bytes)")
            @unknown default: break
            }
            scheduleReceive(task)
        case .failure(let error):
            // POSIX 57 (socket not connected) is a normal disconnect.
            let failure = error as NSError
            let isNormalClose = failure.domain == NSPOSIXErrorDomain && failure.code == 57
            handleDisconnect(task: task, error: isNormalClose ? nil : SteamCMTransportPolicy.sanitized(error))
        }
    }

    // MARK: - Send

    /// Send raw bytes as a binary WebSocket frame.
    /// Wire format: [4B masked EMsg][4B headerLen][protobuf header][body] — no TCP framing wrapper.
    func send(_ data: Data) async throws {
        guard let task = webSocketTask, task.state == .running else {
            throw SteamError.disconnected
        }
        try await task.send(.data(data))
    }

    func sendMessage(eMsg: EMsg, header: CMsgProtoBufHeader, body: Data) async throws {
        let encoded = SteamMessageCodec.encode(eMsg: eMsg, header: header, body: body)
        try await send(encoded)
    }

    /// WebSocket-level ping (transport keepalive).
    /// Steam protocol heartbeat is handled by SteamSession at the message level.
    func sendPing() async {
        webSocketTask?.sendPing { _ in }
    }

    // MARK: - Handlers

    func setMessageHandler(_ handler: @escaping (Data) -> Void) {
        self.messageHandler = handler
    }

    func setDisconnectHandler(_ handler: @escaping (Error?) -> Void) {
        self.disconnectHandler = handler
    }

    private func handleDisconnect(task: URLSessionWebSocketTask, error: Error?) {
        // Only fire disconnect once per connection — clear webSocketTask to prevent repeat
        guard webSocketTask === task else { return }
        let endpoint = currentEndpoint
        clearTransport()
        currentEndpoint = endpoint // reconnect() must still mark the disconnected CM as failed
        if let error {
            SteamLog.trace("Connection lost: \(error.localizedDescription)")
        } else {
            SteamLog.trace("Connection closed cleanly")
        }
        disconnectHandler?(error)
    }

    // MARK: - Disconnect

    private func clearTransport() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        currentEndpoint = nil
    }

    func disconnect() {
        activeConnect = nil
        clearTransport()
        SteamLog.trace("Disconnected")
    }

    func reconnect() async throws {
        if let endpoint = currentEndpoint {
            await serverList.markFailed(endpoint: endpoint)
        }
        disconnect()
        try await connect()
    }
}
