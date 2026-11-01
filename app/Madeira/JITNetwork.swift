// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Getting this device's own network path ready for JIT (docs/JIT.md).
//
// Built-in StikJIT and StikDebug reach this device's lockdownd through
// LocalDevVPN's loopback, which works on Wi-Fi or with no network at all but
// not over cellular data. Enable JIT first checks the loopback directly
// (LoopbackProbe, milliseconds when it works). Only when that fails, and the
// Madeira JIT shortcut is turned on, does Madeira run the shortcut to turn
// Cellular Data off (when there is no Wi-Fi) and connect LocalDevVPN; once a
// game's JIT pool is mapped and the debugger has left, it runs it again to put
// both back. Log tags: [jit-loopback], [jit-shortcut].

import Combine
import Darwin
import Foundation
import Network
import UIKit
import SwiftUI

/// Whether LocalDevVPN's loopback reaches this device's lockdownd at 10.7.0.1:62078
/// (the address StikDebug uses). Two steps, neither depending on what lockdownd says
/// (over USB it answers a plain QueryType; through the tunnel it closed the connection):
/// 1. The route: the interface traffic to 10.7.0.1 would leave by, asked of the kernel
///    with an unsent UDP connect (no packets, microseconds). Not a VPN interface means
///    LocalDevVPN is not routing it, so a network that accepts any connection (a proxy;
///    the 18 Pro's Wi-Fi has one) is never asked.
///    It must also be LocalDevVPN's interface, whose address is in 10.7.0.0/16 (10.7.1.1
///    on the 18 Pro): another VPN carrying all traffic (172.19.0.1 there) also routes
///    10.7.0.1 and accepts the connection, but the JIT helper then reads "early eof".
/// 2. Through LocalDevVPN: a TCP connection, at most `timeout`. Through a working
///    tunnel it opens in milliseconds; over cellular data, where the tunnel does not
///    work, it fails. Nothing is sent, and it is closed at once.
enum LoopbackProbe {
    static let address = "10.7.0.1"
    static let port: UInt16 = 62078

    struct Result {
        let reachable: Bool
        let milliseconds: Double
        let detail: String
    }

    struct Route {
        let interface: String
        let address: String
        /// utun (packet tunnels such as LocalDevVPN), ipsec or ppp.
        var isVPN: Bool { ["utun", "ipsec", "ppp"].contains { interface.hasPrefix($0) } }
        /// LocalDevVPN's own tunnel: a VPN interface whose address is in its 10.7.0.0/16.
        var isLocalDevVPN: Bool { isVPN && address.hasPrefix("10.7.") }
    }

