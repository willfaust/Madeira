// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit
import Combine

// The new look's controller (NewLook.swift): Madeira owns one highlight, on every screen.
// The pad is player 1's, read by GamepadInput and turned into commands by LibraryController,
// so it only reaches Madeira's own screens while no game has the pad.
//
//   D-pad / left stick  moves the highlight to the nearest item that way (held: repeats)
//   A                   presses the highlighted item (opens, toggles, picks)
//   B                   back, cancel or stop: the top layer's own back
//   X                   Play or Install on the highlighted game, else the layer's Play
//   Y / View            Search
//   LB / RB             the previous or next tab
//   LT / RT             a page up or down
//   Menu                the highlighted game's options
//
// Layers: a screen or sheet over another one (the game page, a question, the options) is a
// layer. Only the top layer's items can be highlighted, the layer starts on its own safe
// item, and when it goes the highlight returns to the item it came from. The first press
// only shows the highlight; touching the screen hides it. env.MADEIRA_NEW_LOOK_PAD = 0 turns
// the highlight off (the new look's screens then work by touch only).

@MainActor final class PadHighlight: ObservableObject {
    static let shared = PadHighlight()
    static var enabled: Bool { NewLook.enabled && MadeiraConfig.flag("MADEIRA_NEW_LOOK_PAD") }

    /// The highlight is showing: the controller was used since the last touch.
    @Published private(set) var shown = false
    /// The highlighted item's id.
    @Published private(set) var focus: String?
    /// The top layer's name, for the hints under the screen.
    @Published private(set) var layerName = PadLayer.root

    /// A press on an item: the item runs its own current action (PadItem's onReceive).
    enum Kind { case press, play, menu }
    let action = PassthroughSubject<(String, Kind), Never>()

    struct Item {
        var frame: CGRect
        var layer: String
        var play: Bool
        var menu: Bool
        /// The grid the item belongs to, for moving through covers that are not drawn yet.
        var grid: String?
        /// The view that registered it: a hidden tab's item with the same id never takes it away.
        var owner: ObjectIdentifier? = nil
    }
    private var items: [String: Item] = [:]

    /// A grid of covers: its items' ids in order and how many sit across.
    struct Grid { var ids: [String]; var columns: Int }
    private var grids: [String: Grid] = [:]

    /// A layer: its name, what B does, what X does when the highlight is on no game, and
    /// the item the highlight goes back to when it closes.
    struct Layer {
        let name: String
        var back: (() -> Void)?
        var play: (() -> Void)?
        var start: String?
        let returnTo: String?
        /// A on a layer with nothing to highlight (a store game's sheet): its Install or Open.
        var accept: (() -> Void)? = nil
        /// The view that opened it (PadLayerModifier). With a page stack per tab two layers can
        /// share a name (a store's page in Stores and in Search): each closes only its own.
        var token: UUID? = nil
        /// A page pushed inside a tab (a store's page, a Settings page, a game's page): LB/RB and
        /// Y still change tabs over it, as a tap on the tab bar does. A popup or sheet is not one.
        var page = false
    }
    private var layers: [Layer] = [Layer(name: PadLayer.root, back: nil, play: nil, start: nil, returnTo: nil)]
    var top: Layer { layers[layers.count - 1] }

    /// What the tab bar does: LB/RB, Y, and the tab's own first item.
    var tabs: ((Int) -> Void)?
    var search: (() -> Void)?
    /// B on a tab with no layer over it: Search goes back to the tab you came from
    /// (LibraryView.newLookBody). A pushed page (a store's, a Settings page) is a layer of its
    /// own, and its B goes back a page.
    var rootBack: (() -> Void)?
    /// The highlight's last place on each root page (a tab), for coming back to it.
    private var remembered: [String: String] = [:]
    /// The item a closed layer hands the highlight back to while that item is not laid out again
    /// yet (a game page coming back from Display): it keeps the highlight when it is.
    private var pending: String?
    var page = "library"
    private var started = false
    private var bag: AnyCancellable?

    /// Listens to the controller's commands once, while the new look is on.
    func start() {
        guard !started, Self.enabled else { return }
        started = true
        bag = LibraryController.shared.commands.sink { [weak self] command in
            MainActor.assumeIsolated { self?.handle(command) }
        }
        installTouchWatch()
        LogStore.shared.log("[pad-highlight] on")
    }

    // MARK: Items and layers

