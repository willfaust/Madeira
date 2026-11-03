// SPDX-License-Identifier: GPL-3.0-or-later
// Stand-ins for the app types GalaxyService.swift uses, for the host tests.
import Foundation
struct GOGSession: Sendable { var refreshToken: String }
enum GOGAPIError: Error { case signedOut }
actor GOGAPI {
    static let clientID = "46899977096215655"
    static let userAgent = "test"
    func validSession() async throws -> GOGSession { throw GOGAPIError.signedOut }
}
