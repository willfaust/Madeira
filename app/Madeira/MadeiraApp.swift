import Foundation
import SwiftUI
import UIKit

/// App-wide interface orientation lock (`Auto`, `Landscape`, `Portrait`).
/// Lets the user rotate or lock the game window from the in-game Session menu
/// (or Settings) even when iOS Portrait Orientation Lock is enabled.
@MainActor
final class OrientationLock: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case auto = "auto"
        case landscape = "landscape"
        case portrait = "portrait"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Auto"
            case .landscape: return "Landscape"
            case .portrait: return "Portrait"
            }
        }
        var mask: UIInterfaceOrientationMask {
            switch self {
            case .auto: return .allButUpsideDown
            case .landscape: return .landscape
            case .portrait: return .portrait
            }
        }
    }

    static let shared = OrientationLock()
    private static let key = "madeira.orientationLock"

    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            apply()
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? Mode.auto.rawValue
        self.mode = Mode(rawValue: saved) ?? .auto
    }

    var mask: UIInterfaceOrientationMask { mode.mask }

    func apply() {
        let targetMask = mode.mask
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: targetMask)
            windowScene.requestGeometryUpdate(prefs) { _ in }
        }
    }
}

final class MadeiraAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.shared.mask }
    }
}

@main
struct MadeiraApp: App {
    @UIApplicationDelegateAdaptor(MadeiraAppDelegate.self) private var appDelegate

    init() {
        // A component may ship the Wine unix half as a dylib. When one does, this loads it
        // and the bridge starts Wine from that half instead of the linked archive, so a
        // unix-side change is a package install rather than an app rebuild. No-op (one log
        // line) when no component provides one.
        UnixHalf.install()
        // A package pushed into Documents/Import is installed on the next launch, so a
        // component release takes no UI interaction at all.
        Task { @MainActor in WCPComponentsModel.shared.installInboxAtLaunch() }
        // A debugger that is attached now may be gone before Play is tapped: under
        // LiveContainer it is the guest's launch session, which detaches as soon as it
        // has set CS_DEBUGGED. Take the JIT pool inside that window so a later launch
        // has one. No-op (one decision, no work) when nothing is attached.
        Task.detached(priority: .userInitiated) { StikJITHelper.claimPoolWhileTraced() }
        // Opt-in iPhone pointer experiments (PhonePointer.m): before any scene exists.
        madeira_phone_pointer_setup()
        // madeira-bcd: the Metal Performance HUD's performance insights (the
        // notes that stack up left of its panel: shader compiles, similar render
        // passes, blit encoders) cover the game. Off unless madeira.cfg says
        // env.MTL_HUD_INSIGHTS_ENABLED = 1, which is exported later and wins.
        setenv("MTL_HUD_INSIGHTS_ENABLED", "0", 0)
        // Host pads as Windows.Gaming.Input gamepads (upstream's opt-in provider, willfaust/wine #40):
        // on by default here; madeira.cfg env.MADEIRA_WGI_HOST_PADS = 0 is exported later and wins.
        setenv("MADEIRA_WGI_HOST_PADS", "1", 0)
        // ml1172: read the screen on the main thread; library entries, whose
        // default Resolution comes from it, are also made on other threads.
        _ = ResolutionChoices.screen
        // A sign-in an installer left goes into the Keychain before anything else runs
        // (SigningRefresh.swift), only while the refresh is switched on.
        if SigningRefresh.enabled { SigningAccountStore.takeIn() }
        // Use one profile before Wine or Steam Cloud reads the prefix.
        ProfileUnification.run()
        // Games and downloads keep going when Madeira leaves the screen (BackgroundRun.swift).
        BackgroundRun.shared.start()
        // Read the cached library before the first grid page is built.
        if LibraryGridArm.enabled, SteamOwnedLibrary.enabled { SteamOwnedLibrary.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(InteractionFrameRateInstaller())   // touch frame-rate request (New library grid)
                .modifier(ClaimGamepadEvents())
                .onAppear {
                    ExternalDrives.shared.mountAll()
                    GamepadInput.shared.start()
                    HardwareInput.shared.start()
                    JITNetworkShortcut.shared.restoreLeftover()   // also starts its network path monitor
                    WineGeckoModel.shared.installAutomatically()  // on Wi-Fi, so Wine never asks (WineGecko.swift)
                    AchievementWatcher.shared.start()             // unlock banners from Steam's stats files (SteamAchievements.swift)
                    ClaudeHelp.install()                          // the fixes guide beside madeira-log.txt (ClaudeHelp.swift)
                    if OrientationLock.shared.mode != .auto {
                        OrientationLock.shared.apply()
                    }
                }
                // madeira://jit-network/... (the Madeira JIT shortcut returning, JITNetwork.swift),
                // else a .wcp component package, else a shared game setup (a .madeirasetup file or
                // madeira://setup?d=..., GameSetupShare.swift), else madeira://play?exe=...
                // (Home Screen shortcuts, SavesAndShortcuts.swift).
                .onOpenURL { url in
                    if url.isFileURL && url.pathExtension.lowercased() == "wcp" {
                        Task { @MainActor in WCPComponentsModel.shared.install(from: url) }
                        return
                    }
                    // madeira://wcp?url=https://… downloads and installs a package, and
                    // madeira://wcp scans Madeira's Import folder. Both exist so a
                    // component can be installed without the Files sheet, which
                    // iOS 26/27 sometimes stops delivering taps to.
                    if url.scheme?.lowercased() == "madeira", url.host?.lowercased() == "wcp" {
                        let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first { $0.name.lowercased() == "url" }?.value
                        Task { @MainActor in
                            if let link, !link.isEmpty {
                                WCPComponentsModel.shared.install(remote: link)
                            } else {
                                WCPComponentsModel.shared.importWaitingPackages()
                            }
                        }
                        return
                    }
                    if JITNetworkShortcut.shared.handle(url) || GameSetupInbox.shared.handle(url) { return }
                    ShortcutRouter.shared.handle(url)
                }
        }
    }
}
