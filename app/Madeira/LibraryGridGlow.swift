// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Accelerate
import Combine
import Metal
import os
import QuartzCore
import UIKit

// The zoomable grid's ambient light, without a SwiftUI view per card (docs/zoomable-grid.md, "The glow"). `AmbientGlow`
// (Library.swift) is one hosted TimelineView per card, and a hosted view that flips hidden-for-reuse dirties the tab's whole
// SwiftUI host, so the glow here is Metal layers inside the page's collection view, behind its cells, drawn in the page's
// coordinates: the compositor moves the light with the cards, and it is re-drawn only at its own 30 fps animation and when the
// visible part nears the edge of what was drawn. The drawing is encoded and committed on a background queue, so nothing on the
// main thread waits for a drawable. The light is the card's blurred, saturated artwork (made once on the CPU, as a small
// texture), the turned and mirrored copies, hue drift, knee and the three ring masks (AmbientGlow.metal), and the rays.

struct LibraryGlowCard {
    let key: String
    let frame: CGRect
    let seed: Int
    let dimmed: Bool
    let sourceKey: String?
    let card: LibraryGridCard
}

/// A value moving to a target along a CSS-style cubic bezier (SwiftUI's easeIn / easeOut / easeInOut).
struct LibraryGlowTween {
    struct Curve {
        let x1, y1, x2, y2: Double
        static let easeIn = Curve(x1: 0.42, y1: 0, x2: 1, y2: 1)
        static let easeOut = Curve(x1: 0, y1: 0, x2: 0.58, y2: 1)
        static let easeInOut = Curve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
        func ease(_ t: Double) -> Double {
            if t <= 0 { return 0 }
            if t >= 1 { return 1 }
            func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
            var s = t
            for _ in 0..<8 {
                let x = bezier(s, x1, x2) - t
                let dx = 3 * x1 * (1 - s) * (1 - s) + 6 * (x2 - x1) * s * (1 - s) + 3 * (1 - x2) * s * s
                if abs(x) < 1e-5 || abs(dx) < 1e-6 { break }
                s = min(1, max(0, s - x / dx))
            }
            return bezier(s, y1, y2)
        }
    }
    private var from: Double
    private(set) var target: Double
    private var start = 0.0
    private var duration = 0.0
    private var curve = Curve.easeInOut
    init(_ value: Double) { from = value; target = value }

    func value(at now: Double) -> Double {
        guard duration > 0, now < start + duration else { return target }
        return from + (target - from) * curve.ease((now - start) / duration)
    }
    func running(at now: Double) -> Bool { duration > 0 && now < start + duration }
    mutating func move(to newTarget: Double, now: Double, duration: Double, curve: Curve) {
        guard newTarget != target else { return }
        from = value(at: now)
        target = newTarget
        start = now
        self.duration = duration
        self.curve = curve
    }
}

/// One drawing surface of the glow: a CAMetalLayer view as wide as the page and `LibraryGlowView.surfaceHeight` tall, placed at `origin` (a content y).
private final class LibraryGlowSurface: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metal: CAMetalLayer { layer as! CAMetalLayer }
    var origin: CGFloat = 0
    var valid = false
}

private struct LibraryGlowJob: @unchecked Sendable {
    struct Item {
        var texture: MTLTexture
        var rays: MTLTexture
        var movie: AmbientMovie
        var rect: CGRect
        var size: CGSize
        var art: CGSize
        var reach: Float
        var strength: Float
        var raysAmount: Float
        var seed: Int
    }
    var layer: CAMetalLayer
    var size: CGSize
    var items: [Item]
    var dark: Bool
    var reduceMotion: Bool
    var time: Double
    var onPresented: (@Sendable () -> Void)?
    var onCompleted: @Sendable () -> Void
    /// Drawn and presented on the calling (main) thread inside the current Core Animation transaction, so it lands in the same commit as the cells that moved.
    var sync = false
}

/// The glow: the container that sits first in the collection view (behind its cells), with two surfaces. The front one shows
/// the light; a re-centre (the visible part nears the edge of what is drawn) draws the other in the new place and swaps them.
@MainActor
final class LibraryGlowView: UIView {
    weak var host: LibraryGridHostController?
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let clamp: MTLSamplerState
    private let wrap: MTLSamplerState


    /// The art's size in the glow's base texture. The texture (and the quad it is drawn on) reaches `reach` further than the glow
    /// frame on each side, so the blurred light dies away inside it and never ends in a cut.
    nonisolated static let artPixels = CGSize(width: 100, height: 150)
    nonisolated static let spread: CGFloat = 0.17
    nonisolated static let reach: CGFloat = 0.12
    nonisolated static let texture = CGSize(width: 158, height: 208)

