// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CoreGraphics
import Foundation
import os
import UIKit

// The zoomable grid's sizes and geometry (docs/zoomable-grid.md). The grid's size is a LEVEL: a column count. A page width has a
// few levels (the column counts whose card is between minCard and maxCard wide, at most maxStops), and what is stored is a
// POSITION on them (0 = the biggest cards), so a rotation or a window resize lands on the nearest level of the new width.

// MARK: - Geometry (Foundation/CoreGraphics only; tests/host/check-library-zoom.py compiles this part)

enum LibraryGridGeometry {
    static let padding: CGFloat = 16
    static let maxPageWidth: CGFloat = 1100
    static let blockSpacing: CGFloat = 24
    static let sectionSpacing: CGFloat = 14
    /// Between columns and between rows. Rows keep LazyVGrid's 18; columns are a fixed 20, so the cards and gaps fill the width
    /// exactly at every level and the levels share one lattice in a zoom.
    static let columnGap: CGFloat = 20
    static let rowGap: CGFloat = 18
    /// The narrowest and widest card a level may have, and at most this many levels.
    static let minCard: CGFloat = 72
    static let maxCard: CGFloat = 220
    static let maxStops = 5
    static let minimumColumns = 2
    static let cardsTarget: CGFloat = 154
    static let compactTarget: CGFloat = 110
    static let cardPadding: CGFloat = 4
    static let labelSpacing: CGFloat = 6

    static func contentWidth(viewport: CGFloat) -> CGFloat {
        max(1, min(viewport, maxPageWidth) - 2 * padding)
    }

    static func cardWidth(content: CGFloat, columns: Int) -> CGFloat {
        let n = CGFloat(max(1, columns))
        return max(1, (content - (n - 1) * columnGap) / n)
    }

    static func coverHeight(cardWidth w: CGFloat) -> CGFloat {
        cardPadding + max(0, w - 2 * cardPadding) * 1.5
    }

    static func artworkRect(cardWidth w: CGFloat) -> CGRect {
        CGRect(x: cardPadding, y: cardPadding, width: max(0, w - 2 * cardPadding), height: max(0, w - 2 * cardPadding) * 1.5)
    }

    /// The pixel width a card's cover is asked from LibraryCoverCache for: one function for the cell and the prefetch, so the prefetched bucket is the one the cell asks for.
    static func coverPixels(cardWidth w: CGFloat, scale: CGFloat) -> Int {
        Int((artworkRect(cardWidth: w).width * scale).rounded(.up))
    }

    /// The column counts of `content`: every count whose card lies in [minCard, maxCard], thinned evenly to at most `maxStops` with both ends kept; fewest columns first.
    static func stops(content: CGFloat) -> [Int] {
        var counts: [Int] = []
        var n = minimumColumns
        while n < 100 {
            let w = cardWidth(content: content, columns: n)
            if w < minCard - 1e-6 { break }
            if w <= maxCard + 1e-6 { counts.append(n) }
            n += 1
        }
        guard !counts.isEmpty else { return [minimumColumns] }
        guard counts.count > maxStops else { return counts }
        let last = Double(counts.count - 1), steps = Double(maxStops - 1)
        return (0..<maxStops).map { counts[Int((Double($0) * last / steps).rounded())] }
    }

    static func stopIndex(position: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return min(count - 1, max(0, Int((min(1, max(0, position)) * Double(count - 1) - 1e-9).rounded())))
    }

    static func position(index: Int, count: Int) -> Double {
        count > 1 ? Double(index) / Double(count - 1) : 0
    }

    static func nearestStop(to target: CGFloat, content: CGFloat) -> Int {
        let stops = stops(content: content)
        var best = 0
        for i in stops.indices {
            let d = abs(log(cardWidth(content: content, columns: stops[i]) / target))
            let b = abs(log(cardWidth(content: content, columns: stops[best]) / target))
            if d < b - 1e-9 { best = i }
        }
        return best
    }
}

/// The page's frames at one level: a pure function of its blocks, so the live layout and every level the zoom reads come from the same rule.
enum LibraryGridLayoutModel {
    enum Block {
        case fixed(height: CGFloat, spacing: CGFloat)
        case grid(bands: [CGFloat], spacing: CGFloat)
    }

