// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
import Foundation
import SwiftUI
import UIKit

// App model boundaries only; compile the actual cache, SwiftUI artwork/blur and Core Image spot baker against UIKit.
enum LibraryGridArm { static let releaseMemory = Notification.Name("fixtureReleaseMemory") }
enum LibraryGridGeometry { static let maxCard: CGFloat = 240; static let cardPadding: CGFloat = 12 }
enum LibraryGridNextFrame { static func run(_ action: @escaping () -> Void) { DispatchQueue.main.async(execute: action) } }
@MainActor final class SteamOwnedLibrary: ObservableObject {
    static let shared = SteamOwnedLibrary()
    var ownedRevision = 0
    func game(_ id: Int) -> Int? { nil }
}
enum SteamGamesRules { static func artwork(appID: Int, owned: (Int) -> Int?) -> [URL] { [] } }
struct LibraryEntry { var coverFile: String?; var steamID: Int?; var steamAppID: Int?; var desktop: Bool? }
enum LibraryModel { static let documents = URL(fileURLWithPath: "/fixture") }
enum SteamCatalog { static func hero(_ id: Int) -> URL? { nil } }
enum AmbientArt { case steam(Int), library(LibraryEntry) }
struct AmbientGlowItem {
    let id: String; let art: AmbientArt; let seed: Int; let dimmed: Bool; let pressed: Bool
}
struct AmbientGlow: View {
    let image: Image; let size: CGSize; let seed: Int; let dimmed: Bool; let pressed: Bool
    var body: some View { image }
}
