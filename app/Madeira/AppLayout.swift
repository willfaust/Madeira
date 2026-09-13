import Foundation

/// Which top-level chrome the app presents.
enum AppLayout: Equatable {
    /// Tooling UI: badges, a game strip, the key row and the log console.
    case tooling
    /// The game surface owns the screen.
    case immersive
}

/// Chooses between the two layouts.
///
/// Deliberately pure and outside `ContentView`, because this one comparison is
/// what locked every iPad out of fullscreen. The test used to be
/// `verticalSizeClass == .compact`, which is true only for an iPhone in
/// landscape. An iPad reports `.regular` vertically in BOTH orientations, so
/// `portraitBody` was selected no matter how the device was held: the game ran
/// in a 240pt strip with no way to enlarge it, while the same build on an
/// iPhone got the full screen for free by rotating.
enum LayoutPolicy {

    /// True when the configuration leaves no room for the tooling rows.
    ///
    /// Only an iPhone in landscape is compact vertically. The device kind is
    /// passed in rather than inferred from the size class on purpose: reading
    /// the idiom is what distinguishes "compact because the phone is on its
    /// side" from "compact because an iPad is running in a Slide Over pane",
    /// and a pane is still a place where the tooling rows fit.
    static func forcesImmersive(verticalCompact: Bool, isPad: Bool) -> Bool {
        verticalCompact && !isPad
    }

    /// The layout to show.
    ///
    /// - Parameter userWantsImmersive: the explicit expand toggle, persisted.
    ///   Honoured on every device in every orientation; without it only a
    ///   device that forces immersion ever reaches it.
    static func resolve(verticalCompact: Bool, isPad: Bool,
                        userWantsImmersive: Bool) -> AppLayout {
        if forcesImmersive(verticalCompact: verticalCompact, isPad: isPad) {
            return .immersive
        }
        return userWantsImmersive ? .immersive : .tooling
    }

    /// Whether the immersive layout must draw its own way back.
    ///
    /// False when immersion is forced: an iPhone on its side has nowhere to
    /// return to, so an exit button there would be a lie. True when the user
    /// opted in — an iPad has no rotation to escape with, which is exactly the
    /// trap this avoids.
    static func needsExitAffordance(verticalCompact: Bool, isPad: Bool) -> Bool {
        !forcesImmersive(verticalCompact: verticalCompact, isPad: isPad)
    }
}