    struct Result: Equatable {
        var frames: [CGRect] = []
        var contentHeight: CGFloat = 0
        var ranges: [Range<Int>] = []
        var rowsAbove: [Int] = []
        var rows: [Int] = []
        var cardWidth: CGFloat = 0
    }

    static func layout(_ blocks: [Block], columns: Int, content: CGFloat, originX: CGFloat) -> Result {
        let g = LibraryGridGeometry.self
        let w = g.cardWidth(content: content, columns: columns)
        let cover = g.coverHeight(cardWidth: w)
        var result = Result()
        result.cardWidth = w
        var y = g.padding
        var rowsSoFar = 0
        for block in blocks {
            let start = result.frames.count
            result.rowsAbove.append(rowsSoFar)
            switch block {
            case .fixed(let height, let spacing):
                y += spacing
                result.frames.append(CGRect(x: originX, y: y, width: content, height: height))
                y += height
                result.rows.append(0)
            case .grid(let bands, let spacing):
                y += spacing
                var i = 0
                var rows = 0
                while i < bands.count {
                    let end = min(bands.count, i + columns)
                    let band = bands[i..<end].max() ?? 0
                    let height = cover + band
                    for k in i..<end {
                        result.frames.append(CGRect(x: originX + CGFloat(k - i) * (w + g.columnGap), y: y, width: w, height: height))
                    }
                    y += height
                    rows += 1
                    i = end
                    if i < bands.count { y += g.rowGap }
                }
                rowsSoFar += rows
                result.rows.append(rows)
            }
            result.ranges.append(start..<result.frames.count)
        }
        result.contentHeight = y + g.padding
        return result
    }
}

/// The grid's stored size: a position on the page's levels (0 = biggest cards), or nil for the picker's own choice (Cards or Compact cards).
enum LibraryGridSize {
    static let key = "madeiraLibraryGridPosition"

    static func columns(layout: String, position: Double, content: CGFloat) -> Int {
        let stops = LibraryGridGeometry.stops(content: content)
        let index = position >= 0
            ? LibraryGridGeometry.stopIndex(position: position, count: stops.count)
            : LibraryGridGeometry.nearestStop(to: layout == "compact" ? LibraryGridGeometry.compactTarget
                                                                      : LibraryGridGeometry.cardsTarget, content: content)
        return stops[index]
    }

    static func layout(forCardWidth w: CGFloat) -> String {
        abs(log(w / LibraryGridGeometry.cardsTarget)) <= abs(log(w / LibraryGridGeometry.compactTarget)) ? "cards" : "compact"
    }
}

/// The card title's size follows the level's card width: 12 pt on a narrow card (4 across on a phone), 15 pt on a wide one (2
/// across), a straight line between in half points, so two neighbouring levels of a dense grid differ by a step instead of
/// straddling a cutoff. It reads the level's own card width, never a width in the middle of a pinch.
enum LibraryGridTitle {
    static let narrowCard: CGFloat = 77
    static let wideCard: CGFloat = 160
    static let narrowSize: CGFloat = 12
    static let wideSize: CGFloat = 15

    static func size(cardWidth w: CGFloat) -> CGFloat {
        let t = min(1, max(0, (w - narrowCard) / (wideCard - narrowCard)))
        return ((narrowSize + t * (wideSize - narrowSize)) * 2).rounded() / 2
    }
}

// MARK: - Card labels (measured, and drawn for the zoom)

/// What a card shows under its artwork, as text: the title, the pills, and a Steam game's played line. The same values the
/// SwiftUI card shows (LibraryBadges, SteamGameCell), so the drawn labels and the measured row heights agree with the real cards.
struct LibraryCardLabel: Hashable {
    var title: String
    /// LibraryBadges' format pills (bits, Batch, API, note) and its size pill; nil format: the card shows no LibraryBadges at all.
    var format: [String]?
    var size: String?
    var status: String?
    var played: String?

