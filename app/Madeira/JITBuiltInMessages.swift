// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Codable messages shared by Madeira and its JIT helper extension. Each travels as JSON
/// in an extension request's item (userInfo[itemKey]), to the helper and back.
struct MadeiraJITRequest: Codable, Sendable {
    static let itemKey = "madeira-jit-request"

    enum Operation: String, Codable, Sendable {
        case prepare
        case enable
        case resetDDI
        /// ml1310: report what the extension's own process may map (read-only probe).
        case probe
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let scriptBase64: String?

    static func prepare(pairingData: Data) -> MadeiraJITRequest {
        MadeiraJITRequest(operation: .prepare, targetPID: nil,
                          pairingData: pairingData, scriptBase64: nil)
    }

    static func enable(targetPID: Int32, pairingData: Data,
                       scriptBase64: String) -> MadeiraJITRequest {
        MadeiraJITRequest(operation: .enable, targetPID: targetPID,
                          pairingData: pairingData, scriptBase64: scriptBase64)
    }

    static var resetDDI: MadeiraJITRequest {
        MadeiraJITRequest(operation: .resetDDI, targetPID: nil,
                          pairingData: nil, scriptBase64: nil)
    }

    static var probe: MadeiraJITRequest {
        MadeiraJITRequest(operation: .probe, targetPID: nil,
                          pairingData: nil, scriptBase64: nil)
    }

    struct Response: Codable, Sendable {
        static let itemKey = "madeira-jit-response"
        let success: Bool
        let message: String
        let txmPresent: Bool?
    }
}
