// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CoreImage
import UIKit

/// The soft circle of progressive blur under a not-downloaded game's download glyph, baked into the cover's bitmap
/// (the zoomable grid's counterpart of SteamArtworkBlurSpot in SteamGames.swift, which stays the reference).
/// Like that view it stacks three copies of the art, each blurred more and masked to a smaller radial fade, with
/// the same blur radii and fade stops, as fractions of the artwork's shorter side. Baking it once when the cover is
/// prepared (off the main thread) means a card, a zoom stand-in and the landing all show the same image, and no
/// card carries a live blur.
enum LibraryCoverSpot {
    /// (blur radius, fade radius) as fractions of the shorter side, outermost first.
    private static let steps: [(blur: CGFloat, radius: CGFloat)] = [(0.008, 0.55), (0.015, 0.42), (0.025, 0.30)]
    private static let stops: [(location: CGFloat, alpha: CGFloat)] = [(0, 1), (0.35, 0.85), (0.7, 0.35), (1, 0)]
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let masks = NSCache<NSString, CIImage>()

    /// `image` cropped to the card's 2:3 artwork shape (as the card's aspect-fill would show it) with the spot
    /// drawn into it. The image itself when it cannot be processed.
    nonisolated static func baked(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let cropW = min(w, h / 1.5), cropH = cropW * 1.5
        let pixelsW = Int(cropW.rounded(.down)), pixelsH = Int(cropH.rounded(.down))
        guard pixelsW > 8, pixelsH > 8,
              let cropped = cg.cropping(to: CGRect(x: ((w - CGFloat(pixelsW)) / 2).rounded(.down), y: ((h - CGFloat(pixelsH)) / 2).rounded(.down),
                                                   width: CGFloat(pixelsW), height: CGFloat(pixelsH))) else { return image }
        let extent = CGRect(x: 0, y: 0, width: pixelsW, height: pixelsH)
        let side = CGFloat(pixelsW)
        let source = CIImage(cgImage: cropped)
        var result = source
        for step in steps {
            guard let mask = mask(size: extent.size, radius: side * step.radius) else { return image }
            let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: Double(side * step.blur)).cropped(to: extent)
            result = blurred.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask])
        }
        guard let out = context.createCGImage(result, from: extent, format: .RGBA8, colorSpace: cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB()) else { return image }
        return UIImage(cgImage: out)
    }

    private static func mask(size: CGSize, radius: CGFloat) -> CIImage? {
        let width = Int(size.width), height = Int(size.height)
        let name = "\(width)x\(height)@\(radius)" as NSString
        if let known = masks.object(forKey: name) { return known }
        guard let space = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let gradient = CGGradient(colorSpace: space,
                                        colorComponents: stops.flatMap { [$0.alpha, 1] }, locations: stops.map(\.location), count: stops.count)
        else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
        guard let image = ctx.makeImage().map({ CIImage(cgImage: $0) }) else { return nil }
        masks.setObject(image, forKey: name)
        return image
    }
}
