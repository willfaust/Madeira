// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Reduced to the
// message types the owned library and downloads use. The numbers are Valve's
// (steammessages / enums.proto): interface facts of Steam's public protocol.

import Foundation

// MARK: - Connection state

enum SteamConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected       // WebSocket up, not yet logged on
    case authenticated   // logged on
    case reconnecting    // lost the connection, trying again
}

// MARK: - Message types

/// The message types the library and downloads use.
enum EMsg: UInt32 {
    /// Set on the message type of a protobuf-encoded message.
    static let protoMask: UInt32 = 0x80000000

    case multi = 1
    case clientHeartBeat = 703
    case clientHello = 4006
    case clientLogon = 5514
    case clientLogonResponse = 5515
    case clientLogOff = 5516
    case clientLoggedOff = 5517
    case clientLicenseList = 780
    case clientPICSProductInfoRequest = 8903
    case clientPICSProductInfoResponse = 8904
    case clientPICSAccessTokenRequest = 8905
    case clientPICSAccessTokenResponse = 8906
    case clientGetDepotDecryptionKey = 5438
    case clientGetDepotDecryptionKeyResponse = 5439
    case clientCheckAppBetaPassword = 5450
    case clientCheckAppBetaPasswordResponse = 5451
    case clientPICSPrivateBetaRequest = 8907
    case clientPICSPrivateBetaResponse = 8908
    case serviceMethod = 146
    case serviceMethodResponse = 147
    case serviceMethodCallFromClient = 151

    /// The raw value with the protobuf flag set.
    var masked: UInt32 { rawValue | EMsg.protoMask }
}

/// Unified-service methods.
enum SteamServiceMethod: String {
    case getManifestRequestCode = "ContentServerDirectory.GetManifestRequestCode#1"
    case getCDNAuthToken = "ContentServerDirectory.GetCDNAuthToken#1"
    /// The account's own playtime and last-played times.
    case getOwnedGames = "Player.GetOwnedGames#1"
    /// The account's Steam Cloud file list for one app.
    case cloudGetAppFileChangelist = "Cloud.GetAppFileChangelist#1"
    /// Where one cloud file can be downloaded from.
    case cloudClientFileDownload = "Cloud.ClientFileDownload#1"
    /// Uploading an app's changed cloud files: a batch, each file, the end of the batch.
    case cloudBeginAppUploadBatch = "Cloud.BeginAppUploadBatch#1"
    case cloudClientBeginFileUpload = "Cloud.ClientBeginFileUpload#1"
    case cloudClientCommitFileUpload = "Cloud.ClientCommitFileUpload#1"
    case cloudCompleteAppUploadBatch = "Cloud.CompleteAppUploadBatchBlocking#1"
}

// MARK: - Result codes

enum EResult: UInt32 {
    case ok = 1
    case tryAnotherCM = 48   // the server is overloaded; connect to another

    var isSuccess: Bool { self == .ok }
}