    func register(_ id: String, _ item: Item) {
        items[id] = item
        if id == pending { pending = nil; if focus == id, shown { scrollRequest.send(id) }; return }
        // A layer that just opened rings its start item as soon as it is laid out.
        if pending == nil, shown, focus == nil || items[focus ?? ""]?.layer != top.name, item.layer == top.name,
           top.start == id || (top.start == nil && !settling) {
            move(to: id, scroll: false)
        }
    }
    func unregister(_ id: String, owner: ObjectIdentifier? = nil) {
        if owner == nil || items[id]?.owner == owner { items[id] = nil }
    }
    func setGrid(_ id: String, ids: [String], columns: Int) { grids[id] = Grid(ids: ids, columns: max(1, columns)) }
    func removeGrid(_ id: String) { grids[id] = nil }

    func push(_ name: String, start: String?, back: (() -> Void)?, play: (() -> Void)?, accept: (() -> Void)? = nil,
              token: UUID? = nil, page: Bool = false) {
        if let i = layers.firstIndex(where: { token != nil ? $0.token == token : $0.name == name }), i > 0 {
            layers.removeSubrange(i...)
        }
        // The item to come back to: only one on the layer under it (a page reopened in another
        // tab must not come back to an item of the tab it was opened from).
        // (None while a tab change is under way: the old tab's item is not on this tab.)
        let returnTo = entering != nil ? nil : focus.flatMap { id in
            items[id]?.layer == top.name || grids.values.contains(where: { $0.ids.contains(id) }) ? id : nil
        }
        layers.append(Layer(name: name, back: back, play: play, start: start, returnTo: returnTo, accept: accept, token: token, page: page))
        entering = nil
        layerName = name
        if shown { move(to: start.flatMap { items[$0] != nil ? $0 : nil } ?? first(in: name), scroll: false) }
        // No start item: once the layer is laid out, its top-left row (items register in no set
        // order: a game's Controls page started on its last row, Control size).
        if start == nil { settleSoon(layer: name, page: nil) }
        LogStore.shared.log("[pad-highlight] layer \(name) opened")
    }
    func update(_ name: String, back: (() -> Void)?, play: (() -> Void)?) {
        guard let i = layers.firstIndex(where: { $0.name == name }) else { return }
        layers[i].back = back; layers[i].play = play
    }
    func pop(_ name: String, token: UUID? = nil) {
        guard let i = layers.lastIndex(where: { token != nil ? $0.token == token : $0.name == name }), i > 0 else { return }
        // Only this layer goes: a layer over it (the starting screen over a game page that the
        // session replaced) stays, and the highlight moves back only when this one was on top.
        let wasTop = i == layers.count - 1
        let back = layers[i].returnTo
        layers.remove(at: i)
        layerName = top.name
        LogStore.shared.log("[pad-highlight] layer \(name) closed")
        guard wasTop else {
            // The page under it came back on top first (a game's own page closed inside a tab: the
            // game's page appeared again before this one went): the highlight goes back to its row.
            if let back, items[back]?.layer == top.name { move(to: back, scroll: true) }
            return
        }
        // A tab was picked while this page was open on the old tab: the highlight goes to the
        // new tab's place, not back to the old tab's row.
        if layers.count == 1, let name = entering { entering = nil; land(on: name); return }
        // The page under it may not be laid out again yet (Cameron, Nov 9: back from Display the
        // controller did nothing until a touch): its item takes the highlight when it is.
        if let back, items[back] == nil { move(to: back, scroll: false); pending = back; return }
        move(to: back.flatMap { items[$0]?.layer == top.name ? $0 : nil } ?? first(in: top.name), scroll: true)
    }

