// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Madeira's own VPN for built-in JIT (PlugIns/MadeiraLoopback.appex, built from
// build/madeira-loopback), in place of LocalDevVPN: the JIT helper reaches this device's
// lockdownd at 10.7.0.1 through it, so no other app is needed. LocalDevVPNControl starts
// it when the loopback does not answer; one already connected (LocalDevVPN's, say) is
// used as it is. The first start asks iOS once to allow Madeira to add a VPN
// configuration; Settings › VPN lists it as "Madeira JIT". iOS runs one VPN at a time, so
// it takes over from Tailscale while it is connected. (Lucid's LucidVPN, the same tunnel,
// reached lockdownd this way on the iPhone Duo.)
//
// Log tag: [jit-vpn].

import Foundation
import NetworkExtension

@MainActor
enum MadeiraVPN {
    nonisolated static let extensionFile = "MadeiraLoopback.appex"

    /// The extension's bundle ID in this installation (the sign script gives it
    /// <bundle>.Loopback); nil in a build without it, which keeps LocalDevVPN.
    nonisolated static var identifier: String? {
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appendingPathComponent(extensionFile))?.bundleIdentifier }
    }
    /// The extension is built for iOS 26 (build/madeira-loopback); before that it cannot run.
    /// iOS has allowed the configuration once, so starting it asks nothing.
    static var configured: Bool { UserDefaults.standard.bool(forKey: "madeiraVPNConfigured") }

    nonisolated static var available: Bool {
        if #available(iOS 26.0, *) { return identifier != nil }
        return false
    }

    private static func failure(_ code: Int, _ message: String) -> Error {
        NSError(domain: "MadeiraVPN", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Starts Madeira's VPN and calls back once lockdownd answers through it.
    static func start(_ done: @escaping (Result<Void, Error>) -> Void) {
        guard let identifier else {
            done(.failure(failure(30, "Madeira's VPN is missing from this installation. Reinstall Madeira.")))
            return
        }
        LogStore.shared.log("[jit-vpn] starting Madeira's VPN")
        configuration(identifier) { manager, error in
            guard let manager else {
                LogStore.shared.log("[jit-vpn] configuration refused")
                done(.failure(failure(31, "Madeira needs its VPN for JIT, and iOS didn't add it: \(error?.localizedDescription ?? "no reason given"). Try again and tap Allow.")))
                return
            }
            UserDefaults.standard.set(true, forKey: "madeiraVPNConfigured")
            do { try manager.connection.startVPNTunnel() } catch {
                done(.failure(failure(32, "Madeira's VPN didn't start: \(error.localizedDescription)")))
                return
            }
            waitForConnection(manager, until: Date().addingTimeInterval(20), done)
        }
    }

    /// Disconnects Madeira's VPN (nothing happens when another VPN is the one connected).
    static func stop(_ done: @escaping () -> Void) {
        guard let identifier else { done(); return }
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            DispatchQueue.main.async {
                managers?.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier }?
                    .connection.stopVPNTunnel()
                LogStore.shared.log("[jit-vpn] stopped")
                done()
            }
        }
    }

    /// Madeira's VPN configuration, saved and enabled; the first save is when iOS asks.
    private static func configuration(_ identifier: String, _ done: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            DispatchQueue.main.async {
                let manager = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
                } ?? NETunnelProviderManager()
                let config = NETunnelProviderProtocol()
                config.providerBundleIdentifier = identifier
                config.serverAddress = "This device"
                manager.protocolConfiguration = config
                manager.localizedDescription = "Madeira JIT"
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    DispatchQueue.main.async {
                        if let error { done(nil, error); return }
                        manager.loadFromPreferences { _ in DispatchQueue.main.async { done(manager, nil) } }
                    }
                }
            }
        }
    }

    private static func waitForConnection(_ manager: NETunnelProviderManager, until deadline: Date,
                                          _ done: @escaping (Result<Void, Error>) -> Void) {
        if manager.connection.status == .connected {
            // The tunnel's routes take a moment to settle after it reports in.
            LoopbackProbe.waitUntilReachable(within: 5) { probe in
                LogStore.shared.log("[jit-vpn] connected; lockdownd \(probe.reachable ? "answers" : "does not answer")")
                done(probe.reachable ? .success(()) : .failure(failure(33,
                    "Madeira's VPN is on, but this device didn't answer through it. Turn Wi-Fi on or turn cellular data off, then try again.")))
            }
            return
        }
        guard Date() < deadline else {
            done(.failure(failure(34, "Madeira's VPN didn't connect. Check Settings › VPN, then try again.")))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            waitForConnection(manager, until: deadline, done)
        }
    }
}
