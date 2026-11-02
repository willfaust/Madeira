// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). The sign-in
// errors are the ones sign-in raises; the connection, library and download
// errors belong to the owned library and downloads (docs/STEAM_LIBRARY.md).
// Transport error policy adapted from kuscholar/iDeck; see docs/STEAM_LIBRARY.md.

import Foundation

/// Errors raised by the Steam sign-in, library and download code.
enum SteamError: LocalizedError, Equatable {
    /// Logon EResults that mean the stored sign-in token itself is unusable:
    /// InvalidPassword, AccessDenied, AccountNotFound, Revoked, Expired,
    /// InvalidSignature.
    static let signInExpiredCodes: Set<UInt32> = [5, 15, 18, 26, 27, 94]

    // Sign-in
    case authenticationFailed(String)
    case invalidCredentials
    case rateLimited
    case accountDisabled
    case rsaKeyFetchFailed
    case qrCodeExpired
    case authSessionExpired
    case protobufError(String)

    // Connection
    case noServersAvailable
    case connectionFailed(String)
    /// Safe transport identity only; no URL, headers or credential-bearing error payload.
    case transportFailed(domain: String, code: Int)
    case connectionTimeout
    case disconnected
    /// The CM refused the logon with this EResult. Lets callers tell a revoked
    /// or expired sign-in from a transient network failure.
    case logonDenied(UInt32)
    case invalidMessage

    // Library
    case appInfoNotFound(UInt32)
    case depotNotFound(UInt32)

    // Content
    case manifestFetchFailed(String)
    case chunkDownloadFailed(String)
    /// A content server answered with this HTTP status.
    case contentHTTP(Int)
    /// Every content server refused a depot's file list (HTTP 401 or 403),
    /// also with fresh authorization and a fresh request code.
    case contentRefused(Int)
    case decryptionFailed(String)
    case decompressionFailed
    /// A downloaded chunk could not be decoded; the value names the encoding
    /// (vzip, vzstd, zip) or its leading bytes.
    case chunkDecodeFailed(String)
    case checksumMismatch
    case depotKeyNotFound(UInt32)
    case insufficientDiskSpace(needed: UInt64, available: UInt64)
    /// The chosen branch is password-protected and Steam did not accept the
    /// kept beta code for it (or none is kept).
    case betaCodeNeeded(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason):
            return reason
        case .invalidCredentials:
            return "The account name or password is incorrect."
        case .rateLimited:
            return "Too many attempts. Please try again later."
        case .accountDisabled:
            return "This Steam account has been disabled"
        case .rsaKeyFetchFailed:
            return "Failed to fetch RSA public key for password encryption"
        case .qrCodeExpired:
            return "QR code has expired. Please try again."
        case .authSessionExpired:
            return "The sign-in request expired. Start again."
        case .protobufError(let detail):
            return "Protocol buffer error: \(detail)"
        case .noServersAvailable:
            return "No Steam servers are available."
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .transportFailed(let domain, let code):
            if domain == NSURLErrorDomain {
                switch URLError.Code(rawValue: code) {
                case .secureConnectionFailed:
                    return "Steam could not make a secure connection (\(code)). Check your network or VPN and try again."
                case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                    return "Steam could not verify the server certificate (\(code)). Check your device's date and network settings."
                case .clientCertificateRejected, .clientCertificateRequired:
                    return "Steam requested or rejected a client certificate (\(code)). Check your network or VPN settings."
                default: break
                }
            }
            return "Steam connection failed (\(domain), \(code))."
        case .connectionTimeout:
            return "Steam did not respond in time. Check your internet connection and try again."
        case .disconnected:
            return "Disconnected from Steam."
        case .logonDenied(let code):
            return SteamError.signInExpiredCodes.contains(code)
                ? "Your Steam sign-in is no longer valid. Sign in again."
                : "Steam refused the connection (code \(code)). Try again later."
        case .invalidMessage:
            return "Received an invalid message from Steam."
        case .appInfoNotFound(let appID):
            return "Steam has no information for app \(appID)."
        case .depotNotFound:
            return "Steam has no Windows download for this game."
        case .manifestFetchFailed(let reason):
            return "Could not read the game's file list: \(reason)"
        case .chunkDownloadFailed(let reason):
            return "Download failed: \(reason)"
        case .contentHTTP(let status):
            return "Download failed: Content server returned HTTP \(status)."
        case .contentRefused(let status):
            return "Steam's download servers would not hand out this game's file list (HTTP \(status)), even after Madeira asked Steam for new download permission. Wait a few minutes and tap Try again; downloaded parts are kept. If it keeps happening, check that the game still shows in your Steam library and send Madeira's log."
        case .decryptionFailed(let reason):
            return "Decryption failed: \(reason)"
        case .decompressionFailed:
            return "Failed to decompress downloaded data."
        case .chunkDecodeFailed(let format):
            return "Part of the game could not be decoded (\(format)). Try again; downloaded parts are kept."
        case .checksumMismatch:
            return "A downloaded part failed its checksum."
        case .depotKeyNotFound:
            return "Steam did not allow this account to download the game's files. Check that the account owns it."
        case .insufficientDiskSpace(let needed, let available):
            return String(format: "Not enough free space: the download needs %.1f GB and %.1f GB is available.",
                          Double(needed) / 1_000_000_000, Double(available) / 1_000_000_000)
        case .betaCodeNeeded(let branch):
            return "The \(branch) version needs a beta code Steam accepts. Enter it under Game details › Steam › Version, or pick another version."
        }
    }
}

/// Where a Steam Guard code comes from.
enum SteamGuardType: String, Codable {
    case email = "email"
    case device = "device"          // Steam Mobile Authenticator
}

/// An endpoint/route negotiation failure can be isolated by trying another CM.
/// Explicit trust failures and cancellation must not be hidden by retries.
enum SteamCMTransportPolicy {
    static func canTryAnotherServer(_ error: Error) -> Bool {
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain else { return false }
        switch URLError.Code(rawValue: failure.code) {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .secureConnectionFailed: return true
        default: return false
        }
    }
    static func sanitized(_ error: Error) -> SteamError {
        let failure = error as NSError
        let domain = [NSURLErrorDomain, NSPOSIXErrorDomain].contains(failure.domain) ? failure.domain : "other"
        return .transportFailed(domain: domain, code: failure.code)
    }
}
