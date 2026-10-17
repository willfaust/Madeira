// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

// The zoomable grid's card as a UIKit cell (docs/zoomable-grid.md, "Cells"). The
// original SwiftUI grid's card (LibraryCells, SteamGameCell, LibraryBadges) is untouched
// and stays the grid when the new one is off; this is the same card as a UIKit cell: a cover (LibraryGridZoomCover, the zoom's own
// stand-in, so the two cannot differ), a label that is the label the layout measures (LibraryCardLabel.draw), the press and the
// controller focus ring. A cell is a few layers, so scrolling makes and reuses cells without a hosted SwiftUI view.

struct LibraryGridCardContent: Equatable {
    var label: LibraryCardLabel?
    var source: LibraryCoverCache.Source?
    var overlay: LibraryGridZoomCover.Overlay = .none
    var focused = false
    var accessibility = ""
}

/// Work a card does while it is on screen (the SwiftUI cards' `.task`): a library game's metadata refresh, an installed Steam game's launch configuration.
struct LibraryGridCardWork {
    let id: String
    let run: @MainActor () async -> Void
}

final class LibraryGridLabelView: UIView {
    var label: LibraryCardLabel? { didSet { if label != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.setNeedsDisplay()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let label else { return }
        // The bitmap the zoom drew for this width, when there is one: no text layout in the landing's frame.
        if let kept = LibraryLabelBitmaps.shared.image(for: label, size: bounds.size, traits: traitCollection) {
            kept.draw(in: bounds)
            return
        }
        label.draw(size: bounds.size, fonts: .current(traitCollection))
    }
}

/// A grid cell the zoom can hold hidden: while held, every un-hide is undone in the same call, so a real cell UIKit re-shows is never drawn under the stage.
class LibraryGridHeldCell: UICollectionViewCell {
    var heldHiddenByZoom = false {
        didSet { if heldHiddenByZoom { isHidden = true } }
    }
    override var isHidden: Bool {
        didSet { if heldHiddenByZoom, !isHidden { isHidden = true } }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        heldHiddenByZoom = false
        isHidden = false
    }
}

final class LibraryGridCardCell: LibraryGridHeldCell {
    private(set) var card: LibraryGridCard?
    private(set) var content: LibraryGridCardContent?
    private var cover: LibraryGridZoomCover?
    private let labelView = LibraryGridLabelView()
    private let ring = CAShapeLayer()
    var onPress: ((String, Bool) -> Void)?

    private var coverKey: String?
    private var coverPixels = 0
    private var coverExact = false

    private var wanted: LibraryGridCardWork?
    private var running: (id: String, task: Task<Void, Never>)?
    private var displayed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        contentView.addSubview(labelView)
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.isHidden = true
        contentView.layer.addSublayer(ring)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var key: String { card?.key ?? "" }

    func configure(card: LibraryGridCard, content: LibraryGridCardContent, work: LibraryGridCardWork?) {
        self.card = card
        if cover == nil {
            let made = LibraryGridZoomCover(artSize: art, overlay: content.overlay, traits: nil)
            contentView.insertSubview(made, belowSubview: labelView)
            cover = made
            setNeedsLayout()
        }
        if content != self.content {
            cover?.setOverlay(content.overlay)
            labelView.label = content.label
            ring.isHidden = !content.focused
            accessibilityLabel = content.accessibility
            self.content = content
        }
        refreshCover()
        wanted = work
        updateWork()
    }

    private var art: CGSize { LibraryGridGeometry.artworkRect(cardWidth: max(1, bounds.width)).size }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let rect = LibraryGridGeometry.artworkRect(cardWidth: w)
        if let cover {
            cover.resize(to: rect.size)
            cover.center = CGPoint(x: rect.midX, y: rect.midY)
        }
        let top = LibraryGridGeometry.coverHeight(cardWidth: w)
        labelView.frame = CGRect(x: 0, y: top, width: w, height: max(0, bounds.height - top))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.path = UIBezierPath(roundedRect: bounds, cornerRadius: 16).cgPath
        ring.frame = .zero
        CATransaction.commit()
        refreshCover()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        ring.strokeColor = tintColor.cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        ring.strokeColor = tintColor.cgColor
    }

    // MARK: The zoom's placement

