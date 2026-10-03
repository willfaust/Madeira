import Metal
import QuartzCore
import UIKit

/// Liquid metal in place of Liquid Glass's refraction, on the navigation bar's
/// bar-button pills, keeping everything else the system does with them: their shape,
/// the morph between item sets, merges, the press stretch, the rim highlight, the icons.
///
/// How the system draws such a pill (iOS 26/27, seen in the layer tree): the icons are
/// drawn through portals; a CABackdropLayer with the `glassBackground` filter refracts
/// what is behind, shaped by a CASDFLayer whose CASDFElementLayer children are the
/// pill's live signed-distance shape (they are what UIKit animates); a second CASDFLayer
/// draws the rim highlight from a portal of those same elements. GlassSkin leaves all of
/// that in place, sets the backdrop's opacity to 0, and inserts right above it a group of
/// two layers: a CASDFLayer with a fill effect over another portal of the elements (the
/// live shape, drawn by the render server), and a CAMetalLayer painting the metal
/// (LiquidMetalSkin.metal) composited `sourceIn`, so the metal shows exactly where the
/// shape is, frame for frame. Using the SDF layer as a plain `mask` does not work; the
/// group compositing does.
///
/// UIKit builds new glass layers when a bar's items change (a morph), so a run-loop
/// observer ordered just before Core Animation's commit skins any new pill in the same
/// transaction that creates it (a display-link check left one frame of glass showing),
/// and a pre-commit handler does it again after layout inside each commit, where SwiftUI
/// makes its own changes to the pill.
/// Known issue: in the simulator, a layer added to SwiftUI's glass container sometimes
/// makes SwiftUI start a morph back to a wider item set from a far wider pill (for about
/// 0.2 s), which stock glass never does; the skin shows it. Placing the skin outside
/// SwiftUI's tree avoids that but gets drawn over dark by the pill's own stack.
/// Only pills whose content is bar items are skinned (their content sits in a
/// UIPlatformGlassInteractionView); the search field and other glass stay as they are.
///
/// The tab bar's glass is UIKit's own, built the same way: its platter becomes metal
/// like a pill, and the lens that lifts out of the selected tab under a finger keeps its
/// glass with metal only around its edge, dissolving into the glass toward the middle
/// (`rim`). The navigation bar's search field gets the same rim. Everything is found by class name and key-value coding; if any of it is
/// missing the glass stays as it is. Settings › Appearance › Liquid metal (LiquidMetalSetting,
/// env.MADEIRA_LIQUID_METAL in madeira.cfg) turns it on and off at once, with the Desktop
/// button's liquid metal: off, the app shows plain Liquid Glass.
@MainActor
final class GlassSkin: NSObject {
    static let shared = GlassSkin()
    static var enabled: Bool { LiquidMetalSetting.shared.on }
    private static let groupName = "madeira.glass-skin"

    private var observer: CFRunLoopObserver?
    private var link: CADisplayLink?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var bars: [WeakView] = []
    private var lastBarSearch: CFTimeInterval = 0
    private var skins: [Skin] = []
    private let started = CACurrentMediaTime()

    private struct WeakView { weak var view: UIView? }
    private struct Skin {
        weak var container: CALayer?
        weak var source: CALayer?
        let group: CALayer
        let metal: CAMetalLayer
        /// Metal only around the shape's edge, over the glass (the tab bar's lens).
        let rim: Bool
        /// The rim's lens (_UILiquidLensView), whose lift progress the rim follows.
        weak var lens: UIView?
        /// A navigation bar pill, which a context menu from one of its buttons covers.
        let veils: Bool
    }