    /// A tab became the root page: the highlight goes to its remembered item, else its first.
    func enterPage(_ name: String) {
        // A tab-bar button is never remembered: coming back to a page starts on the page
        // (Cameron, Nov 9: back from Search the highlight sat on the Search button, down did nothing).
        if let focus, items[focus]?.layer == PadLayer.root, !focus.hasPrefix("tab-") { remembered[page] = focus }
        page = name
        // A page pushed on the old tab still has its layer (it closes just after): the new tab's
        // place is taken once it has (pop). A layer the new tab opens itself clears this (push).
        guard layers.count == 1 else { entering = name; return }
        entering = nil
        land(on: name)
    }
    /// A tab picked while a pushed page's layer was still up (enterPage, pop).
    private var entering: String?
    private func land(on name: String) {
        let kept = remembered[name].flatMap { items[$0] != nil ? $0 : nil }
        move(to: kept, scroll: true)
        guard kept == nil else { return }
        // The new page's items lay out after this: once they have, its remembered item, else its
        // top-left item on screen, takes the highlight.
        settleSoon(layer: PadLayer.root, page: name)
    }
    private var settling = false
    /// Controller presses so far: a press while a page settles keeps where it put the highlight.
    private var presses = 0
    private func settleSoon(layer: String, page: String?) {
        settling = true
        let at = presses
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.settle(layer: layer, page: page, at: at) }
    }
    private func settle(layer: String, page: String?, at: Int) {
        settling = false
        guard top.name == layer, page == nil || self.page == page, presses == at else { return }
        if let id = home(layer: layer, page: page) { move(to: id, scroll: true) }
    }
    /// Where the highlight belongs on a layer: the page's remembered item, else its top-left
    /// item on screen, else its first.
    private func home(layer: String, page: String?) -> String? {
        let height = windowSize.height
        return page.flatMap { remembered[$0] }.flatMap { items[$0] != nil ? $0 : nil }
            ?? items.filter { $0.value.layer == layer && !$0.key.hasPrefix("tab-") && $0.value.frame.width > 0
                              && $0.value.frame.minY >= 0 && $0.value.frame.minY < height }
                .min { a, b in
                    abs(a.value.frame.minY - b.value.frame.minY) > 8 ? a.value.frame.minY < b.value.frame.minY : a.value.frame.minX < b.value.frame.minX
                }?.key
            ?? first(in: layer)
    }
    /// The app's window, not the whole screen: in Split View and Stage Manager they differ
    /// (ux-review-0044 #9).
    private var windowSize: CGSize {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.bounds.size ?? UIScreen.main.bounds.size
    }
    /// Nothing but the tab and pages pushed inside it is up (no popup or sheet).
    private var onTabPage: Bool { layers.dropFirst().allSatisfy(\.page) }
    /// The highlight is on an item that is not there (its page closed and the item it came back
    /// to never came back: an uninstalled game, a moved row). A cover of a grid that is only
    /// scrolled away is still there.
    private var onGhost: Bool {
        guard let focus else { return false }
        return items[focus] == nil && !grids.values.contains(where: { $0.ids.contains(focus) })
    }

    // MARK: Showing and moving

    @discardableResult func show() -> Bool {
        installTouchWatch()
        guard !shown else { return false }
        withAnimation(Self.animation) { shown = true }
        if focus == nil || items[focus!]?.layer != top.name { move(to: top.start.flatMap { items[$0] != nil ? $0 : nil } ?? first(in: top.name), scroll: true) }
        return true
    }
    func hide() {
        guard shown else { return }
        withAnimation(Self.animation) { shown = false }
    }
    func move(to id: String?, scroll: Bool = true) {
        pending = nil
        guard id != focus else { return }
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) { focus = id }
        if scroll, let id { scrollRequest.send(id) }
    }
    /// Highlights the first of `ids` that is on screen in the top layer, else the layer's first item.
    func move(toAny ids: [String]) {
        move(to: ids.first { items[$0]?.layer == top.name } ?? first(in: top.name))
    }
    /// The highlighted item should be on screen: pages with a scroll view scroll to it.
    let scrollRequest = PassthroughSubject<String, Never>()
    static var animation: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.08) }

    /// The top-left item of a layer.
    func first(in layer: String) -> String? {
        items.filter { $0.value.layer == layer && $0.value.frame.width > 0 }
            .min { a, b in
                abs(a.value.frame.minY - b.value.frame.minY) > 8 ? a.value.frame.minY < b.value.frame.minY : a.value.frame.minX < b.value.frame.minX
            }?.key
    }

    /// The next item from the highlighted one in `direction`: inside a grid by its order
    /// (covers further down may not be drawn yet), else the nearest drawn item that way.
    func next(_ direction: String) -> String? {
        guard let focus else { return first(in: top.name) }
        // A cover scrolled out of a lazy grid is no longer drawn (its item is gone): its grid still knows where it is.
        let gridID = items[focus]?.grid ?? grids.first(where: { $0.value.ids.contains(focus) })?.key
        if let gridID, let grid = grids[gridID], let index = grid.ids.firstIndex(of: focus) {
            let columns = grid.columns
            var target: Int?
            switch direction {
            case "left": if index % columns > 0 { target = index - 1 }
            case "right": if index % columns < columns - 1, index + 1 < grid.ids.count { target = index + 1 }
            case "up": if index >= columns { target = index - columns }
            case "down":
                if index + columns < grid.ids.count { target = index + columns }
                // The last row is short: the last cover, when the row below has any.
                else if index / columns < (grid.ids.count - 1) / columns { target = grid.ids.count - 1 }
            default: break
            }
            if let target { return grid.ids[target] }
            // Out of the grid: the nearest item that is not one of its covers.
            guard let current = items[focus] else { return nil }
            return nearest(from: current.frame, direction: direction, skip: Set(grid.ids))
        }
        guard let current = items[focus] else { return first(in: top.name) }
        return nearest(from: current.frame, direction: direction, skip: [])
    }

    /// The nearest item in the top layer that lies `direction` from `from`: mostly straight
    /// ahead, a little to the side when nothing is.
    func nearest(from: CGRect, direction: String, skip: Set<String>) -> String? {
        var best: (String, CGFloat)?
        for (id, item) in items where item.layer == top.name && !skip.contains(id) && id != focus && item.frame.width > 0 {
            let f = item.frame
            let ahead: CGFloat, side: CGFloat
            switch direction {
            case "down": guard f.minY >= from.maxY - 4 else { continue }; ahead = f.minY - from.maxY; side = gap(f.minX, f.maxX, from.minX, from.maxX)
            case "up": guard f.maxY <= from.minY + 4 else { continue }; ahead = from.minY - f.maxY; side = gap(f.minX, f.maxX, from.minX, from.maxX)
            case "right": guard f.minX >= from.maxX - 4 else { continue }; ahead = f.minX - from.maxX; side = gap(f.minY, f.maxY, from.minY, from.maxY)
            case "left": guard f.maxX <= from.minX + 4 else { continue }; ahead = from.minX - f.maxX; side = gap(f.minY, f.maxY, from.minY, from.maxY)
            default: continue
            }
            // Left and right stay in the row: an item with no overlap at all is skipped.
            if direction == "left" || direction == "right", side > 0 { continue }
            let score = max(0, ahead) + side * 3
            if best == nil || score < best!.1 { best = (id, score) }
        }
        return best?.0
    }
    /// How far apart two spans are (0 when they overlap).
    private func gap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        if a1 < b0 { return b0 - a1 }
        if b1 < a0 { return a0 - b1 }
        return 0
    }

    /// LT/RT: about a screen up or down.
    func jump(down: Bool) -> String? {
        guard let focus else { return first(in: top.name) }
        let gridID = items[focus]?.grid ?? grids.first(where: { $0.value.ids.contains(focus) })?.key
        if let gridID, let grid = grids[gridID], let index = grid.ids.firstIndex(of: focus) {
            let rows = max(2, Int((windowSize.height * 0.7) / max(items[focus]?.frame.height ?? 200, 120)))
            let step = grid.columns * rows
            let target = down ? min(grid.ids.count - 1, index + step) : max(0, index - step)
            return grid.ids[target]
        }
        guard let current = items[focus] else { return first(in: top.name) }
        let height = windowSize.height * 0.8
        let point = CGPoint(x: current.frame.midX, y: current.frame.midY + (down ? height : -height))
        return items.filter { $0.value.layer == top.name && $0.value.frame.width > 0 && (down ? $0.value.frame.midY > current.frame.midY : $0.value.frame.midY < current.frame.midY) }
            .min { hypot($0.value.frame.midX - point.x, $0.value.frame.midY - point.y) < hypot($1.value.frame.midX - point.x, $1.value.frame.midY - point.y) }?.key
    }

    // MARK: Commands

    func handle(_ command: String) {
        presses += 1
        // In a session only the starting screen is Madeira's, and never under the Session menu
        // (its own A and B; an A there must not press Stop behind it).
        let model = LibraryModel.shared
        guard Self.enabled, model.current == nil || model.startingScreen, !model.menu else { return }
        // The first press of a direction or A only brings the highlight back (where it was).
        // A layer with nothing to highlight (a store game's sheet) takes A as its own accept.
        if command == "accept", let accept = top.accept, !items.values.contains(where: { $0.layer == top.name }) {
            accept(); return
        }
        let moves = ["up", "down", "left", "right", "accept", "pageUp", "pageDown"]
        if moves.contains(command), show() { return }
        // A or Menu on an item that is gone did nothing until a move or a touch (ux-review-0044 #3):
        // the press puts the highlight somewhere real first, as the first press after a touch does.
        // (The directions already start from the layer's first item; B is the layer's own.)
        if command == "accept" || command == "menu", onGhost {
            move(to: home(layer: top.name, page: layers.count == 1 ? page : nil), scroll: true)
            LogStore.shared.log("[pad-highlight] re-homed from a gone item")
            return
        }
        switch command {
        case "up", "down", "left", "right":
            if let id = next(command) { move(to: id) }
        case "pageUp", "pageDown":
            if let id = jump(down: command == "pageDown") { move(to: id) }
        case "accept":
            // A cover just scrolled into view may not be drawn yet: it takes the press when it is.
            if let focus, items[focus]?.layer == top.name || grids.values.contains(where: { $0.ids.contains(focus) }) {
                action.send((focus, .press))
            }
        case "play":
            show()
            if let focus, let item = items[focus], item.layer == top.name, item.play { action.send((focus, .play)) }
            else { top.play?() }
        case "menu":
            if let focus, let item = items[focus], item.layer == top.name, item.menu { show(); action.send((focus, .menu)) }
        case "back":
            if let back = top.back { back() } else if layers.count == 1 { rootBack?() }
        case "previous", "next":
            // Over pages pushed in the tab too (Cameron, Test 6: LB/RB stuck on Settings and
            // Search with a page open there); never under a popup or sheet.
            if onTabPage { tabs?(command == "next" ? 1 : -1) }
        case "add", "search":
            if onTabPage { search?() }
        default: break
        }
    }

    // MARK: Touch

    /// Touching the screen hides the highlight: a recognizer on the window that never takes a touch.
    private var watching = false
    private func installTouchWatch() {
        guard !watching else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        guard let window else { return }
        watching = true
        window.addGestureRecognizer(PadTouchWatch { PadHighlight.shared.hide() })
        // iOS 18 also routes a controller into UIKit's own focus: Madeira reads the pad itself.
        GamepadEventClaim.install(on: window)
    }
}