    /// The cell placed by the zoom's rule before the zoom's stage is shown: only the cover scales (to `coverRect`'s width, centred in
    /// it), the label keeps its size under the cover. `coverRect` is in content coordinates. Transforms only: no layout, no new views.
    func applyZoomPlacement(_ coverRect: CGRect) {
        guard let cover else { return }
        cover.transform = .identity
        labelView.transform = .identity
        let local = coverRect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let rest = LibraryGridGeometry.artworkRect(cardWidth: max(1, bounds.width))
        let art = LibraryGridGeometry.artworkRect(cardWidth: max(1, local.width)).offsetBy(dx: local.minX, dy: local.minY)
        let scale = art.width / max(1, rest.width)
        cover.transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: art.midX - cover.center.x, ty: art.midY - cover.center.y)
        labelView.transform = CGAffineTransform(translationX: local.midX - labelView.center.x,
                                                y: local.maxY + labelView.bounds.height / 2 - labelView.center.y)
    }


    func clearZoomPlacement() {
        cover?.transform = .identity
        labelView.transform = .identity
    }

    // MARK: Cover

    func refreshCover() {
        guard let cover, let source = content?.source else { cover?.setImage(nil, exact: false); coverKey = nil; return }
        let scale = traitCollection.displayScale
        let pixels = LibraryGridGeometry.coverPixels(cardWidth: bounds.width, scale: scale)
        guard pixels > 0 else { return }
        if coverKey == source.variant, coverPixels == pixels, coverExact { return }
        let found = LibraryCoverCache.shared.image(for: source, pixelWidth: pixels)
        cover.setImage(found?.image, exact: found?.exact ?? false)
        coverKey = source.variant
        coverPixels = pixels
        coverExact = found?.exact ?? false
    }

    var coverSourceKey: String? { content?.source?.key }

    // MARK: Press

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            onPress?(key, isHighlighted)
            // Press: spring(response: 0.26, dampingFraction: 0.86) in, spring(response: 0.42, dampingFraction: 0.58) back.
            let pressed = isHighlighted
            let scale = LibraryCardArtworkPress.pressedScale
            UIView.animate(springDuration: pressed ? 0.26 : 0.42, bounce: pressed ? 0.14 : 0.42, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.cover?.transform = pressed ? CGAffineTransform(scaleX: scale, y: scale) : .identity
            }
        }
    }

    // MARK: Work while displayed

    /// Set for a cell realised while a zoom runs: its metadata work waits for the landing, not while the offset sweeps under the zoom.
    private var workHeld = false
    func displayStarted(holdWork: Bool = false) { displayed = true; workHeld = holdWork; updateWork() }
    func releaseHeldWork() { guard workHeld else { return }; workHeld = false; updateWork() }
    func displayEnded() { displayed = false; updateWork() }

    private func updateWork() {
        guard displayed, !workHeld, let wanted else {
            running?.task.cancel()
            running = nil
            return
        }
        if running?.id == wanted.id { return }
        running?.task.cancel()
        let run = wanted.run
        running = (wanted.id, Task(priority: .utility) { await run() })
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        displayed = false
        workHeld = false
        wanted = nil
        updateWork()
        cover?.layer.removeAllAnimations()
        cover?.transform = .identity
        labelView.transform = .identity
        coverKey = nil
        content = nil
        card = nil
        cover?.setImage(nil, exact: false)
    }
}

// MARK: - The card's content from the page

extension LibraryGridPageModel {
    @MainActor func overlay(for item: LibraryGridItem) -> LibraryGridZoomCover.Overlay {
        guard case .card(.steam(let id)) = item else { return .none }
        if let download = SteamOwnedLibrary.shared.downloads[id] {
            switch download.state {
            case .active: return .active(download.progress.fraction)
            case .queued: return .queued
            case .paused: return .paused
            case .failed: return .failed
            }
        }
        return steam[id]?.installed?.installed == true ? .none : .notDownloaded
    }

    @MainActor func dimmed(_ card: LibraryGridCard) -> Bool {
        guard case .steam(let id) = card else { return false }
        return steam[id]?.installed?.installed != true && SteamOwnedLibrary.shared.downloads[id] == nil
    }

    @MainActor func content(for card: LibraryGridCard, label: LibraryCardLabel?, focused: UUID?) -> LibraryGridCardContent {
        var content = LibraryGridCardContent(label: label, source: LibraryGridHostController.coverSource(card, page: self),
                                             overlay: overlay(for: .card(card)))
        if case .entry(let id) = card, id == focused { content.focused = true }
        if let label {
            var texts = [label.title]
            if let status = label.status { texts.append(status) }
            else { texts += (label.format ?? []) + [label.size].compactMap { $0 } }
            if let played = label.played { texts.append(played) }
            content.accessibility = texts.joined(separator: ", ")
        }
        return content
    }

    @MainActor func work(for card: LibraryGridCard) -> LibraryGridCardWork? {
        switch card {
        case .entry(let id):
            return LibraryGridCardWork(id: "entry-\(id)") { await LibraryModel.shared.refreshMetadata(id) }
        case .steam(let id):
            guard let item = steam[id] else { return nil }
            let account = SteamOwnedLibrary.shared, games = SteamGamesModel.shared, library = LibraryModel.shared
            let download = account.downloads[id]
            let status = SteamGamesRules.status(installed: item.installed, transfer: download?.transfer,
                                                updateAvailable: account.updateAvailable(appID: id, installedBuild: games.builds[id]))
            guard status.showsFormat, let game = item.installed else { return nil }
            let entry = library.entries.first { $0.steamAppID == id }
            let key = "\(item.installed?.windowsInstallPath ?? "") \(games.builds[id] ?? 0) \(entry?.steamProgram ?? "") \(account.game(id)?.launches != nil)"
            return LibraryGridCardWork(id: "steam-\(id) " + key) { await library.refreshSteamMetadata(game, title: item.name) }
        }
    }
}
