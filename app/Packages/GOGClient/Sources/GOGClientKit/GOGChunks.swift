// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// GOG's chunks over its secure links: one signed, expiring URL per product
/// (a chunk's `group`), fetched when first needed and again before it expires
/// or when the CDN refuses it; the endpoints by priority, a fallback after
/// repeated failures. Each chunk is checked: md5 of the zlib bytes, then the
/// inflated size and md5. GOG's redistributables (`dependencies`) come from one
/// open link instead, which needs no sign-in (decision 0090).
public actor GOGChunkSource: ContentChunkSource {
    struct Endpoint: Sendable {
        var format: String
        var parameters: [String: String]
        var priority: Int
        var fallbackOnly: Bool
        var expires: Date?
    }

    let session: GOGSession
    let log: Logger
    /// The chunks are GOG's redistributables': the open link, not a product's secure link.
    let dependencies: Bool
    private var links: [UInt32: [Endpoint]] = [:]
    private var failures: [String: Int] = [:]
    public var attempts = 4

    public init(session: GOGSession, log: Logger, dependencies: Bool = false) {
        self.session = session
        self.log = log
        self.dependencies = dependencies
    }

    public func chunk(_ c: ContentChunk) async throws -> [UInt8] {
        guard let path = c.locator, GOGContent.isHash(path) else { throw ClientError.unsafeContent("GOG chunk without a name") }
        var last: Error = ClientError.notFound("chunk")
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            _ = attempt
            let eps = try await endpoints(c.group, renew: false)
            let ordered = eps.filter { !$0.fallbackOnly && (failures[$0.format] ?? 0) < 4 } + eps.filter { $0.fallbackOnly }
            guard let ep = ordered.first else { throw ClientError.retriesExhausted("every GOG CDN endpoint failed") }
            let url = try Self.url(ep, chunk: path)
            do {
                let body = try await session.plain(url, maxBytes: Int(c.compressedSize) + 1024, label: "GOG chunk")
                guard body.count == Int(c.compressedSize), MD5.hash(body) == GOGContent.hex(path) else {
                    throw ClientError.verificationFailed("GOG chunk \(path.prefix(12)) does not match its compressed md5")
                }
                let plain = try Zlib.decompress(body, limit: Int(c.size))
                guard c.matches(plain) else { throw ClientError.verificationFailed("GOG chunk \(path.prefix(12)) does not match its md5") }
                failures[ep.format] = 0
                return plain
            } catch ClientError.cancelled {
                throw ClientError.cancelled
            } catch {
                failures[ep.format, default: 0] += 1
                log.warn("gog", "chunk \(path.prefix(12)) from \(url.host ?? "?") failed: \(error)")
                last = error
                if case ClientError.eresult(.accessDenied, _) = error { links[c.group] = nil }
            }
        }
        throw last
    }

    private func endpoints(_ product: UInt32, renew: Bool) async throws -> [Endpoint] {
        if !renew, let have = links[product], have.allSatisfy({ ($0.expires ?? .distantFuture).timeIntervalSinceNow > 120 }) {
            return have
        }
        let eps: [Endpoint]
        if dependencies {
            eps = try Self.parseLink(try await session.plain(GOGDependencies.openLinkURL, maxBytes: 1 << 20, label: "GOG open link"))
        } else {
            let url = URL(string: "https://content-system.gog.com/products/\(product)/secure_link?generation=2&_version=2&path=/")!
            eps = try Self.parseLink(try await session.authorized(url, maxBytes: 1 << 20, label: "GOG secure link"))
        }
        guard !eps.isEmpty else { throw ClientError.notFound("GOG gave no CDN endpoint for \(product)") }
        links[product] = eps
        return eps
    }

    static func parseLink(_ body: [UInt8]) throws -> [Endpoint] {
        guard let o = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any], let urls = o["urls"] as? [[String: Any]] else {
            throw ClientError.protocolChanged("GOG secure link: unexpected reply")
        }
        return urls.compactMap { u -> Endpoint? in
            guard let format = u["url_format"] as? String, let params = u["parameters"] as? [String: Any],
                  (u["supports_generation"] as? [Int])?.contains(2) ?? true else { return nil }
            var p: [String: String] = [:]
            for (k, v) in params { p[k] = "\(v)" }
            let exp = (params["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                ?? (params["expires_at"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }
            return Endpoint(format: format, parameters: p, priority: u["priority"] as? Int ?? 0,
                            fallbackOnly: u["fallback_only"] as? Bool ?? false, expires: exp)
        }.sorted { $0.priority > $1.priority }
    }

    /// `{base_url}/token=…{path}` with the chunk's `/aa/bb/<md5>` after the link's path; an
    /// open link's format (no `{path}`) is the store's URL, and the chunk's path follows it.
    static func url(_ ep: Endpoint, chunk md5: String) throws -> URL {
        var p = ep.parameters
        p["path"] = (p["path"] ?? "") + "/\(md5.prefix(2))/\(md5.dropFirst(2).prefix(2))/\(md5)"
        var s = ep.format.contains("{path}") ? ep.format : ep.format + "{path}"
        for (k, v) in p { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        guard !s.contains("{"), let url = URL(string: s), url.scheme == "https" else {
            throw ClientError.protocolChanged("GOG secure link: a URL format this client cannot fill")
        }
        return url
    }
}
