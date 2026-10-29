// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Reads the unverified claims of a Steam refresh token (a JWT) locally: the
/// account's SteamID (`sub`) and expiry (`exp`). The server stays the
/// authority; this only lets the client refuse an obviously expired token
/// before using it and report expiry without printing the token.
public struct JWTClaims: Sendable, Equatable {
    public var subject: UInt64?
    public var expiry: Date?
    public var audience: [String]

    public init(token: Secret<String>) throws {
        let parts = token.value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw ClientError.protocolChanged("refresh token is not a three-part JWT") }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.protocolChanged("refresh token payload is not JSON")
        }
        subject = (obj["sub"] as? String).flatMap { UInt64($0) }
        expiry = (obj["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        if let a = obj["aud"] as? [String] { audience = a } else if let a = obj["aud"] as? String { audience = [a] } else { audience = [] }
    }

    public func isExpired(at now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSince(now) < leeway
    }
}
