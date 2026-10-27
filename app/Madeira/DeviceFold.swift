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
        fputs("[fold] \(new.map { "laptop top=\($0.top) deck=\($0.deck)" } ?? "off")\n", stderr)
        // The controls window and the game surface both follow the fold.
        TouchControlsHost.attach()
        MetalBackedView.refreshDisplayMode(reason: "fold")
    }

    fileprivate func note(hinge reading: String) {
        guard reading != hinge else { return }
        hinge = reading
        fputs("[fold] hinge \(reading)\n", stderr)
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
                        Color.clear
                            .onAppear { DeviceFold.shared.update(layout) }
                            .onChange(of: layout) { _, new in DeviceFold.shared.update(new) }
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
}
#endif

private extension CGRect {
    var foldRounded: CGRect {
        func q(_ v: CGFloat) -> CGFloat { (v * 4).rounded() / 4 }
        return CGRect(x: q(minX), y: q(minY), width: q(width), height: q(height))
    }
}

/// The deck under the game: a dark surface with a soft shadow at the fold, so the
/// controls read as lying on a table.
struct FoldDeckBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.09), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 18)
        }
        .allowsHitTesting(false)
    }
}
