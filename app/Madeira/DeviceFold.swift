// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Julian Scanlan
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

// The iPhone Duo's fold (docs/DUO.md). Folded like a laptop, the half above the
// fold keeps the game and the half lying on the table becomes the deck: touch
// controls, or with a controller a copy of the game and the buttons a controller
// has no key for (FoldDeck.swift). Nothing changes on an iPhone without a fold,
// or on the Duo held open or closed.
//
// Whether it is folded comes from the hinge. iOS 27.1 reports the hinge's status
// and angle (onHingeChange) and the fold as a division region (reservedRegions).
// The status turns partiallyOpen, and the division active, only once the hinge is
// bent well over, so the angle decides first (HingeBend). While folded, the
// division's frame, asked for with .includeInactive, splits the window. It can
// move a moment after the last hinge event without the window changing size, so
// the regions are read again a few times after the posture changes
// (HingeSettling). Log tag: [fold].
//
// `-fold` (a launch argument) stands a 24-point fold across the middle of the
// window, so the layout can be seen in the simulator, whose hinge cannot bend.

final class DeviceFold: ObservableObject {
    static let shared = DeviceFold()

    /// The window split at the fold, in window coordinates.
    struct Layout: Equatable {
        /// Above the fold, upright: the game.
        var top: CGRect
        /// The fold itself, which neither half draws in.
        var fold: CGRect
        /// Below the fold, lying flat: the deck.
        var deck: CGRect
    }

    /// Set while folded like a laptop; nil when open, closed, or without a fold.
    @Published private(set) var layout: Layout?

    /// The last hinge reading, "status, N° (M° from flat)", logged when it changes:
    /// real numbers when a fold is caught too early or too late.
    private(set) var hinge = ""

    static let standIn = ProcessInfo.processInfo.arguments.contains("-fold")

    fileprivate func update(_ new: Layout?) {
        guard new != layout else { return }
        layout = new
        LogStore.shared.log("[fold] \(new.map { "laptop top=\($0.top) deck=\($0.deck)" } ?? "off")")
        // The controls window and the game surface both follow the fold.
        TouchControlsHost.attach()
        MetalBackedView.refreshDisplayMode(reason: "fold")
    }

    fileprivate func note(hinge reading: String) {
        guard reading != hinge else { return }
        hinge = reading
        LogStore.shared.log("[fold] hinge \(reading)")
    }

    /// The window and the fold regions last seen, logged when they change, so a fold
    /// that never becomes a layout says why: no division, or one running across a
    /// landscape window (the Duo held on its side) rather than a portrait one.
    private(set) var regions = ""

    fileprivate func note(regions reading: String) {
        guard reading != regions else { return }
        regions = reading
        LogStore.shared.log("[fold] window \(reading)")
    }

    /// A portrait window with the fold across it: the Duo held open (or bent) upright.
    /// The library's title sits close to the screen's left edge there and moves in a
    /// little (LibraryTitleText).
    @Published private(set) var portraitFold = false

    fileprivate func note(portraitFold now: Bool) {
        guard now != portraitFold else { return }
        portraitFold = now
    }
}

/// Folded or not, from the hinge angle. The flattest angle seen stands for open (it
/// starts 6° short of flat, so a launch while already bent still works). More than
/// 10° of bend from it counts as folded and less than 5° as open again; the gap keeps
/// a Duo held in the hand from flickering between layouts. Closed and partially open
/// are taken at their word.
struct HingeBend {
    static let foldAt = 10.0
    static let openAt = 5.0
    private(set) var flattest = 174.0
    private(set) var folded = false

    /// Degrees of bend from the flattest angle seen.
    func bend(_ degrees: Double) -> Double { flattest - degrees }

    mutating func update(closed: Bool, partiallyOpen: Bool, degrees: Double) -> Bool {
        flattest = max(flattest, degrees)
        if closed {
            folded = false
        } else if partiallyOpen {
            folded = true
        } else if folded {
            folded = bend(degrees) >= Self.openAt
        } else {
            folded = bend(degrees) > Self.foldAt
        }
        return folded
    }
}