    private static func target() -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        return inet_pton(AF_INET, address, &addr.sin_addr) == 1 ? addr : nil
    }

    private static func connect(_ fd: Int32, _ addr: inout sockaddr_in) -> Int32 {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// The interface and local address traffic to 10.7.0.1 would leave by; nil without a route.
    static func route() -> Route? {
        guard var addr = target() else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connect(fd, &addr) == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = local.sin_addr
        inet_ntop(AF_INET, &sin, &text, socklen_t(INET_ADDRSTRLEN))
        return Route(interface: interfaceName(holding: local.sin_addr.s_addr) ?? "?", address: String(cString: text))
    }

    private static func interfaceName(holding ip: in_addr_t) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
               sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee.sin_addr.s_addr }) == ip {
                return String(cString: entry.pointee.ifa_name)
            }
            cursor = entry.pointee.ifa_next
        }
        return nil
    }

    /// Blocks for at most `timeout`; use `check(timeout:completion:)` from the main thread.
    /// `requireVPN` is false only for host tests, whose listeners are on lo0.
    static func check(timeout: TimeInterval = 0.4, requireVPN: Bool = true) -> Result {
        let start = CFAbsoluteTimeGetCurrent()
        func done(_ ok: Bool, _ detail: String) -> Result {
            Result(reachable: ok, milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000, detail: detail)
        }
        guard let route = route() else { return done(false, "no route") }
        if requireVPN, !route.isVPN { return done(false, "routed via \(route.interface), not a VPN") }
        if requireVPN, !route.isLocalDevVPN {
            return done(false, "routed via \(route.interface) \(route.address): another VPN, not LocalDevVPN")
        }
        guard var addr = target() else { return done(false, "bad address") }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return done(false, "socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        if connect(fd, &addr) != 0 {
            guard errno == EINPROGRESS else { return done(false, String(cString: strerror(errno))) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(max(1, (start + timeout - CFAbsoluteTimeGetCurrent()) * 1000)))
            guard ready > 0 else { return done(false, ready == 0 ? "timed out via \(route.interface)" : String(cString: strerror(errno))) }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return done(false, "\(String(cString: strerror(err))) via \(route.interface)") }
        }
        return done(true, "connected via \(route.interface) \(route.address)")
    }

    static func check(timeout: TimeInterval = 0.4, completion: @escaping @MainActor (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = check(timeout: timeout)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Checks again until the loopback answers or `within` seconds pass: a VPN that
    /// was just connected needs a moment before it routes.
    static func waitUntilReachable(within: TimeInterval, completion: @escaping @MainActor (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = CFAbsoluteTimeGetCurrent() + within
            var result = check(timeout: 0.4)
            while !result.reachable, CFAbsoluteTimeGetCurrent() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                result = check(timeout: 0.4)
            }
            let final = result
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(final) } }
        }
    }

    /// LocalDevVPN is connected: traffic to 10.7.0.1 leaves by its tunnel. Instant: no
    /// network traffic.
    static var vpnInterfaceUp: Bool { route()?.isLocalDevVPN ?? false }

    /// Another VPN is connected (Tailscale, a work VPN): a VPN interface holds an IPv4
    /// address outside 10.7.0.0/16. The route to 10.7.0.1 alone misses a split tunnel.
    /// iOS's own utun interfaces carry only IPv6 link-local addresses.
    static var otherVPNUp: Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let name = String(cString: entry.pointee.ifa_name)
            guard ["utun", "ipsec", "ppp"].contains(where: { name.hasPrefix($0) }),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin, &text, socklen_t(INET_ADDRSTRLEN))
            if !String(cString: text).hasPrefix("10.7.") { return true }
        }
        return false
    }
}

/// The Madeira JIT shortcut, two ways to add it. `iCloudLink` opens Shortcuts straight at
/// Add Shortcut, but needs a connection: iOS opens a shortcut directly only from an iCloud
/// link (its import-shortcut URL refuses any other). The bundled copy
/// (app/Madeira/Madeira JIT.shortcut, a signed export) installs with none, but only the
/// share sheet can hand a file to Shortcuts: iOS gives Shortcuts that file only when the
/// user picks it there. Shortcuts names an import after the file, "Madeira JIT".
///
/// The link lives only while the shared shortcut stays in its owner's library: deleting
/// it there breaks the link ("Shortcut Not Found"), as happened to the first one.
///
/// THE TWO MUST BE THE SAME SHORTCUT: change it, then share a new iCloud link and export
/// a new file (Share › Options › Anyone › Save to Files), and replace both here. The
/// file's signing certificate expires on 26 Oct 2027. iOS 27 and later only: it keeps the
/// previous VPN with Store Content, which iOS 26 lacks.
enum JITShortcutFile {
    static let iCloudLink = URL(string: "https://www.icloud.com/shortcuts/0cd955d14dd240e3aa3fed5fa9248a37")!
    static var url: URL? { Bundle.main.url(forResource: "Madeira JIT", withExtension: "shortcut") }
    static var supported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }
}

/// The user's "Madeira JIT" shortcut (docs/JIT.md has its steps). Input "start",
/// with "cellular" when Madeira sees cellular data and no Wi-Fi: keep the VPN that is
/// connected (Get Current VPN into Store Content; iOS connects one VPN at a time, so
/// LocalDevVPN replaces it), turn Cellular Data off (only when asked), connect
/// LocalDevVPN, and output that VPN, which tells Madeira whether one was on. Input
/// "done", with "cellular" when "start" had it: turn Cellular Data back on; "vpn-off":
/// disconnect LocalDevVPN (no VPN was on); "vpn-restore": connect the kept VPN again.
/// Only Store Content keeps a VPN that Set VPN accepts: as text (a file, or a name
/// Madeira passed back) it is only a name, which Set VPN cannot convert ("couldn't
/// convert from Text to VPN"). Madeira runs "done" after any "start".
///
/// An app can only run a shortcut by opening the Shortcuts app, so each run leaves
/// Madeira for a moment and comes back through x-callback-url
/// (madeira://jit-network/...). Off unless Settings › JIT › Madeira JIT shortcut
/// turns it on (madeira.cfg env.MADEIRA_JIT_SHORTCUT = 1): without the shortcut the
/// Shortcuts app would only report that it is missing.
@MainActor final class JITNetworkShortcut: ObservableObject {
    static let shared = JITNetworkShortcut()
    static let name = "Madeira JIT"