/// The layer names that are always there.
enum PadLayer {
    static let root = "root"
}

private struct PadLayerKey: EnvironmentKey { static let defaultValue = PadLayer.root }
extension EnvironmentValues {
    /// The layer the views inside belong to (PadHighlight).
    var padLayer: String {
        get { self[PadLayerKey.self] }
        set { self[PadLayerKey.self] = newValue }
    }
}

/// The value after `current` in `values` (the first again after the last): A on a choice row
/// steps to its next option, as the controller cannot open the system's menu.
func padNext<T: Equatable>(_ values: [T], after current: T) -> T {
    guard let first = values.first else { return current }
    guard let index = values.firstIndex(of: current) else { return first }
    return values[(index + 1) % values.count]
}

/// Sees every touch on the window and fails at once, so taps, scrolls and buttons are untouched.
final class PadTouchWatch: UIGestureRecognizer {
    private let touched: @MainActor () -> Void
    init(_ touched: @escaping @MainActor () -> Void) {
        self.touched = touched
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        MainActor.assumeIsolated { touched() }
        state = .failed
    }
}

/// A PadItem's last frame on screen, and whether it is on screen now. (Apple's tab bar keeps
/// the other tabs' pages alive while they are hidden: their items must not register again or
/// take a press meant for an item with the same id on the open tab.)
final class PadLastFrame { var frame: CGRect = .zero; var visible = false }

