// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers

// Host adapters only. Production scheduling, disk I/O, NSCache and ImageIO decoding run unchanged.
final class UIImage: @unchecked Sendable {
    private let bitmap: CGImage
    var cgImage: CGImage? { bitmap }
    let scale: CGFloat = 1
    var size: CGSize { CGSize(width: bitmap.width, height: bitmap.height) }
    init(cgImage: CGImage) { self.bitmap = cgImage }
    func jpegData(compressionQuality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, bitmap, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        CGImageDestinationFinalize(output)
        return data as Data
    }
}
enum LibraryGridArm { static let releaseMemory = Notification.Name("fixtureReleaseMemory") }
enum LibraryGridGeometry {
    static let maxCard: CGFloat = 240; static let cardPadding: CGFloat = 12
    static func artworkRect(cardWidth: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: cardWidth, height: cardWidth * 1.5) }
    static func coverPixels(cardWidth: CGFloat, scale: CGFloat) -> Int { 96 }
}
enum LibraryGridNextFrame {
    static func run(_ action: @escaping () -> Void) { DispatchQueue.main.async(execute: action) }
}
enum Gate {
    static let lock = NSLock()
    static var blocked = false
    static let semaphore = DispatchSemaphore(value: 0)
    static func wait() {
        lock.lock(); let shouldWait = blocked; lock.unlock()
        if shouldWait { semaphore.wait() }
    }
    static func close() {
        while semaphore.wait(timeout: .now()) == .success {}
        lock.lock(); blocked = true; lock.unlock()
    }
    static func open() { lock.lock(); blocked = false; lock.unlock(); for _ in 0..<12 { semaphore.signal() } }
}
final class Fixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var counts: [String: Int] = [:]
    private static var offline = false
    static var brokenFirst = false
    private static var corruptFirst = false
    private static var held = false
    private static var holdSecond = false
    static var pending: [Fixture] = []
    static func configure(offline: Bool? = nil, corruptFirst: Bool? = nil, held: Bool? = nil, holdSecond: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let offline { self.offline = offline }
        if let corruptFirst { self.corruptFirst = corruptFirst }
        if let held { self.held = held }
        if let holdSecond { self.holdSecond = holdSecond }
    }
    static let bytes: Data = {
        let width = 300, height = 450
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var random: UInt32 = 42
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<3 {
                    random = random &* 1664525 &+ 1013904223
                    pixels[(y * width + x) * 4 + c] = UInt8((Int(random >> 24) + x / 3 + y / 4 + c * 30) / 3)
                }
                pixels[(y * width + x) * 4 + 3] = 255
            }
        }
        let image = UIImage(cgImage: context.makeImage()!)
        // Deterministic textured artwork, 300x450 and approximately 56 KiB as sampled Steam capsules.
        var best = image.jpegData(compressionQuality: 0.7)!
        for step in 1...19 {
            let candidate = image.jpegData(compressionQuality: CGFloat(step) / 20)!
            if abs(candidate.count - 56 * 1024) < abs(best.count - 56 * 1024) { best = candidate }
        }
        return best
    }()
    static func bake(_ image: UIImage) -> UIImage { Gate.wait(); return LibraryCoverSpot.baked(image) }
    static var jobs = 0
    static func startedJob() { lock.lock(); jobs += 1; lock.unlock() }
    static func finishedJob() { lock.lock(); jobs -= 1; lock.unlock() }
    static var liveJobs: Int { lock.lock(); defer { lock.unlock() }; return jobs }
    static var trimScans = 0
    static var writtenBytes = 0
    static func wrote(_ bytes: Int) { lock.lock(); writtenBytes += bytes; lock.unlock() }
    static var diskStats: (scans: Int, written: Int) { lock.lock(); defer { lock.unlock() }; return (trimScans, writtenBytes) }
    static func trimmed() { lock.lock(); trimScans += 1; lock.unlock() }
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Fixture.self]
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.counts[request.url!.path, default: 0] += 1
        if Self.held || (Self.holdSecond && request.url!.lastPathComponent == "second") { Self.pending.append(self); Self.lock.unlock(); return }
        Self.lock.unlock()
        respond()
    }
    func respond() {
        Self.lock.lock()
        let offline = Self.offline, broken = Self.brokenFirst, corrupt = Self.corruptFirst
        Self.lock.unlock()
        if offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let first = request.url!.lastPathComponent == "first"
        let response = HTTPURLResponse(url: request.url!, statusCode: first && broken ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: first && corrupt ? Data("invalid image".utf8) : Self.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static var total: Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }
    static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path, default: 0] }
    static func release() {
        lock.lock(); held = false; let items = pending; pending = []; lock.unlock()
        for item in items { item.respond() }
    }
}

@MainActor final class SteamOwnedLibrary {
    static let shared = SteamOwnedLibrary()
    var ownedRevision = 0
    func game(_ id: Int) -> Int? { nil }
}
enum SteamGamesRules { static func artwork(appID: Int, owned: (Int) -> Int?) -> [URL] { [] } }
struct LibraryEntry { var coverFile: String?; var steamID: Int?; var steamAppID: Int? }
enum LibraryModel { static var documents: URL { LibraryCoverCache.folder.deletingLastPathComponent().appendingPathComponent("documents") } }