    struct Fonts {
        let title: UIFont
        let pill: UIFont
        let played: UIFont
        let traits: UITraitCollection?
        static func current(_ traits: UITraitCollection? = nil) -> Fonts {
            func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
                let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
                return UIFont.systemFont(ofSize: base.pointSize, weight: weight)
            }
            return Fonts(title: titleFont(cardWidth: LibraryGridTitle.wideCard, traits: traits),
                         pill: font(.caption2, .medium), played: font(.caption2, .regular), traits: traits)
        }
        static func titleFont(cardWidth w: CGFloat, traits: UITraitCollection?) -> UIFont {
            let size = UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: LibraryGridTitle.size(cardWidth: w), compatibleWith: traits)
            return UIFont.systemFont(ofSize: size, weight: .semibold)
        }
        func at(cardWidth w: CGFloat) -> Fonts {
            Fonts(title: Self.titleFont(cardWidth: w, traits: traits), pill: Self.scaled(pill, Style.forCardWidth(w).scale),
                  played: played, traits: traits)
        }
        static func scaled(_ font: UIFont, _ scale: CGFloat) -> UIFont {
            scale == 1 ? font : font.withSize((font.pointSize * scale * 4).rounded() / 4)
        }
    }

    /// How a level writes its pills: one rule per level, never mixed within a grid. Chosen by the card width, so a phone, an
    /// iPad and a landscape window all get the rule that fits their cards: wide cards (2 columns on a phone) show the full
    /// labels at full size; mid cards (3 columns) the full labels at 0.8x text (the floor SwiftUI's `minimumScaleFactor(0.8)`
    /// gives these badges); narrow cards (4 columns and denser) the compact labels at 0.8x. The thresholds sit between those
    /// widths on a log scale. The style changes only across a level boundary.
    struct Style: Hashable {
        let scale: CGFloat
        let compact: Bool
        static let fullMinCard: CGFloat = 140
        static let compactBelowCard: CGFloat = 92
        static let textFloor: CGFloat = 0.8
        static func forCardWidth(_ w: CGFloat) -> Style {
            w >= fullMinCard ? Style(scale: 1, compact: false)
                : w >= compactBelowCard ? Style(scale: textFloor, compact: false)
                : Style(scale: textFloor, compact: true)
        }
    }

    /// The compact spelling of a pill's text: bits as x64 / x86, OpenGL as GL, Vulkan as VK, a size of 10 GB or more as a whole
    /// number, under 1 GB in MB; 1-10 GB keeps its one decimal. Any other text (a status, a note) is unchanged.
    static func compactText(_ text: String) -> String {
        switch text {
        case "64-bit": return "x64"
        case "32-bit": return "x86"
        case "OpenGL": return "GL"
        case "Vulkan": return "VK"
        default: break
        }
        if text.hasSuffix(" GB"), let gb = Double(text.dropLast(3)) {
            if gb < 1 { return "\(Int((gb * 1000).rounded())) MB" }
            if gb >= 10 { return String(format: "%.0f GB", gb) }
        }
        return text
    }

    private func pillTexts(compact: Bool) -> [String]? {
        let texts: [String]
        if let status { texts = [status] }
        else if let format { texts = format + (size.map { [$0] } ?? []) }
        else { return nil }
        return compact && status == nil ? texts.map(Self.compactText) : texts
    }

    /// What the band's height depends on. A state pill is always one row and the played line one line, whatever their text
    /// ("Downloading 37%" ticks every second), so the height cache keys on the label with those texts blanked: a progress tick
    /// is the same key, a changed title, tag or size is a new one.
    var heightKey: LibraryCardLabel {
        var key = self
        if status != nil { key.status = "" }
        if played != nil { key.played = "" }
        return key
    }

    private static let pillPadH: CGFloat = 5, pillPadV: CGFloat = 4, pillSpacing: CGFloat = 4

    /// How a title sits in its width: its visible lines (1 or 2), the scale it is set at (1, or less for a title with a word that does not fit, never below `Style.textFloor`).
    struct TitleFit: Hashable {
        let lines: Int
        let scale: CGFloat
        let hyphenated: Bool
        let truncated: Bool
    }

    /// The title rule, one function for the band's measure and the cell's draw. The title wraps at words and hyphenates where
    /// the system finds a hyphenation point. A word that still cannot fit shrinks THIS title alone, in steps down to 0.8x; past
    /// that it is cut. A title longer than two lines is cut (ellipsis) at full size.
    static func titleFit(_ title: String, width w: CGFloat, font: UIFont) -> TitleFit {
        guard !title.isEmpty else { return TitleFit(lines: 1, scale: 1, hyphenated: false, truncated: false) }
        let key = TitleLinesKey(title: title, width: w, font: font.fontName, size: font.pointSize)
        if let known = titleLinesMemo.withLock({ $0[key] }) { return known }
        let fit = measureTitleFit(title, width: w, font: font)
        titleLinesMemo.withLock { if $0.count > 20_000 { $0.removeAll() }; $0[key] = fit }
        return fit
    }
    private struct TitleLinesKey: Hashable { let title: String; let width: CGFloat; let font: String; let size: CGFloat }
    private static let titleLinesMemo = OSAllocatedUnfairLock(initialState: [TitleLinesKey: TitleFit]())

    static var titleStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.hyphenationFactor = 1
        return style
    }

    private static func measureTitleFit(_ title: String, width w: CGFloat, font: UIFont) -> TitleFit {
        let spaced = title.contains { $0.isWhitespace }
        var last = TitleFit(lines: 1, scale: 1, hyphenated: false, truncated: false)
        for step in [1, 0.95, 0.9, 0.85, Style.textFloor] as [CGFloat] {
            let f = Fonts.scaled(font, step)
            let layout = layoutTitle(title, width: max(1, w), font: f)
            last = TitleFit(lines: min(2, layout.lines), scale: step, hyphenated: layout.hyphenated, truncated: layout.lines > 2)
            // A word split without a hyphen, or one word over two lines, shrinks the title; a longer one is cut.
            if !layout.splitWord && (layout.lines <= 2 || spaced) { return last }
        }
        return TitleFit(lines: last.lines, scale: Style.textFloor, hyphenated: last.hyphenated, truncated: true)
    }

    /// The one text engine of a title: this TextKit layout is what `layoutTitle` measures and what `draw` paints, so the lines
    /// counted and the lines drawn cannot disagree. `maxLines` 0 lays out every line; the draw passes the visible lines.
    private static func titleLayout(_ title: String, width: CGFloat, font: UIFont, maxLines: Int = 0)
        -> (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer) {
        let storage = NSTextStorage(string: title, attributes: [.font: font, .paragraphStyle: titleStyle,
                                                                 .foregroundColor: UIColor.label])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return (storage, manager, container)
    }

    /// The lines TextKit makes of `title` in `width`: how many, whether a visible line ends in a hyphen the layout added, and whether the first line ends inside a word with no hyphen.
    private static func layoutTitle(_ title: String, width: CGFloat, font: UIFont) -> (lines: Int, hyphenated: Bool, splitWord: Bool) {
        let text = title as NSString
        let (storage, manager, _) = titleLayout(title, width: width, font: font)
        defer { withExtendedLifetime(storage) {} }
        var lines = 0, hyphenated = false, split = false
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, _ in
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines += 1
            let added = glyphs.length > chars.length
            if added && lines <= 2 { hyphenated = true }
            if lines == 1, !added, NSMaxRange(chars) < text.length {
                let before = text.character(at: NSMaxRange(chars) - 1), after = text.character(at: NSMaxRange(chars))
                func inWord(_ c: unichar) -> Bool { Unicode.Scalar(c).map { !CharacterSet.whitespacesAndNewlines.contains($0) } ?? true }
                func dash(_ c: unichar) -> Bool { c == 0x2D || c == 0x2010 || c == 0x2013 || c == 0x2014 }
                if inWord(before) && inWord(after) && !dash(before) { split = true }
            }
        }
        return (lines, hyphenated, split)
    }

    private struct PillWidthKey: Hashable { let text: String; let font: String; let size: CGFloat }
    private static let pillWidthMemo = OSAllocatedUnfairLock(initialState: [PillWidthKey: CGFloat]())

    private static func pillWidth(_ text: String, font: UIFont) -> CGFloat {
        let key = PillWidthKey(text: text, font: font.fontName, size: font.pointSize)
        if let known = pillWidthMemo.withLock({ $0[key] }) { return known }
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2 * pillPadH
        pillWidthMemo.withLock { if $0.count > 20_000 { $0.removeAll() }; $0[key] = width }
        return width
    }

    /// A pill placed in a row: its text, the width it is drawn at (its natural width, or less when cut with a tail ellipsis) and whether it is cut.
    struct PlacedPill: Hashable {
        let text: String
        let width: CGFloat
        let truncated: Bool
    }

    private static func rowWidth(_ widths: ArraySlice<CGFloat>) -> CGFloat {
        widths.isEmpty ? 0 : widths.reduce(0, +) + CGFloat(widths.count - 1) * pillSpacing
    }

    /// The pills' rows, at most two, and the width each is drawn at. The pills flow in order: the first row takes as many as fit,
    /// the rest go to the second. When they do not fit in two rows, the split that cuts least is taken and the pills of an
    /// overfull row are cut with a tail ellipsis, the widest first (`shrink`). A pill is never left out. `bandHeight` and `draw`
    /// both read this. No pills at all is `[[]]` (a card that shows the pill area empty).
    func pillPlacement(width: CGFloat, font: UIFont, compact: Bool = false) -> [[PlacedPill]] {
        guard let texts = pillTexts(compact: compact) else { return [] }
        if texts.isEmpty { return [[]] }
        let natural = texts.map { Self.pillWidth($0, font: font) }
        let count = texts.count

        func overflow(_ range: Range<Int>) -> CGFloat { max(0, Self.rowWidth(natural[range]) - width) }
        // Row one takes every pill that fits (the first always stays in it).
        var split = count
        var used: CGFloat = 0
        for i in 0..<count {
            let next = used + (i > 0 ? Self.pillSpacing : 0) + natural[i]
            if i > 0, next > width + 0.001 { split = i; break }
            used = next
        }
        // Two rows that still overflow: the split whose most-cut pill keeps the most of its width (ties: more pills in row one).
        func floors(_ range: Range<Int>) -> [CGFloat] {
            range.map { Self.pillWidth(String(texts[$0].prefix(1)) + "\u{2026}", font: font) }
        }
        func keptShare(_ range: Range<Int>) -> CGFloat {
            let widths = Self.shrink(natural: Array(natural[range]), floors: floors(range),
                                     available: width - CGFloat(range.count - 1) * Self.pillSpacing)
            return zip(widths, natural[range]).map { $0 / $1 }.min() ?? 1
        }
        if count > 1, overflow(0..<split) + overflow(split..<count) > 0.001 {
            var best: CGFloat = -1
            for k in 1..<count {
                let share = min(keptShare(0..<k), keptShare(k..<count))
                if share >= best - 0.001 { best = max(best, share); split = k }
            }
        }
        var rows: [[PlacedPill]] = []
        for range in (split == count ? [0..<count] : [0..<split, split..<count]) {
            let widths = Self.shrink(natural: Array(natural[range]), floors: floors(range),
                                     available: width - CGFloat(range.count - 1) * Self.pillSpacing)
            rows.append(zip(range, widths).map { PlacedPill(text: texts[$0], width: $1, truncated: $1 < natural[$0] - 0.5) })
        }
        return rows
    }

    /// `natural` widths cut to fit `available`: the widest give up width first (water-filling: all pills end at the same width or
    /// at their own, shorter, natural one). A pill does not go below its floor (its first character and an ellipsis) unless even
    /// the floors do not fit; then they share the width in proportion.
    static func shrink(natural: [CGFloat], floors: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard natural.reduce(0, +) > available + 0.001 else { return natural }
        let floors = zip(floors, natural).map { min($0, $1) }
        let floorTotal = floors.reduce(0, +)
        if floorTotal >= available { return floors.map { $0 * max(0, available) / floorTotal } }
        var low: CGFloat = 0, high = natural.max() ?? 0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            let total = zip(natural, floors).map { max($1, min($0, mid)) }.reduce(0, +)
            if total > available { high = mid } else { low = mid }
        }
        return zip(natural, floors).map { max($1, min($0, low)) }
    }

    func bandHeight(cardWidth: CGFloat, fonts: Fonts) -> CGFloat {
        let w = max(1, cardWidth - 2 * LibraryGridGeometry.cardPadding)
        let style = Style.forCardWidth(cardWidth)
        let fonts = fonts.at(cardWidth: cardWidth)
        let rows = pillPlacement(width: w, font: fonts.pill, compact: style.compact)
        let fit = Self.titleFit(title, width: w, font: fonts.title)
        return band(titleLines: fit.lines, titleFont: Fonts.scaled(fonts.title, fit.scale),
                    pillRows: rows.isEmpty ? nil : rows.filter { !$0.isEmpty }.count, fonts: fonts)
    }

    /// The band of a card no one can see yet: no text is measured, the lines come from the text's length at an average glyph
    /// width. The measured band replaces it before the card can come on screen.
    func estimatedBandHeight(cardWidth: CGFloat, fonts: Fonts) -> CGFloat {
        let w = max(1, cardWidth - 2 * LibraryGridGeometry.cardPadding)
        let style = Style.forCardWidth(cardWidth)
        let fonts = fonts.at(cardWidth: cardWidth)
        func width(_ text: String, _ font: UIFont) -> CGFloat { CGFloat(text.count) * font.pointSize * 0.55 }
        let lines = width(title, fonts.title) > w ? 2 : 1
        var rows: Int?
        if status != nil {
            rows = 1
        } else if format != nil, let texts = pillTexts(compact: style.compact) {
            let all = texts.map { width($0, fonts.pill) + 2 * Self.pillPadH }
            let one = all.reduce(0, +) + CGFloat(max(0, all.count - 1)) * Self.pillSpacing
            rows = all.isEmpty ? 0 : (one <= w || all.count == 1 ? 1 : 2)
        }
        return ceil(band(titleLines: lines, titleFont: fonts.title, pillRows: rows, fonts: fonts))
    }

    private func band(titleLines: Int, titleFont: UIFont, pillRows: Int?, fonts: Fonts) -> CGFloat {
        let spacing = LibraryGridGeometry.labelSpacing
        var h = spacing + CGFloat(titleLines) * ceil(titleFont.lineHeight)
        if let nonEmpty = pillRows {
            let row = ceil(fonts.pill.lineHeight) + 2 * Self.pillPadV
            h += spacing + CGFloat(nonEmpty) * row + CGFloat(max(0, nonEmpty - 1)) * Self.pillSpacing
        }
        if played != nil { h += spacing + ceil(fonts.played.lineHeight) }
        return h + LibraryGridGeometry.cardPadding
    }

    /// Draws the label fonts' common characters once, off the main thread: a glyph's first draw loads its outline, slow enough to show while scrolling.
    static func warmGlyphs(fonts: Fonts) {
        let sample = String((0x20...0x7E).compactMap { Unicode.Scalar($0).map(Character.init) }) + "%\u{2022}\u{00B7}\u{2013}\u{2014}\u{2026}\u{2019}"
        let titles = [LibraryGridTitle.narrowCard, 110, LibraryGridTitle.wideCard].map { fonts.at(cardWidth: $0).title }
        let all = titles + titles.map { Fonts.scaled($0, Style.textFloor) } + [fonts.pill, fonts.played, Fonts.scaled(fonts.pill, Style.textFloor)]
        DispatchQueue.global(qos: .utility).async {
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            let size = CGSize(width: 1_600, height: 60)
            for font in all {
                _ = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    (sample as NSString).draw(in: CGRect(origin: .zero, size: size), withAttributes: [.font: font, .foregroundColor: UIColor.label])
                }
            }
        }
    }

    /// The label as ONE image: drawn text, no views. `size` is the band (card width x band height). Kept by what it was drawn
    /// for (`LibraryLabelBitmaps`), so a card showing the same label at the same width again is not drawn twice.
    func image(size: CGSize, fonts: Fonts, traits: UITraitCollection) -> UIImage {
        if let kept = LibraryLabelBitmaps.shared.image(for: self, size: size, traits: traits) { return kept }
        let format = UIGraphicsImageRendererFormat(for: traits)
        format.opaque = false
        format.preferredRange = .standard
        let made = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            traits.performAsCurrent { draw(size: size, fonts: fonts) }
        }
        LibraryLabelBitmaps.shared.keep(made, for: self, size: size, traits: traits)
        return made
    }

    /// Draws the label into the current context, top left at the origin, with the current trait collection's dynamic colours.
    /// The zoom's label images and the card cell's label view share this one drawing.
    func draw(size: CGSize, fonts: Fonts) {
        let style = Style.forCardWidth(size.width)
        let fonts = fonts.at(cardWidth: size.width)
        let x = LibraryGridGeometry.cardPadding
        let w = max(1, size.width - 2 * x)
        var y = LibraryGridGeometry.labelSpacing
        let fit = Self.titleFit(title, width: w, font: fonts.title)
        let titleFont = Fonts.scaled(fonts.title, fit.scale)
        // The measure's own engine (titleLayout), the last visible line truncated.
        if !title.isEmpty {
            let (storage, manager, container) = Self.titleLayout(title, width: w, font: titleFont, maxLines: fit.lines)
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: CGPoint(x: x, y: y))
            withExtendedLifetime(storage) {}
        }
        y += CGFloat(fit.lines) * ceil(titleFont.lineHeight)
        let rows = pillPlacement(width: w, font: fonts.pill, compact: style.compact)
        if !rows.isEmpty {
            y += LibraryGridGeometry.labelSpacing
            let rowHeight = ceil(fonts.pill.lineHeight) + 2 * Self.pillPadV
            for row in rows where !row.isEmpty {
                var px = x
                for pill in row {
                    let rect = CGRect(x: px, y: y, width: pill.width, height: rowHeight)
                    UIColor.secondaryLabel.withAlphaComponent(0.12).setFill()
                    UIBezierPath(roundedRect: rect, cornerRadius: 6).fill()
                    let textRect = rect.insetBy(dx: Self.pillPadH, dy: Self.pillPadV)
                    if textRect.width >= 1 {
                        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
                        (pill.text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin],
                                                     attributes: [.font: fonts.pill, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style],
                                                     context: nil)
                    }
                    px += pill.width + Self.pillSpacing
                }
                y += rowHeight + Self.pillSpacing
            }
            y -= Self.pillSpacing
        }
        if let played {
            y += LibraryGridGeometry.labelSpacing
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            (played as NSString).draw(with: CGRect(x: x, y: y, width: w, height: ceil(fonts.played.lineHeight)), options: [.usesLineFragmentOrigin],
                                      attributes: [.font: fonts.played, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style],
                                      context: nil)
        }
    }
}