    /// Settings › JIT › Madeira JIT shortcut: when LocalDevVPN's loopback does not answer,
    /// Enable JIT runs the shortcut. Off unless it is 1.
    @Published var enabled = MadeiraConfig.flag("MADEIRA_JIT_SHORTCUT", fallback: false) {
        didSet {
            guard enabled != oldValue else { return }
            MadeiraConfig.set("env.MADEIRA_JIT_SHORTCUT", enabled ? "1" : nil)
            LogStore.shared.log("[jit-shortcut] setting on=\(enabled ? 1 : 0)")
        }
    }

    enum Outcome { case done(String), failed(String) }

    /// Cellular data is carrying traffic and there is no Wi-Fi: the case LocalDevVPN's
    /// loopback cannot work in. From the system's network path, kept current.
    var cellularOnly: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
    }
    private let monitor = NWPathMonitor()

    private init() {
        monitor.start(queue: DispatchQueue(label: "madeira.jit-network.path"))
    }

    /// The "done" input owed since a "start" (see above); nil when none. Kept on disk, so
    /// a run that ends between them (Madeira closed or crashed) is put back at the next
    /// launch. Main thread.
    private static let pendingKey = "madeiraJITShortcutPendingDone"
    private var pending: String? {
        get { UserDefaults.standard.string(forKey: Self.pendingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingKey) }
    }
    private var waiting: ((Outcome) -> Void)?
    private var timeout: Timer?
    private var restoring = false
    private var restoreWaiters: [() -> Void] = []

    /// Runs "start". Pending from before it runs: even a "start" that fails part-way may
    /// have changed something.
    func start(completion: @escaping (Outcome) -> Void) {
        let cellular = cellularOnly
        let base = cellular ? "done cellular" : "done"
        // LocalDevVPN already connected (its tunnel just does not work over cellular
        // data): "done" leaves it. Until "start" reports the VPN, "done" leaves VPNs alone.
        let localDevVPNWasUp = LoopbackProbe.vpnInterfaceUp
        pending = base
        run(cellular ? "start cellular" : "start") { [weak self] outcome in
            if case .done(let output) = outcome, !localDevVPNWasUp {
                let vpnWasOn = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                self?.pending = base + (vpnWasOn ? " vpn-restore" : " vpn-off")
            }
            completion(outcome)
        }
    }

    /// Runs "done" when "start" ran since the last "done", then calls `completion`.
    func restoreIfNeeded(completion: @escaping () -> Void) {
        if restoring { restoreWaiters.append(completion); return }
        guard let input = pending else { completion(); return }
        restoring = true
        restoreWaiters = [completion]
        pending = nil
        run(input) { [weak self] _ in
            guard let self else { return }
            self.restoring = false
            let waiters = self.restoreWaiters
            self.restoreWaiters.removeAll()
            waiters.forEach { $0() }
        }
    }

    /// At launch: a run that ended between "start" and "done" left the device without
    /// cellular data or its VPN; put them back.
    func restoreLeftover() {
        guard pending != nil, enabled else { return }
        LogStore.shared.log("[jit-shortcut] an earlier run ended before done: restoring now")
        restoreIfNeeded {}
    }

    /// From the launch thread, right after the debugger detached: runs "done" if
    /// needed and blocks until Madeira is back (or `timeout` passes). Nothing draws
    /// yet at that point, so the moment in the background is safe.
    nonisolated static func restoreBlocking(timeout: TimeInterval = 30) {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { shared.restoreIfNeeded { finished.signal() } }
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            LogStore.shared.log("[jit-shortcut] done did not return within \(Int(timeout)) s; continuing", level: .error)
        }
    }

    private func run(_ input: String, completion: @escaping (Outcome) -> Void) {
        finish(.failed("superseded"))
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "x-callback-url"
        c.path = "/run-shortcut"
        c.queryItems = [
            URLQueryItem(name: "name", value: Self.name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: input),
            URLQueryItem(name: "x-success", value: "madeira://jit-network/success"),
            URLQueryItem(name: "x-error", value: "madeira://jit-network/error"),
            URLQueryItem(name: "x-cancel", value: "madeira://jit-network/cancel")
        ]
        guard let url = c.url else { completion(.failed("bad shortcut URL")); return }
        LogStore.shared.log("[jit-shortcut] run input=\(input)")
        waiting = completion
        timeout = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.failed("the shortcut did not return within 60 s")) }
        }
        UIApplication.shared.open(url) { [weak self] opened in
            if !opened { MainActor.assumeIsolated { self?.finish(.failed("Shortcuts could not be opened")) } }
        }
    }

    /// madeira://jit-network/{success|error|cancel}, from Shortcuts' x-callback-url.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "madeira", url.host == "jit-network" else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value ?? "" }
        switch url.path {
        case "/success": finish(.done(value("result")))
        case "/error":   finish(.failed(value("errorMessage").isEmpty ? "the shortcut failed" : value("errorMessage")))
        default:         finish(.failed("the shortcut was cancelled"))
        }
        return true
    }

    private func finish(_ outcome: Outcome) {
        timeout?.invalidate()
        timeout = nil
        guard let waiting else { return }
        self.waiting = nil
        switch outcome {
        case .done(let result): LogStore.shared.log("[jit-shortcut] returned output=\(result.isEmpty ? "none" : "a VPN name")")
        case .failed(let why):  LogStore.shared.log("[jit-shortcut] failed: \(why)", level: .error)
        }
        waiting(outcome)
    }
}