    /// The glow's size is a share of the card's width, which suits ordinary cards; a small card would get a few points of blur and a
    /// reach smaller than the gap. So the glow is sized as if the card were at least `reference` wide: `scale` is how many times
    /// wider that is than the card (1 at or above it), and the glow's blur, spread and reach are the ordinary ones times `scale`,
    /// in points the same at every level.
    nonisolated static func scale(artWidth: CGFloat, reference: CGFloat) -> CGFloat {
        artWidth > 0 ? max(1, reference / artWidth) : 1
    }
    /// The width in texture pixels of the art in a card's base texture: its blur, spread and reach are fixed pixel counts, so a card
    /// with a larger `scale` has a smaller art in the same margins. In steps of 4 so a resized window does not rebuild every texture.
    nonisolated static func artPixels(scale: CGFloat) -> Int {
        max(24, Int((artPixels.width / scale / 4).rounded()) * 4)
    }
    nonisolated static func textureSize(artPixels art: Int) -> (width: Int, height: Int) {
        let margin = Int(((spread + reach) * artPixels.width).rounded()) * 2
        return (art + margin, art * 3 / 2 + margin)
    }
    private var referenceArt: CGFloat {
        let g = LibraryGridGeometry.self
        let card = min(g.cardWidth(content: g.contentWidth(viewport: viewport.width), columns: g.minimumColumns), g.maxCard)
        return g.artworkRect(cardWidth: card).width
    }
    func lightReach(cardWidth: CGFloat) -> CGFloat {
        let art = LibraryGridGeometry.artworkRect(cardWidth: cardWidth).width
        return art * Self.scale(artWidth: art, reference: referenceArt) * (Self.spread + Self.reach)
    }
    nonisolated static let overscan: CGFloat = 0.4
    nonisolated static let maximumScale: CGFloat = 2

    private struct Entry {
        var texture: MTLTexture?
        var style = ""
        var artPixels = Int(LibraryGlowView.artPixels.width)
        var builtExact = false
        /// The art's pixel width the card's geometry needs: a texture made for another width is never drawn, whatever it looks like.
        var wantedArtPixels = Int(LibraryGlowView.artPixels.width)
        var stale = false
        var pending = false
        var rays: MTLTexture?
        var movie: AmbientMovie?
        var seed = 0
        var lastSeen = 0.0
        var sourceKey: String?
        var dimmed = false
    }
    private var entries: [String: Entry] = [:]
    private var raysBySeed: [Int: MTLTexture] = [:]
    private struct TweenSet {
        var rays = LibraryGlowTween(0)    // 0 soft ... 1 crisp
        var scale = LibraryGlowTween(1)
        var fade = LibraryGlowTween(1)
    }
    private var tweens: [String: TweenSet] = [:]

    private var link: CADisplayLink?
    private var fastLink = false
    private var lastAnimation = 0.0
    private var lastScroll = 0.0
    private var lastTop = 0.0, lastTopTime = 0.0
    private var animating = false
    private var cancellables = Set<AnyCancellable>()
    private(set) var suspended = false
    private let queueWork = DispatchQueue(label: "madeira.glow.base", qos: .userInitiated, attributes: .concurrent)
    private let renderQueue = DispatchQueue(label: "madeira.glow.render", qos: .userInteractive)

    private let surfaces: [LibraryGlowSurface]
    private var front: LibraryGlowSurface
    private var viewport = CGSize.zero
    private var renderBusy = false
    private var swapping = false
    private var dirty = false