/// Drawn labels, kept by what they were drawn for: the label's text, the band's size (to a hundredth of a point) and the traits
/// that change how it draws. The zoom draws every level's labels off the main thread; the card cell's label view finds the one
/// for its width here. Bounded by size in memory: past the limit the oldest go.
final class LibraryLabelBitmaps: @unchecked Sendable {
    static let shared = LibraryLabelBitmaps()
    private struct Key: Hashable {
        let label: LibraryCardLabel
        let width: Int, height: Int
        let style: Int, category: String, scale: Int
        let titleHalfPoints: Int
    }
    private var images: [Key: UIImage] = [:]
    private var order: [Key] = []
    private let lock = NSLock()
    private var bytes = 0
    private static let byteLimit = 16 * 1_024 * 1_024
    private static func cost(_ image: UIImage) -> Int { Int(image.size.width * image.size.height * image.scale * image.scale * 4) }

    private func key(_ label: LibraryCardLabel, _ size: CGSize, _ traits: UITraitCollection) -> Key {
        Key(label: label, width: Int((size.width * 100).rounded()), height: Int((size.height * 100).rounded()),
            style: traits.userInterfaceStyle.rawValue, category: traits.preferredContentSizeCategory.rawValue,
            scale: Int((traits.displayScale * 100).rounded()), titleHalfPoints: Int(LibraryGridTitle.size(cardWidth: size.width) * 2))
    }

    func image(for label: LibraryCardLabel, size: CGSize, traits: UITraitCollection) -> UIImage? {
        let k = key(label, size, traits)
        lock.lock(); defer { lock.unlock() }
        return images[k]
    }

    func keep(_ image: UIImage, for label: LibraryCardLabel, size: CGSize, traits: UITraitCollection) {
        let k = key(label, size, traits)
        lock.lock(); defer { lock.unlock() }
        if let old = images.updateValue(image, forKey: k) { bytes -= Self.cost(old) } else { order.append(k) }
        bytes += Self.cost(image)
        while bytes > Self.byteLimit, order.count > 1 {
            let oldest = order.removeFirst()
            if let gone = images.removeValue(forKey: oldest) { bytes -= Self.cost(gone) }
        }
    }
}