/// Controls the installed LocalDevVPN app through its documented enable/disable
/// URLs. Opening an app is not connection success: report the measured loopback.
@MainActor final class LocalDevVPNControl: ObservableObject {
    static let shared = LocalDevVPNControl()
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var completions: [(Result<Void, Error>) -> Void] = []
    private var operation = 0

    func refresh() {
        guard !busy else { return }
        connected = LoopbackProbe.vpnInterfaceUp
        if StikJITHelper.ready { message = nil }   // JIT came on another way: nothing left to say
    }

    private func failure(_ message: String) -> Error {
        NSError(domain: "MadeiraLocalDevVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// `openingApps`: false for the automatic start, which neither opens LocalDevVPN nor
    /// says anything when the VPN is not there; Play does both.
    func connect(openingApps: Bool = true, completion: @escaping (Result<Void, Error>) -> Void) {
        if busy {
            // Only connect operations accept joiners; disconnect disables controls.
            if !completions.isEmpty { completions.append(completion) }
            else { completion(.failure(failure("LocalDevVPN is disconnecting. Try again when it finishes."))) }
            return
        }
        busy = true
        message = "Checking connection…"
        completions = [completion]
        operation += 1
        let current = operation
        LoopbackProbe.check { [weak self] probe in
            guard let self, self.operation == current else { return }
            if probe.reachable { self.finish(.success(())); return }
            // Madeira's own VPN when this build has it: no other app to install or open. If it
            // cannot start (no Network Extensions entitlement, or Don't Allow), LocalDevVPN
            // still can when it is installed.
            if MadeiraVPN.available {
                self.message = "Starting Madeira's VPN…"
                MadeiraVPN.start { [weak self] result in
                    guard let self, self.operation == current else { return }
                    if case .failure(let error) = result, openingApps, LocalDevVPN.appInstalled {
                        LogStore.shared.log("[jit-vpn] Madeira's VPN did not start (\(error.localizedDescription)): LocalDevVPN instead")
                        LocalDevVPN.fellBack = true
                        self.openLocalDevVPN(current)
                    } else {
                        if case .success = result { LocalDevVPN.fellBack = false }
                        self.finish(result, quiet: !openingApps)
                    }
                }
                return
            }
            guard openingApps else {
                self.finish(.failure(self.failure("LocalDevVPN is not connected.")), quiet: true)
                return
            }
            guard LocalDevVPN.appInstalled else {
                self.finish(.failure(self.failure("Install LocalDevVPN, open it once to approve its VPN configuration, then try again.")))
                return
            }
            self.openLocalDevVPN(current)
        }
    }

    /// Connects LocalDevVPN through its enable URL, then waits for the loopback to answer.
    private func openLocalDevVPN(_ current: Int) {
        self.message = "Connecting…"
        UIApplication.shared.open(LocalDevVPN.connect) { [weak self] opened in
            Task { @MainActor in
                guard let self, self.operation == current else { return }
                guard opened else {
                    self.finish(.failure(self.failure("LocalDevVPN could not open. Open it once, then try again.")))
                    return
                }
                LoopbackProbe.waitUntilReachable(within: 25) { [weak self] result in
                    guard let self, self.operation == current else { return }
                    if result.reachable { self.finish(.success(())) }
                    else {
                        self.finish(.failure(self.failure("LocalDevVPN is not reaching this device. Approve its VPN configuration if asked. On cellular-only connections, use the Madeira JIT shortcut or connect to Wi-Fi.")))
                    }
                }
            }
        }
    }

    /// `quiet`: a failure leaves no message in the bar (the automatic start's).
    private func finish(_ result: Result<Void, Error>, quiet: Bool = false) {
        connected = LoopbackProbe.vpnInterfaceUp
        busy = false
        switch result {
        case .success: message = nil
        case .failure(let error): message = quiet ? nil : error.localizedDescription
        }
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0(result) }
    }

    func setEnabled(_ wanted: Bool) {
        guard !busy else { return }
        if wanted { connect { _ in }; return }
        if MadeiraVPN.available && !LocalDevVPN.fellBack {
            busy = true
            message = "Disconnecting…"
            operation += 1
            let current = operation
            MadeiraVPN.stop { [weak self] in
                Task { @MainActor [weak self] in
                    for _ in 0..<20 {
                        guard let self, self.operation == current else { return }
                        if !LoopbackProbe.vpnInterfaceUp { self.finish(.success(())); return }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    guard let self, self.operation == current else { return }
                    self.finish(.failure(self.failure("Another VPN is still connected. Turn it off in Settings › VPN.")))
                }
            }
            return
        }
        guard LocalDevVPN.appInstalled else {
            message = "Open the app that owns this VPN to disconnect it."
            return
        }
        busy = true
        message = "Disconnecting…"
        operation += 1
        let current = operation
        let url = URL(string: "localdevvpn://disable?scheme=madeira")!
        UIApplication.shared.open(url) { [weak self] opened in
            Task { @MainActor in
                guard let self, self.operation == current else { return }
                guard opened else {
                    self.finish(.failure(self.failure("LocalDevVPN could not open.")))
                    return
                }
                // LocalDevVPN returns before its tunnel has fully stopped.
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard self.operation == current else { return }
                    if !LoopbackProbe.vpnInterfaceUp { self.finish(.success(())); return }
                }
                self.finish(.failure(self.failure("The local tunnel is still connected. Check LocalDevVPN or the app that owns this VPN.")))
            }
        }
    }
}

/// Always visible at the top of the library, with real connection state. Disabling
/// the tunnel mid-attach would break JIT, so the switch waits for setup to finish.
struct JITConnectionBar: View {
    @ObservedObject private var vpn = LocalDevVPNControl.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var jitState = LibraryJITState.shared
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    // Once JIT is ready and nothing needs attention, the bar steps aside: it sat
    // over the library's first row (Desktop).
    var body: some View {
        if jitState.enabled && !vpn.busy && !jit.busy {
            Color.clear.frame(height: 0)
        } else {
            bar
        }
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                if vpn.busy || jit.busy { ProgressView().controlSize(.small) }
                Toggle(isOn: Binding(get: { vpn.connected }, set: { vpn.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalDevVPN.name).font(.subheadline.weight(.semibold))
                        Text(jit.busy ? (jit.status ?? "Preparing JIT…") :
                             StikJITHelper.ready ? "JIT ready" : vpn.connected ? "Connected" : "Connects automatically for JIT")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)
                .disabled(vpn.busy || jit.busy)
                .accessibilityIdentifier("localdevvpn.toggle")
                Button { jit.showSetup = true } label: {
                    Image(systemName: "gearshape").padding(6)
                }
                .accessibilityLabel("JIT setup")
            }
            if let message = vpn.message, !vpn.busy {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.regularMaterial)
        .onAppear { vpn.refresh() }
        .onReceive(refresh) { _ in vpn.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in vpn.refresh() }
    }
}