    static func make() -> LibraryGlowView? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "glowVertex"), let fragment = library.makeFunction(name: "glowFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        let clampDescriptor = MTLSamplerDescriptor()
        clampDescriptor.minFilter = .linear; clampDescriptor.magFilter = .linear
        clampDescriptor.sAddressMode = .clampToZero; clampDescriptor.tAddressMode = .clampToZero
        let wrapDescriptor = MTLSamplerDescriptor()
        wrapDescriptor.minFilter = .linear; wrapDescriptor.magFilter = .linear
        wrapDescriptor.sAddressMode = .repeat; wrapDescriptor.tAddressMode = .clampToEdge
        guard let clamp = device.makeSamplerState(descriptor: clampDescriptor), let wrap = device.makeSamplerState(descriptor: wrapDescriptor) else { return nil }
        return LibraryGlowView(device: device, queue: queue, pipeline: pipeline, clamp: clamp, wrap: wrap)
    }

    private init(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState, clamp: MTLSamplerState, wrap: MTLSamplerState) {
        self.device = device; self.queue = queue; self.pipeline = pipeline; self.clamp = clamp; self.wrap = wrap
        func surface() -> LibraryGlowSurface {
            let view = LibraryGlowSurface(frame: .zero)
            view.isUserInteractionEnabled = false
            view.isOpaque = false
            view.backgroundColor = .clear
            view.isHidden = true
            let layer = view.metal
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.isOpaque = false
            layer.framebufferOnly = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            // Three: the zoom draws on the main thread inside the frame's transaction, and with two it waits up to a second for a free drawable.
            layer.maximumDrawableCount = 3
            layer.allowsNextDrawableTimeout = true
            return view
        }
        let pair = [surface(), surface()]
        surfaces = pair
        front = pair[0]
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        for view in pair { addSubview(view) }
        // A cover that arrives (or a better size): the card's light is made from it.
        LibraryCoverCache.shared.updates.receive(on: DispatchQueue.main).sink { [weak self] key in self?.coverLanded(key) }.store(in: &cancellables)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in self.markDirty() }
        for name in [UIApplication.didReceiveMemoryWarningNotification, LibraryGridArm.releaseMemory] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in self?.releaseTextures() }.store(in: &cancellables)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateLink()
        if window == nil { releaseResources() } else { restoreDrawables() }
    }

    private func releaseTextures() {
        entries = [:]
        raysBySeed = [:]
        markDirty()
    }

    private var drawablesReleased = false
    private func releaseResources() {
        entries = [:]
        raysBySeed = [:]
        guard !drawablesReleased, viewport != .zero else { return }
        drawablesReleased = true
        for view in surfaces {
            view.valid = false
            view.metal.drawableSize = CGSize(width: 1, height: 1)
        }
        swapping = false
    }

    private func restoreDrawables() {
        guard drawablesReleased else { return }
        drawablesReleased = false
        let size = viewport
        viewport = .zero
        viewportChanged(size)
    }

    func viewportChanged(_ size: CGSize) {
        guard size != viewport, size.width > 0, size.height > 0 else { return }
        viewport = size
        let scale = min(window?.screen.scale ?? traitCollection.displayScale, Self.maximumScale)
        let height = (size.height * (1 + 2 * Self.overscan)).rounded(.up)
        for view in surfaces {
            view.valid = false
            view.metal.contentsScale = scale
            view.metal.drawableSize = CGSize(width: size.width * scale, height: height * scale)
            view.frame = CGRect(x: 0, y: view.origin, width: size.width, height: height)
        }
        frame = CGRect(x: 0, y: 0, width: size.width, height: 0)
        swapping = false
        markDirty()
    }

    // MARK: Running

    private var wanted: Bool { AmbientGlowSettings.shared.mode == .new && !suspended && window != nil }

    func modeChanged() {
        isHidden = AmbientGlowSettings.shared.mode != .new
        updateLink()
        markDirty()
    }

    private func updateLink() {
        if wanted, link == nil {
            let proxy = LinkProxy(self)
            let link = CADisplayLink(target: proxy, selector: #selector(LinkProxy.tick))
            link.add(to: .main, forMode: .common)
            self.link = link
            fastLink = false
            applyRate()
        } else if !wanted, let link {
            link.invalidate()
            self.link = nil
        }
    }

    /// 60 while the page moves (a re-centre needs to be timely) or a press tween runs, 30 otherwise. The glow never asks for 120:
    /// the light is a slow fade and the compositor moves it.
    private func applyRate() {
        guard let link else { return }
        if animating {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        } else if fastLink {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        } else {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        }
    }

    private final class LinkProxy: NSObject {
        weak var view: LibraryGlowView?
        init(_ view: LibraryGlowView) { self.view = view }
        @objc func tick() { MainActor.assumeIsolated { view?.tick() } }
    }

    /// The page scrolled: nothing is drawn (the compositor moves the light); the link runs at 60 for a moment so a re-centre is timely.
    func scrolled() {
        lastScroll = CACurrentMediaTime()
        if !fastLink, link != nil { fastLink = true; applyRate() }
    }

    /// The page's card frames changed (an update, a relayout with measured bands, a corrected offset). The cells move in this layout
    /// pass and the light is drawn for the new frames in the same pass (`syncDraw`), never at the old places for a frame.
    private var framesDirty = false
    func framesMoved() { framesDirty = true }


    func syncDraw() {
        guard framesDirty else { return }
        framesDirty = false
        guard wanted, front.valid, host?.zoom == nil else { markDirty(); return }
        render(into: front, origin: front.origin, recentre: false, sync: true)
    }

    private func markDirty() {
        dirty = true
        updateLink()
    }

    /// The zoom hides the light and the landing brings it back. While it fades out (`fadeOut`) it follows its cards (`follow`); it is
    /// drawn once for the landing's layout, so the fade-in has no cards to follow.
    nonisolated static let fadeOut = 0.12
    private var followUntil = 0.0
    private var fadeOutPending = false
    private var graceFadeOut: DispatchWorkItem?
    nonisolated static let fadeOutGrace = 0.25
    private func startFadeOut() {
        guard suspended, fadeOutPending else { return }
        fadeOutPending = false
        followUntil = CACurrentMediaTime() + Self.fadeOut
        UIView.animate(withDuration: Self.fadeOut) { self.alpha = 0 } completion: { [weak self] _ in
            guard let self, self.suspended else { return }
            self.updateLink()
        }
    }
    private var fadeInPending = false
    private var landedAt = 0.0
    nonisolated static let fadeInPatience = 0.5
    /// The landing's fade-in starts when every card on screen has its light for the new level (or after `fadeInPatience`).
    private func fadeInWhenReady(_ cards: [LibraryGlowCard], at now: Double) {
        guard fadeInPending else { return }
        let ready = !cards.isEmpty && cards.allSatisfy { entries[$0.key]?.pending != true }
        guard ready || now - landedAt > Self.fadeInPatience else { dirty = true; return }
        fadeInPending = false
        UIView.animate(withDuration: 0.35) { self.alpha = 1 }
    }
    var following: Bool { suspended && CACurrentMediaTime() < followUntil }

    func setSuspended(_ now: Bool) {
        guard now != suspended else { return }
        suspended = now
        if now {
            fadeInPending = false
            // The fade-out and the follow window start with the first frame the cards are placed (`follow`), not when the stage is
            // handed over: a light on its own clock would show the at-rest light over cards that have moved. A stage that never
            // places a card still fades it after `fadeOutGrace`.
            followUntil = .greatestFiniteMagnitude
            fadeOutPending = true
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.startFadeOut() }
            }
            graceFadeOut?.cancel()
            graceFadeOut = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOutGrace, execute: work)
        } else {
            fadeOutPending = false
            graceFadeOut?.cancel()
            graceFadeOut = nil
            for view in surfaces { view.valid = false }
            swapping = false
            updateLink()
            dirty = true
            // The light comes back once the cards on screen have the light made for this level (`fadeInWhenReady`).
            landedAt = CACurrentMediaTime()
            fadeInPending = true
            tick()
        }
    }

    // MARK: Press

    func setPressed(_ key: String, _ pressed: Bool) {
        let now = CACurrentMediaTime()
        var set = tweens[key] ?? TweenSet()
        let closed = Double(LibraryCardArtworkPress.pressedScale) / Double(1 + 2 * Self.spread)
        if pressed {
            set.rays.move(to: 1, now: now, duration: 0.2, curve: .easeOut)
            set.scale.move(to: closed, now: now, duration: 0.55, curve: .easeInOut)
            set.fade.move(to: 0, now: now, duration: 0.6, curve: .easeIn)
        } else {
            set.rays.move(to: 0, now: now, duration: 0.9, curve: .easeIn)
            set.scale.move(to: 1, now: now, duration: 1.6, curve: .easeInOut)
            set.fade.move(to: 1, now: now, duration: 1.3, curve: .easeOut)
        }
        tweens[key] = set
        animating = true
        applyRate()
        markDirty()
    }

    // MARK: Drawing

    private func tick() {
        guard wanted, let host, viewport.width > 0, UIApplication.shared.applicationState != .background else { return }
        let now = CACurrentMediaTime()
        if fastLink, now - lastScroll > 0.4 { fastLink = false; applyRate() }
        let collection = host.collectionView!
        let top = Double(collection.bounds.minY)
        let velocity = lastTopTime > 0 && now > lastTopTime ? (top - lastTop) / (now - lastTopTime) : 0
        lastTop = top; lastTopTime = now
        let height = Double(viewport.height)
        let lead = max(0.1 * height, abs(velocity) * 0.12)
        let near = !front.valid || top - lead < Double(front.origin) || top + height + lead > Double(front.origin) + Double(front.bounds.height)
        let animate = dirty || animating || (!UIAccessibility.isReduceMotionEnabled && now - lastAnimation >= 1.0 / 30 - 0.004)
        guard near || animate else { return }
        guard !renderBusy else {
            return
        }
        if near, !swapping || !front.valid {
            let ahead = max(-0.8, min(0.8, velocity * 0.15 / (height * Self.overscan)))
            let origin = CGFloat(top - height * Self.overscan * (1 - ahead))
            let target = front.valid ? (surfaces[0] === front ? surfaces[1] : surfaces[0]) : front
            render(into: target, origin: origin, recentre: true)
        } else if animate {
            render(into: front, origin: front.origin, recentre: false)
        }
    }

    private func coverLanded(_ key: String) {
        var changed = false
        for (id, entry) in entries where entry.sourceKey == key && (entry.texture == nil || !entry.builtExact) {
            entries[id]?.stale = true       // made again from the better bitmap
            changed = true
        }
        if changed { markDirty() }
    }

    private func render(into target: LibraryGlowSurface, origin: CGFloat, recentre: Bool, sync: Bool = false) {
        guard let host else { return }
        let began = CACurrentMediaTime()
        dirty = false
        lastAnimation = began
        let height = target.bounds.height
        let cards = host.glowCards(between: origin, and: origin + height)
        let dark = traitCollection.userInterfaceStyle == .dark
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let time = Date().timeIntervalSinceReferenceDate
        var items: [LibraryGlowJob.Item] = []
        items.reserveCapacity(cards.count)
        var anyRunning = false
        for card in cards {
            var entry = entries[card.key] ?? Entry()
            entry.lastSeen = began
            let tween = tweens[card.key]
            if let tween, tween.rays.running(at: began) || tween.scale.running(at: began) || tween.fade.running(at: began) { anyRunning = true }
            prepare(&entry, card: card, dark: dark)
            entries[card.key] = entry
            let art = LibraryGridGeometry.artworkRect(cardWidth: card.frame.width).offsetBy(dx: card.frame.minX, dy: card.frame.minY - origin)
            if let made = item(entry, art: art, seed: card.seed, tween: tween, dark: dark, at: began) {
                items.append(made)
            }
        }
        fadeInWhenReady(cards, at: began)
        if animating && !anyRunning {
            animating = false
            tweens = tweens.filter { $0.value.rays.target != 0 }   // a card still held keeps its closed state
            applyRate()
        }
        if entries.count > 120 { prune() }

        target.origin = origin
        if recentre {
            target.frame = CGRect(x: 0, y: origin, width: target.bounds.width, height: height)
            swapping = true
        }
        let token = target
        var presentedHandler: (@Sendable () -> Void)?
        if recentre {
            presentedHandler = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.presented(token) } }
            }
        }
        let completedHandler: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.renderBusy = false } }
        }
        let job = LibraryGlowJob(layer: target.metal, size: target.metal.drawableSize, items: items, dark: dark,
                                 reduceMotion: reduceMotion, time: time, onPresented: presentedHandler, onCompleted: completedHandler, sync: sync)
        renderBusy = true
        let pipeline = pipeline, queue = queue, clamp = clamp, wrap = wrap
        if sync { Self.encode(job, pipeline: pipeline, queue: queue, clamp: clamp, wrap: wrap) }
        else { renderQueue.async { Self.encode(job, pipeline: pipeline, queue: queue, clamp: clamp, wrap: wrap) } }
        if recentre {
            // A presented handler that never comes (a dropped drawable) must not hold the next re-centre for ever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { if let self, !token.valid || token !== self.front { self.swapping = false } }
            }
        }
    }

    /// One card's light: its quad (the glow's frame and its reach, scaled by the press) around the artwork `art` (in the
    /// surface's points), and the strengths.
    private func item(_ entry: Entry, art: CGRect, seed: Int, tween: TweenSet?, dark: Bool, at now: Double) -> LibraryGlowJob.Item? {
        guard let texture = entry.texture, let rays = entry.rays, let movie = entry.movie else { return nil }
        // The light is sized by its card's width: a texture made at another level's width is not drawn until the one
        // for this level has been made (otherwise a landing would show the old level's penumbra for a moment).
        guard entry.artPixels == entry.wantedArtPixels else { return nil }
        let k = Self.artPixels.width / CGFloat(entry.artPixels)
        let spread = art.width * k * Self.spread
        let glow = art.insetBy(dx: -spread, dy: -spread)
        let reach = art.width * k * Self.reach
        let quad = glow.insetBy(dx: -reach, dy: -reach)
        let scaleNow = tween?.scale.value(at: now) ?? 1
        let rect = CGRect(x: quad.midX - quad.width * scaleNow / 2, y: quad.midY - quad.height * scaleNow / 2,
                          width: quad.width * scaleNow, height: quad.height * scaleNow)
        let strength = (dark ? 0.92 : 0.8) * (entry.dimmed ? 0.3 : 1)
        return .init(texture: texture, rays: rays, movie: movie, rect: rect, size: glow.size, art: art.size, reach: Float(reach),
                     strength: Float(strength * (tween?.fade.value(at: now) ?? 1)),
                     raysAmount: Float(tween?.rays.value(at: now) ?? 0), seed: seed)
    }

    /// The light fading out for a zoom, on its cards: `placed` holds the artwork rect the stage puts each card at in this frame, in
    /// the page's coordinates. Nothing is looked up or laid out here, and a card the light has no texture for is just not lit.
    func follow(_ placed: [(key: String, art: CGRect, alpha: CGFloat)]) {
        startFadeOut()
        guard following, front.valid else { return }
        let began = CACurrentMediaTime()
        let dark = traitCollection.userInterfaceStyle == .dark
        let origin = front.origin
        var items: [LibraryGlowJob.Item] = []
        items.reserveCapacity(placed.count)
        for card in placed {
            guard let entry = entries[card.key], var made = item(entry, art: card.art.offsetBy(dx: 0, dy: -origin), seed: entry.seed,
                                                                 tween: tweens[card.key], dark: dark, at: began) else { continue }
            made.strength *= Float(card.alpha)
            items.append(made)
        }
        let job = LibraryGlowJob(layer: front.metal, size: front.metal.drawableSize, items: items, dark: dark,
                                 reduceMotion: UIAccessibility.isReduceMotionEnabled,
                                 time: Date().timeIntervalSinceReferenceDate, onPresented: nil,
                                 onCompleted: { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.renderBusy = false } } },
                                 sync: true)
        renderBusy = true
        let pipeline = pipeline, queue = queue, clamp = clamp, wrap = wrap
        // Drawn and presented in this frame's transaction, for every frame (never skipped): a light drawn later would stay where the cards were.
        Self.encode(job, pipeline: pipeline, queue: queue, clamp: clamp, wrap: wrap)
    }

    /// The pinch's first frames, before its stage is shown, place the live cards by the session's rule
    /// (`LibraryGridZoomStart.applyBridgeTransform`). The light would stay at rest, at the old size, until the session takes over, so
    /// from the first such frame it leaves rest (suspended) and follows the cards where they were just placed.
    func followBridge(_ placed: [(key: String, art: CGRect, alpha: CGFloat)]) {
        setSuspended(true)
        follow(placed)
    }

    private func presented(_ surface: LibraryGlowSurface) {
        surface.valid = true
        surface.isHidden = false
        for other in surfaces where other !== surface { other.isHidden = true; other.valid = false }
        front = surface
        swapping = false
    }

    /// The background half: acquire a drawable (this thread may wait for it, main does not), encode one quad
    /// per card, present. Reads nothing that main writes.
    nonisolated private static func encode(_ job: LibraryGlowJob, pipeline: MTLRenderPipelineState, queue: MTLCommandQueue,
                                           clamp: MTLSamplerState, wrap: MTLSamplerState) {
        guard job.size.width > 0 else { job.onCompleted(); return }
        if job.sync { job.layer.presentsWithTransaction = true }
        let next = job.layer.nextDrawable()
        guard let drawable = next else { job.onCompleted(); return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { job.onCompleted(); return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(clamp, index: 0)
        encoder.setFragmentSamplerState(wrap, index: 1)
        let n = AmbientMovie.samples
        var params = [Float](repeating: 0, count: 15 + 3 * n)
        let w = Double(job.layer.bounds.width), h = Double(job.layer.bounds.height)
        for item in job.items {
            let f = item.movie.frame(at: job.reduceMotion ? 0 : job.time)
            let glow = item.rect
            params[0] = Float(glow.minX / w * 2 - 1)
            params[1] = Float(1 - glow.minY / h * 2)
            params[2] = Float(glow.maxX / w * 2 - 1)
            params[3] = Float(1 - glow.maxY / h * 2)
            params[4] = Float(f.hue)
            params[5] = job.dark ? 0.3 : 0
            params[6] = item.strength
            params[7] = item.raysAmount
            params[8] = job.reduceMotion ? 0 : Float(1.2 * sin(job.time * 0.12 + Double(item.seed % 97)) * .pi / 180)
            params[9] = Float(item.size.width); params[10] = Float(item.size.height)
            params[11] = job.dark ? 1 : 0
            params[12] = item.reach
            params[13] = Float(item.art.width); params[14] = Float(item.art.height)
            for i in 0..<n {
                params[15 + i] = Float(f.turned[i])
                params[15 + n + i] = Float(f.mirrored[i])
                params[15 + 2 * n + i] = Float(f.light[i])
            }
            params.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            encoder.setFragmentTexture(item.texture, index: 0)
            encoder.setFragmentTexture(item.rays, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        buffer.addCompletedHandler { _ in job.onCompleted() }
        if let onPresented = job.onPresented {
            #if targetEnvironment(simulator)
            buffer.addScheduledHandler { _ in onPresented() }      // (the simulator SDK has no presented handler)
            #else
            drawable.addPresentedHandler { _ in onPresented() }
            #endif
        }
        if job.sync {
            buffer.commit()
            buffer.waitUntilScheduled()
            drawable.present()
            job.layer.presentsWithTransaction = false
        } else {
            buffer.present(drawable)
            buffer.commit()
        }
    }

    private func prune() {
        let kept = entries.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(80)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        if raysBySeed.count > 400 { raysBySeed = [:] }
    }

    // MARK: Per-card resources

    private func prepare(_ entry: inout Entry, card: LibraryGlowCard, dark: Bool) {
        if entry.movie == nil || entry.seed != card.seed {
            entry.movie = AmbientMovie(seed: card.seed)
            entry.seed = card.seed
            entry.rays = nil
        }
        if entry.rays == nil {
            if let known = raysBySeed[card.seed] { entry.rays = known }
            else if let made = makeRays(seed: card.seed) { raysBySeed[card.seed] = made; entry.rays = made }
        }
        entry.sourceKey = card.sourceKey
        entry.dimmed = card.dimmed
        let artWidth = LibraryGridGeometry.artworkRect(cardWidth: card.frame.width).width
        let artPixels = Self.artPixels(scale: Self.scale(artWidth: artWidth, reference: referenceArt))
        let style = "\(dark ? 1 : 0)\(card.dimmed ? 1 : 0)-\(artPixels)"
        entry.wantedArtPixels = artPixels
        guard entry.texture == nil || entry.style != style || entry.stale, !entry.pending,
              var source = LibraryGridHostController.coverSource(card.card, page: host?.page) else { return }
        source.spot = false   // the glow is lit from the plain art
        guard let found = LibraryCoverCache.shared.image(for: source, pixelWidth: 96), let cg = found.image.cgImage else { return }
        entry.pending = true
        entry.stale = false
        let key = card.key, dimmed = card.dimmed, exact = found.exact
        queueWork.async { [weak self] in
            let texture = self.flatMap { $0.makeTexture(LibraryGlowBase.render(cover: cg, dark: dark, dimmed: dimmed, artPixels: artPixels), artPixels: artPixels) }
            DispatchQueue.main.async {
                guard let self else { return }
                var current = self.entries[key] ?? Entry()
                current.pending = false
                if let texture {
                    current.texture = texture
                    current.artPixels = artPixels
                    current.style = style
                    current.builtExact = exact
                }
                self.entries[key] = current
                self.markDirty()
            }
        }
    }

    nonisolated private func makeTexture(_ pixels: [UInt16], artPixels: Int) -> MTLTexture? {
        let size = Self.textureSize(artPixels: artPixels)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size.width,
                                                                  height: size.height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: texture.width * 8)
        }
        return texture
    }

    private func makeRays(seed: Int) -> MTLTexture? {
        let count = 60
        var r = AmbientRandom(seed: seed &* 31 &+ 7)
        var stops: [(at: Double, level: Double)] = []
        var at = 0.0
        while at < 1 {
            let width = (0.5 + r.unit()) / Double(count)
            let level = pow(r.unit(), 0.7)
            stops.append((at, level))
            stops.append((min(1, at + width * 0.55), level))
            at += width
        }
        stops.append((1, stops[0].level))
        let n = 2048
        var bytes = [UInt8](repeating: 0, count: n)
        var k = 0
        for i in 0..<n {
            let x = Double(i) / Double(n)
            while k + 1 < stops.count - 1, stops[k + 1].at <= x { k += 1 }
            let a = stops[k], b = stops[k + 1]
            let t = b.at > a.at ? min(1, max(0, (x - a.at) / (b.at - a.at))) : 0
            bytes[i] = UInt8(max(0, min(255, ((a.level + (b.level - a.level) * t) * 255).rounded())))
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: n, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, n, 1), mipmapLevel: 0, withBytes: bytes, bytesPerRow: n)
        return texture
    }
}