    /// `fadeIn`: liquid metal was just turned on in Settings, so the pills it finds in the
    /// next moment fade from their glass into metal instead of switching.
    func start(fadeIn: Bool = false) {
        guard Self.enabled, observer == nil, Self.privateClassesPresent, preparePipeline() else { return }
        fadeInUntil = fadeIn ? CACurrentMediaTime() + 0.5 : 0
        // Core Animation commits in an observer of order 2,000,000; run just before it.
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                      true, 1_999_999) { _, _ in
            MainActor.assumeIsolated {
                GlassSkin.shared.attach()
                GlassSkin.shared.attachAgainAfterLayout()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        link = CADisplayLink(target: self, selector: #selector(renderAll))
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link?.add(to: .main, forMode: .common)
        LogStore.shared.log("[glass-skin] started")
    }

    /// Takes the skin off every pill (liquid metal turned off in Settings): the metal fades
    /// out over the system's glass, and nothing more is drawn or attached.
    func stop() {
        guard let observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = nil
        link?.invalidate()
        link = nil
        let fading = skins
        CATransaction.begin()
        CATransaction.setAnimationDuration(UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.35)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { for skin in fading { skin.group.removeFromSuperlayer() } } }
        for skin in fading {
            skin.group.opacity = 0
            if !skin.rim, let backdrop = skin.container?.sublayers?.first(where: { Self.isClass($0, "CABackdropLayer") }) {
                backdrop.opacity = 1
            }
        }
        CATransaction.commit()
        skins.removeAll()
        steadyRects.removeAll()
        bars.removeAll()
        veiled = false
        LogStore.shared.log("[glass-skin] stopped")
    }

    /// SwiftUI updates a pill's layers during Core Animation's commit itself (its hosting
    /// view lays out and renders there), after the run-loop observer: when a morph settles
    /// it swaps the shape's element source and resets the backdrop that way, and one frame
    /// of plain glass showed. So attach runs again inside each commit, in its pre-commit
    /// phase (after layout, before the tree goes to the render server), through
    /// CATransaction's commit handlers (+addCommitHandler:forPhase:, phase 1 = pre-commit;
    /// the declaration WebKit uses). Missing, only the observer runs.
    private typealias AddCommitHandler = @convention(c) (AnyClass, Selector, @escaping @convention(block) () -> Void, UInt32) -> Void
    private static let addCommitHandlerSelector = NSSelectorFromString("addCommitHandler:forPhase:")
    private static let addCommitHandler: AddCommitHandler? = {
        guard let method = class_getClassMethod(CATransaction.self, addCommitHandlerSelector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: AddCommitHandler.self)
    }()
    private var commitHandlerPending = false
    private var fadeInUntil: CFTimeInterval = 0

    private func attachAgainAfterLayout() {
        guard observer != nil, !commitHandlerPending, let add = Self.addCommitHandler else { return }
        commitHandlerPending = true
        add(CATransaction.self, Self.addCommitHandlerSelector, {
            MainActor.assumeIsolated {
                GlassSkin.shared.commitHandlerPending = false
                GlassSkin.shared.attach()
            }
        }, 1)
    }

    private static var privateClassesPresent: Bool {
        ["CASDFLayer", "CASDFFillEffect", "CAPortalLayer", "CABackdropLayer"].allSatisfy { NSClassFromString($0) != nil }
    }

    private func preparePipeline() -> Bool {
        if pipeline != nil { return true }
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "liquidMetalSkinVertex"),
              let fragment = library.makeFunction(name: "liquidMetalSkinFragment") else { return false }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return false }
        self.device = device
        self.queue = device.makeCommandQueue()
        self.pipeline = pipeline
        return true
    }

    // MARK: Attaching

    private func attach() {
        guard observer != nil else { return }   // stopped (a commit handler may still fire)
        // The bars persist; a navigation bar's platter containers do not (opening and
        // closing a bar button's menu builds a new one), so the glass is looked up under the
        // bars on every pass (a walk of a few dozen layers) and only the bars are cached.
        let now = CACurrentMediaTime()
        if bars.allSatisfy({ $0.view?.window == nil }) || now - lastBarSearch > 1 {
            lastBarSearch = now
            bars = findBars().map { WeakView(view: $0) }
        }
        for (i, skin) in skins.enumerated().reversed() where skin.container?.superlayer == nil {
            skin.group.removeFromSuperlayer()
            skins.remove(at: i)
        }
        let menu = contextMenuShowing()
        if menu != veiled {
            veiled = menu
            for skin in skins where skin.veils { veil(skin, menu) }
        }
        for bar in bars.compactMap(\.view) where bar.window != nil {
            if bar is UITabBar {
                skinTabBar(bar)
            } else {
                for platter in Self.platters(in: bar) { skinNewPills(in: platter) }
                for search in Self.searchBars(in: bar) { skinGlass(in: [search.layer], rimEverywhere: true) }
            }
        }
        // ml1216: the link draws only while a pill is skinned (renderAll pauses it).
        link?.isPaused = skins.isEmpty
    }

    /// A context menu from a bar button (the sort menu) grows out of the pill and, closing,
    /// shrinks back into it; then UIKit keeps a glass copy of the pill over the real one
    /// for about a second and removes it in one frame. Over metal that read as a flash, so
    /// while a menu is up the navigation bar pills show their own glass again (unseen,
    /// under the menu), and when it is gone the metal fades back in.
    private var veiled = false

    private func contextMenuShowing() -> Bool {
        // The menu's container is added at the top of the window: only those levels are looked at.
        UIApplication.shared.connectedScenes.flatMap { ($0 as? UIWindowScene)?.windows ?? [] }.contains { window in
            window.subviews.contains { top in
                NSStringFromClass(type(of: top)).contains("ContextMenuContainer")
                    || top.subviews.contains { NSStringFromClass(type(of: $0)).contains("ContextMenuContainer") }
            }
        }
    }

    private func veil(_ skin: Skin, _ on: Bool) {
        guard let backdrop = skin.container?.sublayers?.first(where: { Self.isClass($0, "CABackdropLayer") }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        skin.group.opacity = on ? 0 : 1
        backdrop.opacity = on ? 1 : 0
        CATransaction.commit()
        if !on { fadeIn(skin, over: backdrop) }
    }

    /// The metal fades in over the system's glass (whose backdrop fades out under it).
    private func fadeIn(_ skin: Skin, over backdrop: CALayer?) {
        let pairs: [(CALayer, Float, Float)] = [(skin.group, 0, 1)] + (backdrop.map { [($0, Float(1), Float(0))] } ?? [])
        for (layer, from, to) in pairs {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = to
            fade.duration = UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.5
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "madeira.glass-skin.fade")
        }
    }

    /// The navigation bars and tab bars, in every window.
    private func findBars() -> [UIView] {
        UIApplication.shared.connectedScenes.flatMap { ($0 as? UIWindowScene)?.windows ?? [] }.flatMap { bars(in: $0) }
    }

    /// A navigation bar's bar-button platter containers.
    private static func platters(in bar: UIView) -> [UIView] {
        var found: [UIView] = []
        func walk(_ view: UIView) {
            if NSStringFromClass(type(of: view)).contains("NavigationBarPlatterContainer") { found.append(view); return }
            for sub in view.subviews { walk(sub) }
        }
        walk(bar)
        return found
    }

    /// A navigation bar's search bars (a stacked search controller's field).
    private static func searchBars(in bar: UIView) -> [UISearchBar] {
        if let search = bar as? UISearchBar { return [search] }
        return bar.subviews.flatMap { searchBars(in: $0) }
    }

    private func bars(in view: UIView) -> [UIView] {
        if view is UINavigationBar || view is UITabBar { return [view] }
        return view.subviews.flatMap { bars(in: $0) }
    }

    private func skinNewPills(in platter: UIView) {
        // A pill's glass container: a layer holding a CABackdropLayer.
        func walk(_ layer: CALayer) {
            if let sublayers = layer.sublayers, sublayers.contains(where: { Self.isClass($0, "CABackdropLayer") }) {
                if let i = skins.firstIndex(where: { $0.container === layer }) {
                    refresh(i)
                } else if let root = layer.superlayer, Self.holdsBarItems(root) {
                    skin(container: layer, rim: false, veils: true)
                }
            }
            for sub in layer.sublayers ?? [] where sub.name != Self.groupName { walk(sub) }
        }
        walk(platter.layer)
    }

    /// A tab bar's glass: the platter behind its tabs, and the lens that lifts out of the
    /// selected tab under a finger (built on its first lift). Each is a UIKit glass group
    /// whose _UIMaterialDefinitionView holds the glassBackground backdrop and the highlight,
    /// in the layers of the bar's group view: its own and a second one it hosts beside it
    /// (a _UIMultiLayer, where the platter's glass lives).
    private func skinTabBar(_ bar: UIView) {
        var host: UIView = bar
        var ancestor = bar.superview
        while let view = ancestor {
            if NSStringFromClass(type(of: view)).contains("TabBarGroupView") { host = view; break }
            ancestor = view.superview
        }
        let roots = [host.layer] + (host.superview?.layer.sublayers ?? []).filter { $0.delegate === host && $0 !== host.layer }
        skinGlass(in: roots, rimEverywhere: false)
    }

    /// UIKit glass under `roots`: every _UIMaterialDefinitionView (the glassBackground
    /// backdrop and the highlight), as metal, or as a rim inside the tab bar's lens or
    /// everywhere with `rimEverywhere` (the search field).
    private func skinGlass(in roots: [CALayer], rimEverywhere: Bool) {
        // The lens view itself (its own subviews' classes are nested in it and carry its name).
        let lensClass: AnyClass? = NSClassFromString("_UILiquidLensView")
        func walk(_ layer: CALayer, lens: UIView?) {
            let view = layer.delegate as? UIView
            let name = view.map { NSStringFromClass(type(of: $0)) } ?? ""
            let lens = lensClass.flatMap { cls in view.flatMap { $0.isKind(of: cls) ? $0 : nil } } ?? lens
            if name.contains("MaterialDefinitionView") {
                if let i = skins.firstIndex(where: { $0.container === layer }) {
                    refresh(i)
                } else {
                    skin(container: layer, rim: rimEverywhere || lens != nil, lens: lens)
                }
                return
            }
            for sub in layer.sublayers ?? [] where sub.name != Self.groupName { walk(sub, lens: lens) }
        }
        for root in roots { walk(root, lens: nil) }
    }

    /// UIKit and SwiftUI keep working on a pill after it is skinned: they reset the
    /// backdrop, hand the shape a new element source when a morph settles, and drive a
    /// morph by setting the geometry frame by frame. Keep the refraction hidden, follow the
    /// source, and keep the skin's shape on the system's. The group is never moved once
    /// inserted: SwiftUI manages the container's sublayers itself.
    private func refresh(_ index: Int) {
        let skin = skins[index]
        guard let container = skin.container, let sublayers = container.sublayers,
              let backdrop = sublayers.first(where: { Self.isClass($0, "CABackdropLayer") }),
              let highlight = sublayers.first(where: { Self.isClass($0, "CASDFLayer") }) else { return }
        if !skin.rim, !(skin.veils && veiled), backdrop.opacity != 0 { backdrop.opacity = 0 }
        // The bar can grow (the tab bar spans the screen in landscape and its platter moves
        // to the middle): the metal grows with it. Never shrunk, so a morph that narrows the
        // bar for a moment does not reallocate the drawable.
        if !skin.rim, let root = container.superlayer {
            let cover = Self.cover(root.bounds, rim: false)
            if !skin.group.bounds.contains(cover) {
                let grown = skin.group.bounds.union(cover)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                skin.group.frame = grown
                skin.group.bounds = grown
                skin.metal.frame = grown
                skin.metal.bounds = grown
                skin.metal.drawableSize = CGSize(width: grown.width * skin.metal.contentsScale, height: grown.height * skin.metal.contentsScale)
                CATransaction.commit()
            }
        }
        let shapes = (skin.group.sublayers ?? []).filter { Self.isClass($0, "CASDFLayer") }
        for shape in shapes { mirror(highlight, onto: shape) }
        guard let current = highlight.sublayers?.first?.value(forKey: "sourceLayer") as? CALayer,
              current !== skin.source else { return }
        for shape in shapes { shape.sublayers?.first?.setValue(current, forKey: "sourceLayer") }
        skins[index] = Skin(container: container, source: current, group: skin.group, metal: skin.metal, rim: skin.rim, lens: skin.lens, veils: skin.veils)
    }

    /// The skin goes into the pill's glass container, right above the backdrop, so it sits
    /// under the icons and the rim highlight. (Beneath SwiftUI's hosting view instead, the
    /// pill's own stack draws over it dark.) A rim skin leaves the backdrop showing.
    private func skin(container: CALayer, rim: Bool, lens: UIView? = nil, veils: Bool = false) {
        guard let root = container.superlayer,
              let sublayers = container.sublayers,
              let backdrop = sublayers.first(where: { Self.isClass($0, "CABackdropLayer") }),
              let highlight = sublayers.first(where: { Self.isClass($0, "CASDFLayer") }),
              let highlightPortal = highlight.sublayers?.first,
              let source = highlightPortal.value(forKey: "sourceLayer") as? CALayer,
              let fillClass = NSClassFromString("CASDFFillEffect") as? NSObject.Type,
              let device else { return }

        // All of the pill's layers share one coordinate space (bounds origin = frame
        // origin); one generous rect around the bar covers every place the pill can move to.
        let cover = Self.cover(root.bounds, rim: rim)
        let group = CALayer()
        group.name = Self.groupName
        group.frame = cover
        group.bounds = cover

        // The shape layer takes the system's highlight SDF layer's geometry (mirror()): the
        // render server clips the shape to that layer's bounds, and during a morph the
        // elements alone can be much wider than the pill.
        let fill = fillClass.init()
        // ml1218: the fill effect is a plain NSObject, not a CALayer, so an unknown key
        // throws NSUnknownKeyException (uncatchable in Swift) rather than being stored. If
        // an iOS update drops the property, the pill keeps its glass instead.
        guard fill.responds(to: NSSelectorFromString("setColor:")) else { return }
        fill.setValue(UIColor.white.cgColor, forKey: "color")
        guard let shape = sdfLayer(effect: fill, highlight: highlight, highlightPortal: highlightPortal, source: source) else { return }

        let metal = CAMetalLayer()
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isOpaque = false
        let scale = container.contentsScale > 0 ? container.contentsScale : UIScreen.main.scale
        metal.contentsScale = scale
        metal.frame = cover
        metal.bounds = cover
        metal.drawableSize = CGSize(width: cover.width * scale, height: cover.height * scale)
        metal.compositingFilter = "sourceIn"

        group.addSublayer(shape)
        group.addSublayer(metal)
        container.insertSublayer(group, above: backdrop)
        if veils && veiled {
            group.opacity = 0
        } else if !rim {
            backdrop.opacity = 0
        }
        skins.append(Skin(container: container, source: source, group: group, metal: metal, rim: rim, lens: lens, veils: veils))
        if CACurrentMediaTime() < fadeInUntil, !(veils && veiled) {
            fadeIn(skins[skins.count - 1], over: rim ? nil : backdrop)
        }
        render(skins[skins.count - 1], light: container.delegate.flatMap { ($0 as? UIView)?.traitCollection.userInterfaceStyle == .light }
               ?? (bars.lazy.compactMap(\.view).first?.traitCollection.userInterfaceStyle == .light))
    }

    /// The area the metal covers, around the pill's root: room for the pill's stretches,
    /// and more around the tab bar's lens, which grows as it lifts and is dragged about.
    private static func cover(_ bounds: CGRect, rim: Bool) -> CGRect {
        rim ? bounds.insetBy(dx: -90, dy: -60) : bounds.insetBy(dx: -40, dy: -30)
    }

    /// An SDF layer drawing `effect` over a portal of the pill's shape elements.
    private func sdfLayer(effect: NSObject, highlight: CALayer, highlightPortal: CALayer, source: CALayer) -> CALayer? {
        guard let sdfClass = NSClassFromString("CASDFLayer") as? CALayer.Type,
              let portalClass = NSClassFromString("CAPortalLayer") as? CALayer.Type else { return nil }
        let layer = sdfClass.init()
        mirror(highlight, onto: layer)
        layer.setValue(highlight.value(forKey: "smoothness"), forKey: "smoothness")
        layer.setValue(effect, forKey: "effect")
        let portal = portalClass.init()
        portal.frame = highlightPortal.frame
        portal.bounds = highlightPortal.bounds
        portal.setValue(source, forKey: "sourceLayer")
        portal.setValue(false, forKey: "hidesSourceLayer")
        layer.addSublayer(portal)
        return layer
    }

    /// Keep `layer`'s geometry on `source`'s: the same model bounds and position, and a copy
    /// of each geometry animation UIKit has added to it. This runs before Core Animation
    /// commits, so a copy starts in the same transaction as its original and the render
    /// server plays both in step.
    private func mirror(_ source: CALayer, onto layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // SwiftUI's layers anchor at the top-left; a new layer anchors at its centre.
        if layer.anchorPoint != source.anchorPoint { layer.anchorPoint = source.anchorPoint }
        if layer.bounds != source.bounds { layer.bounds = source.bounds }
        if layer.position != source.position { layer.position = source.position }
        if !CATransform3DEqualToTransform(layer.transform, source.transform) { layer.transform = source.transform }
        CATransaction.commit()
        for key in source.animationKeys() ?? [] where layer.animation(forKey: "mirror." + key) == nil {
            guard let animation = source.animation(forKey: key) else { continue }
            if let property = animation as? CAPropertyAnimation {
                guard let path = property.keyPath,
                      ["bounds", "position", "transform", "anchorPoint"].contains(where: { path.hasPrefix($0) }) else { continue }
            }
            layer.add(animation, forKey: "mirror." + key)
        }
    }

    /// Whether a glass shape's content is bar items (not a search field or other glass):
    /// every bar-button pill's content sits in a UIPlatformGlassInteractionView (SwiftUI's
    /// items in UIKitBarItemHost, UIKit's in _UIButtonBarButton).
    private static func holdsBarItems(_ root: CALayer) -> Bool {
        func walk(_ layer: CALayer, _ depth: Int) -> Bool {
            if let view = layer.delegate as? UIView {
                let name = NSStringFromClass(type(of: view))
                if name.contains("PlatformGlassInteraction") || name.contains("UIPlatformGl") || name.contains("BarItemHost")
                    || name.contains("ButtonBarButton") { return true }
            }
            guard depth < 12 else { return false }
            return (layer.sublayers ?? []).contains { walk($0, depth + 1) }
        }
        return walk(root, 0)
    }

    /// How far a lens has lifted, 0 to 1, as it is drawn this frame. UIKit eases it in and
    /// out itself and keeps the lens's glass a while after it is back to 0, so the rim
    /// follows it instead of the glass's lifetime. 1 when it cannot be read.
    private static func liftProgress(_ lens: UIView?) -> Float {
        guard let lens, lens.responds(to: NSSelectorFromString("liftProgress")),
              let progress = lens.value(forKey: "liftProgress") as AnyObject?,
              progress.responds(to: NSSelectorFromString("presentationValue")),
              let value = progress.value(forKey: "presentationValue") as? Double else { return 1 }
        return Float(min(max(value, 0), 1))
    }

    private static func isClass(_ layer: CALayer, _ name: String) -> Bool {
        NSStringFromClass(type(of: layer)) == name
    }

    // MARK: Rendering

    @objc private func renderAll() {
        // ml1216: nothing skinned (no bar found yet): pause until attach() skins a pill,
        // instead of a 60 Hz wakeup that only queued another commit handler.
        guard !skins.isEmpty else { link?.isPaused = true; return }
        // A press can change the pill in a commit the run-loop observer does not precede.
        attachAgainAfterLayout()
        skins.removeAll { $0.container?.superlayer == nil || $0.group.superlayer == nil }
        if steadyRects.count > skins.count {
            let live = Set(skins.map { ObjectIdentifier($0.metal) })
            steadyRects = steadyRects.filter { live.contains($0.key) }
        }
        guard !skins.isEmpty, UIApplication.shared.applicationState != .background else { return }
        let light = bars.lazy.compactMap(\.view).first?.traitCollection.userInterfaceStyle == .light
        for skin in skins { render(skin, light: light) }
    }

    /// UIKit's tab bar glass places its shape elements with match animations (they follow
    /// another layer). When UIKit adds them again, as a press starts or a drag settles, the
    /// presentation tree puts an element in the wrong place for one frame (off by the bar's
    /// offset in the window, or at its own origin) while the render server draws it in the
    /// right one, and the metal's lighting jumped with it: the bright band crossed the
    /// middle for a frame. Such an element moves a point or two a frame, so a jump of more
    /// than 24 pt is held off for up to three frames.
    private var steadyRects: [ObjectIdentifier: (rects: [CGRect], held: Int)] = [:]

    private func steady(_ rects: [CGRect], for metal: CAMetalLayer, matched: Bool) -> [CGRect] {
        let key = ObjectIdentifier(metal)
        guard matched, let last = steadyRects[key], !last.rects.isEmpty, last.held < 3,
              rects.isEmpty || (last.rects.count == rects.count
                  && zip(last.rects, rects).contains(where: { abs($0.midX - $1.midX) > 24 || abs($0.midY - $1.midY) > 24 })) else {
            steadyRects[key] = (rects, 0)
            return rects
        }
        steadyRects[key] = (last.rects, last.held + 1)
        return last.rects
    }

    private func render(_ skin: Skin, light: Bool) {
        guard let queue, let pipeline, let source = skin.source, let drawable = skin.metal.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }

        // The pill's live element rects, from the presentation tree, in the metal layer's space.
        let metal = skin.metal.presentation() ?? skin.metal
        var raw: [CGRect] = []
        for element in (source.presentation() ?? source).sublayers ?? [] where raw.count < 4 {
            // An element with no size is not placed yet (UIKit's start at zero until their
            // match animations place them).
            guard element.bounds.width >= 1, element.bounds.height >= 1 else { continue }
            raw.append(metal.convert(element.bounds, from: element))
        }
        let matched = source.sublayers?.contains { ($0.animationKeys() ?? []).contains { $0.hasPrefix("match") } } ?? false
        let rects = steady(raw, for: skin.metal, matched: matched)

        var uniforms = [Float](repeating: 0, count: 24)
        uniforms[0] = Float(skin.metal.bounds.minX)
        uniforms[1] = Float(skin.metal.bounds.minY)
        uniforms[2] = Float(skin.metal.contentsScale)
        uniforms[3] = UIAccessibility.isReduceMotionEnabled ? 0 : Float((CACurrentMediaTime() - started).truncatingRemainder(dividingBy: 3600))
        for (i, r) in rects.enumerated() {
            uniforms[4 + i * 4] = Float(r.minX); uniforms[5 + i * 4] = Float(r.minY)
            uniforms[6 + i * 4] = Float(r.width); uniforms[7 + i * 4] = Float(r.height)
        }
        uniforms[20] = Float(bitPattern: UInt32(rects.count))
        uniforms[21] = skin.rim ? 1 : 0
        uniforms[22] = skin.rim ? Self.liftProgress(skin.lens) : 1
        uniforms[23] = light ? 1 : 0

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