extension View {
    /// Publishes DeviceFold.layout for the whole window. Apply once, at the root.
    func deviceFoldReader() -> some View { modifier(DeviceFoldReader()) }
}

private struct DeviceFoldReader: ViewModifier {
    @State private var generation = 0
    @State private var settling = HingeSettling()
    @State private var bend = HingeBend()
    /// Folded, by the hinge angle or status.
    @State private var folded = false
    @State private var lastStatus = ""

    func body(content: Content) -> some View {
        if DeviceFold.standIn {
            content.background(
                GeometryReader { proxy in
                    let layout = proxy.standInFold()
                    Color.clear
                        .onAppear { DeviceFold.shared.update(layout) }
                        .onChange(of: layout) { _, new in DeviceFold.shared.update(new) }
                }
                .ignoresSafeArea()
            )
        } else {
            reader(content)
        }
    }

    @ViewBuilder private func reader(_ content: Content) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content
                .background(
                    GeometryReader { proxy in
                        let layout = proxy.foldLayout(folded: folded, generation: generation)
                        let regions = proxy.foldRegions(generation: generation)
                        let portraitFold = proxy.portraitFold(generation: generation)
                        Color.clear
                            .onAppear {
                                DeviceFold.shared.update(layout)
                                DeviceFold.shared.note(regions: regions)
                                DeviceFold.shared.note(portraitFold: portraitFold)
                            }
                            .onChange(of: layout) { _, new in DeviceFold.shared.update(new) }
                            .onChange(of: regions) { _, new in DeviceFold.shared.note(regions: new) }
                            .onChange(of: portraitFold) { _, new in DeviceFold.shared.note(portraitFold: new) }
                    }
                    .ignoresSafeArea()
                )
                .onHingeChange { _, new in
                    guard let hinge = new.hinge else { return }
                    let status = hinge.status == .closed ? "closed"
                        : hinge.status == .partiallyOpen ? "partially open" : "open"
                    let degrees = hinge.angle.degrees
                    let now = bend.update(closed: hinge.status == .closed,
                                          partiallyOpen: hinge.status == .partiallyOpen, degrees: degrees)
                    DeviceFold.shared.note(hinge: String(format: "%@, %.0f° (%.0f° from flat)",
                                                         status, degrees, bend.bend(degrees)))
                    // Read the regions again when the answer changes, not on every angle tick.
                    guard now != folded || status != lastStatus else { return }
                    folded = now
                    lastStatus = status
                    settling.refresh($generation)
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Asks the region reader again after the posture changes, until the division has settled.
private final class HingeSettling {
    private static let delays: [TimeInterval] = [0, 0.3, 0.8, 1.6]
    private var pending: [DispatchWorkItem] = []

    func refresh(_ generation: Binding<Int>) {
        pending.forEach { $0.cancel() }
        pending = Self.delays.map { delay in
            let item = DispatchWorkItem { generation.wrappedValue += 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }
}

private extension GeometryProxy {
    /// `-fold`: a 24-point fold across the middle of the window.
    func standInFold() -> DeviceFold.Layout {
        let height: CGFloat = 24
        let fold = CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height).foldRounded
        return DeviceFold.Layout(top: CGRect(x: 0, y: 0, width: size.width, height: fold.minY),
                                 fold: fold,
                                 deck: CGRect(x: 0, y: fold.maxY, width: size.width, height: size.height - fold.maxY))
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private extension GeometryProxy {
    /// The two halves around a horizontal fold, or nil when there is none: the
    /// active division, or while folded by the hinge the inactive one's frame.
    /// `generation` only makes SwiftUI evaluate this again while the fold settles.
    func foldLayout(folded: Bool, generation _: Int) -> DeviceFold.Layout? {
        let divisions = reservedRegions(kind: .division, options: .includeInactive)
            .filter { $0.frame.width > $0.frame.height }
        guard let division = divisions.first(where: { $0.isActive }) ?? (folded ? divisions.first : nil) else { return nil }
        // Layout passes differ in the last bits; those must not read as a new fold.
        let fold = division.frame.foldRounded
        let top = CGRect(x: 0, y: 0, width: size.width, height: max(0, fold.minY)).foldRounded
        let deck = CGRect(x: 0, y: fold.maxY, width: size.width, height: max(0, size.height - fold.maxY)).foldRounded
        // A sliver either side is a fold near an edge, not a laptop.
        guard top.height >= 120, deck.height >= 120 else { return nil }
        return DeviceFold.Layout(top: top, fold: fold, deck: deck)
    }

    /// A portrait window with a division across it (DeviceFold.portraitFold).
    func portraitFold(generation _: Int) -> Bool {
        size.height > size.width && reservedRegions(kind: .division, options: .includeInactive)
            .contains { $0.frame.width > $0.frame.height }
    }

    /// "951x669 divisions=[476,0 19x669 inactive]": the window and every division,
    /// for the log (DeviceFold.note(regions:)).
    func foldRegions(generation _: Int) -> String {
        let divisions = reservedRegions(kind: .division, options: .includeInactive).map { region in
            let f = region.frame
            return "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) \(region.isActive ? "active" : "inactive")"
        }
        return "\(Int(size.width))x\(Int(size.height)) divisions=[\(divisions.joined(separator: "; "))]"
    }
}
#endif

private extension CGRect {
    var foldRounded: CGRect {
        func q(_ v: CGFloat) -> CGFloat { (v * 4).rounded() / 4 }
        return CGRect(x: q(minX), y: q(minY), width: q(width), height: q(height))
    }
}

/// The deck under the game: black, with the game reflected in it as in a glossy
/// table, the way Netflix lights the lower screen of a folded Duo: flipped about the
/// fold so the game's lower edge meets it, blurred until only its colours are left,
/// and dimmed evenly so the keys on it stay the brightest thing there, dimming a
/// little further down the deck but never to black (GameMirror, filling it). Without
/// `edge` the same copy glows unflipped behind the game: in the bars beside it above
/// the fold, and behind the game's band upright and unfolded. The Mirror key turns it
/// off (`madeiraFoldGlow`). A soft shadow at the fold keeps the controls reading as
/// lying on a table.
struct FoldDeckBackground: View {
    /// On by default; a key of its own, so the sharp copy's old off switch does not carry over.
    static let glowKey = "madeiraFoldGlow"
    @AppStorage(glowKey) private var mirror = true
    /// The copy flipped about the top edge, as a reflection (off for the backdrop behind
    /// the game).
    var edge = true
    /// The shade along the top, under the hinge: only folded.
    var hinge = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The copy is drawn at 1/shrink of the size, blurred there and scaled up: a live
    /// full-size copy blurred every game frame cost the game GPU time.
    private static let shrink: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black
                if mirror && !reduceTransparency && GameMirror.available && geo.size.width > 1 && geo.size.height > 1 {
                    // 7 here is 56 points at full size: only the colours are left. 2.5
                    // kept the game's shapes.
                    GameMirror(fill: true, bottom: edge)
                        .frame(width: geo.size.width / Self.shrink, height: geo.size.height / Self.shrink)
                        .blur(radius: 7, opaque: true)
                        .saturation(1.2)
                        .scaleEffect(x: Self.shrink, y: edge ? -Self.shrink : Self.shrink)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(LinearGradient(colors: edge ? [.white.opacity(0.62), .white.opacity(0.5), .white.opacity(0.4)] : [.white, .white],
                                             startPoint: .top, endPoint: .bottom))
                        .opacity(edge ? 1 : 0.8)
                }
                if edge && hinge {
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .onAppear { LogStore.shared.log("[fold] deck glow=\(mirror ? 1 : 0) portal=\(GameMirror.available ? 1 : 0)") }
    }
}
