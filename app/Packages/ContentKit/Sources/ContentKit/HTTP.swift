// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bounded HTTPS GET used for the CM directory and the content CDN. Responses
/// are size-capped; transient failures retry a fixed number of times with
/// backoff; cancellation propagates. URLs are never logged unscrubbed.
public struct HTTPClient: Sendable {
    public var maxAttempts = 3
    public var timeout: TimeInterval = 30
    public let session: URLSession
    public let log: Logger

    /// `userAgent`: what the store's own client sends (Steam's by default).
    public init(log: Logger, userAgent: String = "Valve/Steam HTTP Client 1.0") {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        // The installer keeps several chunk requests in flight per CDN host.
        config.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: config)
        self.log = log
    }

    public func get(_ url: URL, maxBytes: Int, label: String) async throws -> [UInt8] {
        try await get(url, headers: [:], maxBytes: maxBytes, label: label)
    }

    /// A GET with extra headers (a store's authorization header, given as a `Secret`
    /// by the caller and never logged: only `label` and the scrubbed URL host are).
    public func get(_ url: URL, headers: [String: Secret<String>], maxBytes: Int, label: String) async throws -> [UInt8] {
        try await send(url, method: "GET", headers: headers, maxBytes: maxBytes, label: label)
    }

    /// Any method, with an optional body (a form for a store's token endpoint, a
    /// `Secret` because it can carry a login code or a refresh token). Besides a GET's
    /// refusals, another method's HTTP 400 is a refusal too (a used or expired code).
    public func send(_ url: URL, method: String, headers: [String: Secret<String>] = [:], body: Secret<[UInt8]>? = nil,
                     maxBytes: Int, label: String) async throws -> [UInt8] {
        var lastError: ClientError = .transport("\(label): no attempt")
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                request.httpMethod = method
                if let body { request.httpBody = Data(body.value) }
                for (k, v) in headers { request.setValue(v.value, forHTTPHeaderField: k) }
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard data.count <= maxBytes else {
                    throw ClientError.unsafeContent("\(label): \(data.count) bytes exceeds cap \(maxBytes)")
                }
                switch status {
                case 200, 204: return [UInt8](data)
                case 400 where method != "GET":
                    throw ClientError.eresult(.accessDenied, context: "\(label): HTTP 400")
                case 401, 403, 404, 410:
                    throw ClientError.eresult(.accessDenied, context: "\(label): HTTP \(status)")
                default:
                    lastError = .transport("\(label): HTTP \(status)")
                }
            } catch let e as ClientError {
                if case .transport = e {} else { throw e }
                lastError = e
            } catch is CancellationError {
                throw ClientError.cancelled
            } catch let e as URLError where e.code == .cancelled {
                throw ClientError.cancelled
            } catch {
                lastError = .transport("\(label): \(type(of: error)) \((error as NSError).code)")
            }
            log.warn("http", "\(label) attempt \(attempt)/\(maxAttempts) failed: \(lastError)")
            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 750_000_000)
            }
        }
        throw ClientError.retriesExhausted(lastError.description)
    }
}
