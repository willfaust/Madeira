// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// An owned GOG game, as the library lists it.
public struct GOGGame: Codable, Equatable, Sendable, Identifiable {
    /// The product ID, in decimal.
    public var id: String
    public var title: String
    /// `//images-…/<hash>`: the art base, without size suffix or scheme.
    public var image: String?
    public var windows: Bool
    public var dlcCount: Int?

    public init(id: String, title: String, image: String?, windows: Bool, dlcCount: Int? = nil) {
        self.id = id
        self.title = title
        self.image = image
        self.windows = windows
        self.dlcCount = dlcCount
    }

    /// The art at one of GOG's sizes (measured 2026-10-06): `_800` 800×370 (a tile),
    /// `_bg_crop_1920x655` (a page backdrop), `_1600` 1600×740; `_glx_logo` is only 100×60.
    public func art(_ suffix: String) -> URL? {
        guard let image, !image.isEmpty else { return nil }
        let base = image.hasPrefix("//") ? "https:" + image : image
        return URL(string: base + suffix + ".jpg")
    }
}

public enum GOGLibrary {
    /// Every owned game that runs on Windows, page by page, by title.
    public static func owned(_ session: GOGSession) async throws -> [GOGGame] {
        var games: [GOGGame] = []
        var page = 1, pages = 1
        repeat {
            let url = URL(string: "https://embed.gog.com/account/getFilteredProducts?mediaType=1&page=\(page)")!
            let body = try await session.authorized(url, maxBytes: 8 << 20, label: "GOG library page \(page)")
            let p = try parse(body)
            games += p.games
            pages = p.pages
            page += 1
        } while page <= pages && page <= 200
        return games.filter(\.windows).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func parse(_ body: [UInt8]) throws -> (games: [GOGGame], pages: Int) {
        struct Page: Decodable {
            struct Product: Decodable {
                struct Works: Decodable { var Windows: Bool? }
                var id: Int
                var title: String
                var image: String?
                var worksOn: Works?
                var dlcCount: Int?
            }
            var products: [Product]
            var totalPages: Int?
        }
        guard let p = try? JSONDecoder().decode(Page.self, from: Data(body)) else {
            throw ClientError.protocolChanged("GOG library: unexpected reply")
        }
        return (p.products.map { GOGGame(id: String($0.id), title: $0.title, image: $0.image, windows: $0.worksOn?.Windows ?? false,
                                         dlcCount: $0.dlcCount) }, max(1, p.totalPages ?? 1))
    }
}
