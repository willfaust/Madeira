// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Every failure a store client (Steam, GOG, Epic) or the install engine can
/// report; SteamClientKit calls it `SteamError`. Protocol drift (a field with the wrong
/// wire type, a missing required field, an unknown compression marker) is a
/// typed `protocolChanged`, never a crash. No case carries a secret: token,
/// QR and CDN values are never interpolated into an error.
public enum ClientError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A pinned schema no longer matches what the server sent.
    case protocolChanged(String)
    /// Steam answered with a non-OK EResult.
    case eresult(EResult, context: String)
    case timeout(String)
    case cancelled
    case transport(String)
    case notLoggedOn
    case noCredentials
    case credentialStore(String)
    /// The QR session ended without approval (Steam dropped it: denied or expired).
    case qrSessionEnded(EResult)
    case qrExpired
    /// Steam refused the account name and password (or is throttling sign-ins) before a session began.
    case credentialsRefused(EResult)
    /// A credential sign-in's session ended without approval (denied, expired or superseded).
    case authSessionEnded(EResult)
    /// Unsafe content the client refuses to materialise: path traversal,
    /// symlink escape, oversized or malformed compressed data.
    case unsafeContent(String)
    case verificationFailed(String)
    case unsupported(String)
    case notFound(String)
    case retriesExhausted(String)
    /// Not enough free space for what an install still has to write, plus its
    /// margin: the job pauses with its stage kept.
    case insufficientSpace(needed: UInt64, available: UInt64)

    static func gb(_ b: UInt64) -> String { String(format: "%.2f", Double(b) / 1e9) }

    public var description: String {
        switch self {
        case let .protocolChanged(s): return "protocol changed: \(s)"
        case let .eresult(r, context): return "\(context): EResult \(r)"
        case let .timeout(s): return "timeout: \(s)"
        case .cancelled: return "cancelled"
        case let .transport(s): return "transport: \(s)"
        case .notLoggedOn: return "not logged on"
        case .noCredentials: return "no stored credentials"
        case let .credentialStore(s): return "credential store: \(s)"
        case let .qrSessionEnded(r): return "QR session ended by Steam (EResult \(r)): denied or expired"
        case .qrExpired: return "QR challenge expired locally"
        case let .credentialsRefused(r): return "credentials refused by Steam (EResult \(r))"
        case let .authSessionEnded(r): return "sign-in session ended by Steam (EResult \(r))"
        case let .unsafeContent(s): return "unsafe content rejected: \(s)"
        case let .verificationFailed(s): return "verification failed: \(s)"
        case let .unsupported(s): return "unsupported: \(s)"
        case let .notFound(s): return "not found: \(s)"
        case let .retriesExhausted(s): return "retries exhausted: \(s)"
        case let .insufficientSpace(needed, available):
            return "not enough space: needs \(Self.gb(needed)) GB, \(Self.gb(available)) GB free; paused, staged work kept"
        }
    }
}

/// Pinned subset of EResult (JavaSteam src/main/steamd/.../eresult.steamd @ 433f2ad1).
/// Unknown values are kept as `.other`, so a new code is reported, not trapped.
public enum EResult: Equatable, Hashable, Sendable, CustomStringConvertible {
    case ok, fail, noConnection, invalidPassword, loggedInElsewhere, invalidProtocolVer, invalidParam
    case fileNotFound, busy, invalidState, accessDenied, timeout, serviceUnavailable, notLoggedOn
    case pending, revoked, expired, noMatch, accountDisabled, tryAnotherCM, rateLimitExceeded
    case accountLoginDeniedThrottle, invalidSignature
    case duplicateRequest, accountLogonDenied, invalidLoginAuthCode, twoFactorCodeMismatch
    case other(Int32)

    public init(_ raw: Int32) {
        switch raw {
        case 1: self = .ok
        case 2: self = .fail
        case 3: self = .noConnection
        case 5: self = .invalidPassword
        case 6: self = .loggedInElsewhere
        case 7: self = .invalidProtocolVer
        case 8: self = .invalidParam
        case 9: self = .fileNotFound
        case 10: self = .busy
        case 11: self = .invalidState
        case 15: self = .accessDenied
        case 16: self = .timeout
        case 20: self = .serviceUnavailable
        case 21: self = .notLoggedOn
        case 22: self = .pending
        case 26: self = .revoked
        case 29: self = .duplicateRequest
        case 27: self = .expired
        case 42: self = .noMatch
        case 43: self = .accountDisabled
        case 48: self = .tryAnotherCM
        case 63: self = .accountLogonDenied
        case 65: self = .invalidLoginAuthCode
        case 84: self = .rateLimitExceeded
        case 87: self = .accountLoginDeniedThrottle
        case 88: self = .twoFactorCodeMismatch
        case 121: self = .invalidSignature
        default: self = .other(raw)
        }
    }

    /// Transient results worth a bounded retry on another attempt.
    public var isTransient: Bool {
        switch self {
        case .busy, .timeout, .serviceUnavailable, .tryAnotherCM, .noConnection: return true
        default: return false
        }
    }

    public var description: String { name }

    public var name: String {
        switch self {
        case .ok: return "OK"
        case .fail: return "Fail"
        case .noConnection: return "NoConnection"
        case .invalidPassword: return "InvalidPassword"
        case .loggedInElsewhere: return "LoggedInElsewhere"
        case .invalidProtocolVer: return "InvalidProtocolVer"
        case .invalidParam: return "InvalidParam"
        case .fileNotFound: return "FileNotFound"
        case .busy: return "Busy"
        case .invalidState: return "InvalidState"
        case .accessDenied: return "AccessDenied"
        case .timeout: return "Timeout"
        case .serviceUnavailable: return "ServiceUnavailable"
        case .notLoggedOn: return "NotLoggedOn"
        case .pending: return "Pending"
        case .revoked: return "Revoked"
        case .expired: return "Expired"
        case .noMatch: return "NoMatch"
        case .accountDisabled: return "AccountDisabled"
        case .tryAnotherCM: return "TryAnotherCM"
        case .rateLimitExceeded: return "RateLimitExceeded"
        case .accountLoginDeniedThrottle: return "AccountLoginDeniedThrottle"
        case .invalidSignature: return "InvalidSignature"
        case .duplicateRequest: return "DuplicateRequest"
        case .accountLogonDenied: return "AccountLogonDenied"
        case .invalidLoginAuthCode: return "InvalidLoginAuthCode"
        case .twoFactorCodeMismatch: return "TwoFactorCodeMismatch"
        case let .other(v): return "EResult(\(v))"
        }
    }
}