/// An item the highlight can reach: its ring, its place on screen, and what A, X and Menu do.
struct PadItem: ViewModifier {
    let id: String
    var cornerRadius: CGFloat = 16
    var grid: String? = nil
    var play: (() -> Void)? = nil
    var menu: (() -> Void)? = nil
    /// The item is a capsule or a circle (buttons, pills, chips): the outline is a capsule around it.
    var capsule = false
    /// Where the outline sits: negative is a gap outside the item (the usual 4 pt), 0 is on its own
    /// edge (a tab inside the tab bar, so it stays inside the bar), positive is inside it (a row in a
    /// card, so it follows the card's curve instead of poking out). Its corners are always
    /// `cornerRadius - inset`, which keeps it concentric with the item.
    var inset: CGFloat = -4
    let press: () -> Void
    @Environment(\.padLayer) private var layer
    /// Its last place: a page that comes back (a pushed page closed) is not measured again
    /// when nothing moved, so it registers again from here. (A box: keeping it redraws nothing while scrolling.)
    @State private var last = PadLastFrame()
    /// This item has the highlight. Each item follows only its own yes/no, not the whole
    /// PadHighlight: a move or a tab switch redraws the one or two items that changed, not every
    /// item in every tab and pushed page (Cameron, Test 6: tab switching got laggy over time).
    @State private var on = false
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .overlay {
                // Every outline is concentric with its item (Apple's rule; Cameron, Nov 9: "make sure things
                // line up"): the same shape, moved out or in by `inset`, corners changed by the same amount.
                Group {
                    if capsule {
                        Capsule().strokeBorder(NewLookColor.ring(scheme), lineWidth: 3)
                    } else {
                        RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous)
                            .strokeBorder(NewLookColor.ring(scheme), lineWidth: 3)
                    }
                }
                .padding(inset)
                .opacity(on ? 1 : 0)
                .allowsHitTesting(false)
            }
            .zIndex(on ? 1 : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                last.frame = frame
                guard last.visible else { return }
                PadHighlight.shared.register(id, .init(frame: frame, layer: layer, play: play != nil, menu: menu != nil, grid: grid,
                                                        owner: ObjectIdentifier(last)))
            }
            .onAppear {
                last.visible = true
                if last.frame != .zero {
                    PadHighlight.shared.register(id, .init(frame: last.frame, layer: layer, play: play != nil, menu: menu != nil, grid: grid,
                                                            owner: ObjectIdentifier(last)))
                }
            }
            .onDisappear {
                last.visible = false
                PadHighlight.shared.unregister(id, owner: ObjectIdentifier(last))
            }
            .id(id)
            .onReceive(PadHighlight.shared.$focus.combineLatest(PadHighlight.shared.$shown)
                .map { [id] focus, shown in shown && focus == id }.removeDuplicates()) { on = $0 }
            .onReceive(PadHighlight.shared.action) { pressed in
                guard pressed.0 == id, last.visible else { return }
                switch pressed.1 {
                case .press: press()
                case .play: play?()
                case .menu: menu?()
                }
            }
    }
}