/// The card's blurred artwork for its glow (AmbientGlow.layer, once): the cover aspect-filled into the art rectangle of a
/// frame-sized buffer, two copies (scaled 1.09 and blurred 0.07 of the art's width; scaled 1.03, blurred 0.03, at 0.75), then
/// saturation and brightness. The blur is a true gaussian in floating point on a buffer wide enough for all of it, so the light
/// dies away inside the texture instead of ending in a cut, and its faint tail keeps its colour (half-float premultiplied RGBA).
/// Pure CPU work, any thread.
enum LibraryGlowBase {
    static func render(cover: CGImage, dark: Bool, dimmed: Bool, artPixels: Int) -> [UInt16] {
        let size = LibraryGlowView.textureSize(artPixels: artPixels)
        let width = size.width, height = size.height
        let count = width * height
        let art = CGSize(width: CGFloat(artPixels), height: CGFloat(artPixels * 3 / 2))
        // The blur and the copies' scale are the ordinary ones in pixels of the ordinary art (100 wide); a smaller art is the same light around a smaller card.
        let ordinary = LibraryGlowView.artPixels.width, k = Double(ordinary / art.width)
        let artRect = CGRect(x: (CGFloat(width) - art.width) / 2, y: (CGFloat(height) - art.height) / 2, width: art.width, height: art.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        func context() -> CGContext {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info)!
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)         // y down, as the glow's frame
            ctx.interpolationQuality = .high
            return ctx
        }
        let source = context()
        let fill = max(artRect.width / CGFloat(cover.width), artRect.height / CGFloat(cover.height))
        let drawn = CGSize(width: CGFloat(cover.width) * fill, height: CGFloat(cover.height) * fill)
        source.saveGState()
        source.clip(to: artRect)
        source.translateBy(x: artRect.midX, y: artRect.midY)
        source.scaleBy(x: 1, y: -1)           // upright in the flipped context
        source.draw(cover, in: CGRect(x: -drawn.width / 2, y: -drawn.height / 2, width: drawn.width, height: drawn.height))
        source.restoreGState()
        let sourceImage = source.makeImage()!

