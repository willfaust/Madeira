// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A web page a running game asked to open (decision 0064): what Playport's URL
/// opener handed the host, sorted into what the web sheet does with it.
public struct UrlOpenRequest: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Epic's device sign-in page (`https://www.epicgames.com/activate?userCode=…`):
        /// an Epic game's sheet opens it signed in to Epic, with no confirm card.
        case epicActivation = "epic-activation"
        /// Any other http or https page: opened unsigned, after a confirm card.
        case web
    }

    /// The longest URL the opener passes (url_opener_protocol.h, less its NUL).
    public static let maxBytes = 2047

    public let url: URL
    public let kind: Kind
    /// The host only, as the sheet's bar and the log show it.
    public let host: String
    /// Host and path, never the query or fragment: what the log may show.
    public var logLabel: String { host + (url.path.isEmpty ? "/" : url.path) }

    /// The request for `string`, or nil when it is refused: not http or https,
    /// no host, a user name or password in it, or longer than `maxBytes`.
    public static func classify(_ string: String) -> UrlOpenRequest? {
        guard !string.isEmpty, string.utf8.count <= maxBytes,
              let c = URLComponents(string: string), let url = c.url,
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil else { return nil }
        let activation = scheme == "https" && host == "www.epicgames.com" && c.path == "/activate"
            && c.port == nil && (c.queryItems ?? []).contains { $0.name == "userCode" && !($0.value ?? "").isEmpty }
        return UrlOpenRequest(url: url, kind: activation ? .epicActivation : .web, host: host)
    }
}

extension UrlOpenRequest {
    /// Epic's web sign-in with a one-time exchange code, which then goes on to this
    /// page: `https://www.epicgames.com/id/exchange?exchangeCode=…&redirectUrl=…`
    /// (the form measured on the workstation; only it signs in the `/id` session the
    /// activate page reads). Both values are percent-encoded whole.
    public func epicSignInURL(exchangeCode: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let code = exchangeCode.addingPercentEncoding(withAllowedCharacters: allowed),
              let page = url.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://www.epicgames.com/id/exchange?exchangeCode=\(code)&redirectUrl=\(page)")
    }
}

/// How often a game may open a page (decision 0064): one sheet at a time, at
/// least `spacing` seconds between opens, at most `perPlay` in one play.
public struct UrlOpenRate: Sendable {
    public enum Refusal: String, Equatable, Sendable {
        case sheetUp = "a page is already up"
        case tooSoon = "too soon after the last"
        case playLimit = "the play's limit reached"
    }

    public let spacing: TimeInterval
    public let perPlay: Int
    public private(set) var opened = 0
    private var last: Date?

    public init(spacing: TimeInterval = 5, perPlay: Int = 10) {
        self.spacing = spacing
        self.perPlay = perPlay
    }

    /// Takes one open at `now` when the rules allow it; nil when taken, else why not.
    public mutating func take(at now: Date, sheetUp: Bool) -> Refusal? {
        if sheetUp { return .sheetUp }
        if opened >= perPlay { return .playLimit }
        if let last, now.timeIntervalSince(last) < spacing { return .tooSoon }
        opened += 1
        last = now
        return nil
    }
}