/// A screen or sheet over the others: its items form the top layer while it is up.
struct PadLayerModifier: ViewModifier {
    let name: String
    var start: String?
    let back: (() -> Void)?
    var play: (() -> Void)? = nil
    var accept: (() -> Void)? = nil
    var page = false
    /// This view's own layer (two pages with one layer name can be up in different tabs).
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content
            .environment(\.padLayer, name)
            .onAppear { PadHighlight.shared.push(name, start: start, back: back, play: play, accept: accept, token: token, page: page) }
            .onDisappear { PadHighlight.shared.pop(name, token: token) }
    }
}

/// Keeps the highlighted item on screen in a scroll view.
struct PadScrollFollow: ViewModifier {
    let reader: ScrollViewProxy
    /// Items that scroll the page all the way up, to the view with this id (a game page's Play:
    /// its cover above it shows too).
    var toTop: Set<String> = []
    var topID = "pad-top"
    func body(content: Content) -> some View {
        content.onReceive(PadHighlight.shared.scrollRequest) { id in
            withAnimation(PadHighlight.animation) {
                if toTop.contains(id) { reader.scrollTo(topID, anchor: .top) } else { reader.scrollTo(id, anchor: .center) }
            }
        }
    }
}

extension View {
    /// A controller-reachable item (PadHighlight): `id` is unique on the screen.
    /// `when`: false leaves the view out of the highlight (a pill that only shows a state).
    @ViewBuilder func padItem(_ id: String, cornerRadius: CGFloat = 16, grid: String? = nil,
                              play: (() -> Void)? = nil, menu: (() -> Void)? = nil, when: Bool = true, capsule: Bool = false,
                              inset: CGFloat = -4, press: @escaping () -> Void) -> some View {
        if PadHighlight.enabled && when {
            modifier(PadItem(id: id, cornerRadius: cornerRadius, grid: grid, play: play, menu: menu, capsule: capsule, inset: inset, press: press))
        } else { self }
    }
    /// A layer over the screens below (PadHighlight): `start` is its safe first item, `back` B.
    /// `page`: a page pushed inside a tab (LB/RB and Y still change tabs over it).
    @ViewBuilder func padLayer(_ name: String, start: String? = nil, back: (() -> Void)?, play: (() -> Void)? = nil,
                               accept: (() -> Void)? = nil, page: Bool = false) -> some View {
        if PadHighlight.enabled { modifier(PadLayerModifier(name: name, start: start, back: back, play: play, accept: accept, page: page)) } else { self }
    }
    /// Scrolls to the highlighted item (inside a ScrollViewReader).
    @ViewBuilder func padScrollFollow(_ reader: ScrollViewProxy, toTop: Set<String> = []) -> some View {
        if PadHighlight.enabled { modifier(PadScrollFollow(reader: reader, toTop: toTop)) } else { self }
    }
}