        func layer(scale: CGFloat, sigma: Double) -> [[Float]] {
            let ctx = context()
            ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
            ctx.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
            let kernel = gaussian(sigma)
            return (0..<4).map { channel in
                var plane = [Float](repeating: 0, count: count)
                for i in 0..<count { plane[i] = Float(bytes[i * 4 + channel]) / 255 }
                blur(&plane, width: width, height: height, kernel: kernel)
                return plane
            }
        }
        let wash = layer(scale: 1 + 0.09 * CGFloat(k), sigma: Double(ordinary) * 0.07)
        let band = layer(scale: 1 + 0.03 * CGFloat(k), sigma: Double(ordinary) * 0.03)
        let saturation: Float = dimmed ? 1.15 : (dark ? 1.5 : 1.9)
        let brightness: Float = dark ? 0 : (dimmed ? 0.04 : 0.12)
        var pixels = [UInt16](repeating: 0, count: count * 4)
        for i in 0..<count {
            let ba = band[3][i] * 0.75
            let alpha = wash[3][i] * (1 - ba) + ba
            guard alpha > 1e-5 else { continue }
            var rgb = SIMD3<Float>(0, 0, 0)
            for c in 0..<3 { rgb[c] = (wash[c][i] * (1 - ba) + band[c][i] * 0.75) / alpha }
            let lum = 0.213 * rgb[0] + 0.715 * rgb[1] + 0.072 * rgb[2]
            for c in 0..<3 {
                let v = min(1, max(0, lum + saturation * (rgb[c] - lum) + brightness))
                pixels[i * 4 + c] = Float16(v * alpha).bitPattern
            }
            pixels[i * 4 + 3] = Float16(alpha).bitPattern
        }
        return pixels
    }

    private static func gaussian(_ sigma: Double) -> [Float] {
        let radius = max(1, Int((sigma * 3.5).rounded(.up)))
        let taps = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let sum = taps.reduce(0, +)
        return taps.map { $0 / sum }
    }

    private static func blur(_ plane: inout [Float], width: Int, height: Int, kernel: [Float]) {
        var result = [Float](repeating: 0, count: plane.count)
        plane.withUnsafeMutableBytes { source in
            result.withUnsafeMutableBytes { target in
                var from = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var to = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                kernel.withUnsafeBufferPointer { taps in
                    _ = vImageSepConvolve_PlanarF(&from, &to, nil, 0, 0, taps.baseAddress, UInt32(taps.count), taps.baseAddress, UInt32(taps.count),
                                                  0, 0, vImage_Flags(kvImageBackgroundColorFill))
                }
            }
        }
        plane = result
    }
}
