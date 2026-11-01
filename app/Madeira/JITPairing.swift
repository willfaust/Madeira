// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import BackgroundTasks
import dnssd
import Foundation
import SwiftUI
import UIKit
import UserNotifications

// On-device pairing for Built-in StikJIT (docs/JIT.md, "On-device pairing").
//
// iOS 27 can pair with a computer it finds on the local network, started from
// the iPhone: Settings › Privacy & Security › Developer Mode lists every
// `_remotepairing-pairable-host._tcp` service, and pairing with one asks for the
// PIN that host shows. Madeira plays that computer for its own iPhone:
// libmadeira_rppairing (build/rppairing-ios, idevice's PairableHost) listens on
// a port and runs the pairing; this file publishes the port through
// mDNSResponder (dns_sd, so only the Local Network permission is needed, not
// the multicast entitlement) and stores the resulting RPPairing file where
// Built-in StikJIT reads it.
//
// The user pairs from Settings, so Madeira has to keep running in the
// background: a BGContinuedProcessingTask ("<bundle id>.pairing.session",
// permitted by `$(PRODUCT_BUNDLE_IDENTIFIER).pairing.*` in Info.plist) whose
// system progress UI also shows the PIN. When iOS refuses it (for example a
// re-signed bundle whose identifier no longer matches), only the short
// background grace period remains, and the page says so. The PIN is also sent
// as a local notification.
//
// Log tag: [jit-pairing] (states only: no PIN, device name or identifiers).
@MainActor final class OnDevicePairing: ObservableObject {
    static let shared = OnDevicePairing()

    /// Shown on the iPhone as "Pair with Madeira"; the host identifier is derived from it.
    static let hostName = "Madeira"
    static let timeout: TimeInterval = 300

    enum Phase: Equatable {
        case idle
        /// Advertised; the user pairs from Settings.
        case waiting
        /// The iPhone asked for the code.
        case pin(String)
        case paired(device: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// iOS refused the continued-processing task: Madeira can only wait briefly in the background.
    @Published private(set) var backgroundLimited = false

    static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    var isShowingPin: Bool {
        if case .pin = phase { return true }
        return false
    }

    var active: Bool {
        switch phase {
        case .waiting, .pin: return true
        default: return false
        }
    }

    private var session: OpaquePointer?
    private var registration: DNSServiceRef?
    private var continued: AnyObject?            // BGContinuedProcessingTask (iOS 26+)
    private var registered: String?
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var deadline: Timer?

    private init() {}

    private func log(_ line: String) { LogStore.shared.log("[jit-pairing] " + line) }

    /// False when nothing started and no phase change follows (a pairing is already
    /// running, or the last one is still closing). A failure to start publishes `.failed`.
    @discardableResult
    func start() -> Bool {
        guard Self.isSupported, !active, session == nil else { return false }
        var error: UnsafeMutablePointer<CChar>?
        guard let session = madeira_rppairing_new(Self.hostName, &error) else {
            fail(Self.take(error) ?? "Madeira could not open its pairing port.")
            return true
        }
        self.session = session
        phase = .waiting
        backgroundLimited = false
        log("started")
        requestNotifications()
        guard publish(session) else {
            madeira_rppairing_free(session)
            self.session = nil
            return true
        }
        beginBackground()
        deadline = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { _ in
            MainActor.assumeIsolated { OnDevicePairing.shared.cancel(reason: "Pairing timed out. Try again when you are ready to pair from Settings.") }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = 0
            var device: UnsafeMutablePointer<CChar>?
            var failure: UnsafeMutablePointer<CChar>?
            let status = madeira_rppairing_accept(session, { pin, _ in
                guard let pin else { return }
                let code = String(cString: pin)
                DispatchQueue.main.async { OnDevicePairing.shared.showPin(code) }
            }, nil, &bytes, &length, &device, &failure)
            let data = bytes.map { Data(bytes: $0, count: length) }
            madeira_rppairing_bytes_free(bytes, length)
            let name = Self.take(device)
            let message = Self.take(failure)
            DispatchQueue.main.async {
                OnDevicePairing.shared.finished(status: status, data: data, device: name, message: message)
            }
        }
        return true
    }

    /// Stops a pairing in progress. `reason` is shown as the failure; nil returns to idle.
    func cancel(reason: String? = nil) {
        guard let session else { return }
        madeira_rppairing_cancel(session)
        stopAdvertising()
        phase = reason.map(Phase.failed) ?? .idle
        log(reason == nil ? "cancelled" : "stopped")
    }

    private func showPin(_ pin: String) {
        guard active else { return }
        phase = .pin(pin)
        log("code shown")
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.updateTitle("Pairing code \(pin)", subtitle: "Enter it on this \(Self.deviceKind) to pair with Madeira")
            task.progress.completedUnitCount = 1
        }
        if UIApplication.shared.applicationState != .active {
            notify("Madeira pairing code: \(pin)", body: "Enter this code on your \(Self.deviceKind) to finish pairing.")
        }
    }

    private func finished(status: Int32, data: Data?, device: String?, message: String?) {
        if let session { madeira_rppairing_free(session) }
        session = nil
        stopAdvertising()
        deadline?.invalidate()
        deadline = nil
        switch status {
        case 0:
            do {
                guard let data else { throw NSError(domain: "MadeiraJIT", code: 20) }
                try JITCoordinator.shared.storeOnDevicePairing(data)
                phase = .paired(device: device ?? "this \(Self.deviceKind)")
                log("paired")
                if UIApplication.shared.applicationState != .active {
                    notify("Paired with Madeira", body: "Return to Madeira to finish setting up JIT.")
                }
                endBackground(success: true)
            } catch {
                fail("Pairing finished, but Madeira could not save the pairing file.")
            }
        case 2:
            endBackground(success: false)
        default:
            fail(message.map { "Pairing failed: \($0)" } ?? "Pairing failed. Try again.")
        }
    }

    private func fail(_ message: String) {
        if let session {
            madeira_rppairing_cancel(session)
        }
        stopAdvertising()
        phase = .failed(message)
        log("failed")
        endBackground(success: false)
    }

    private static var deviceKind: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    nonisolated private static func take(_ string: UnsafeMutablePointer<CChar>?) -> String? {
        guard let string else { return nil }
        defer { madeira_rppairing_string_free(string) }
        return String(cString: string)
    }

    // MARK: Advertising

    private func publish(_ session: OpaquePointer) -> Bool {
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        for index in 0..<madeira_rppairing_txt_count(session) {
            guard let key = madeira_rppairing_txt_key(session, index),
                  let value = madeira_rppairing_txt_value(session, index) else { continue }
            TXTRecordSetValue(&txt, key, UInt8(clamping: strlen(value)), value)
        }
        var ref: DNSServiceRef?
        let error = DNSServiceRegister(
            &ref, 0, 0, madeira_rppairing_service_name(session), "_remotepairing-pairable-host._tcp", nil, nil,
            madeira_rppairing_port(session).bigEndian, TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
            { _, _, error, _, _, _, _ in
                guard error != DNSServiceErrorType(kDNSServiceErr_NoError) else { return }
                DispatchQueue.main.async { OnDevicePairing.shared.advertisingFailed(error) }
            }, nil)
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            advertisingFailed(error)
            return false
        }
        DNSServiceSetDispatchQueue(ref, .main)
        registration = ref
        return true
    }

    private func advertisingFailed(_ error: DNSServiceErrorType) {
        guard active else { return }
        log("advertising failed error=\(error)")
        fail(error == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
             ? "Madeira needs Local Network access to pair. Allow it in Settings › Apps › Madeira, then try again."
             : "Madeira could not announce itself on the local network. Check that Wi-Fi is on, then try again.")
    }

    private func stopAdvertising() {
        if let registration { DNSServiceRefDeallocate(registration) }
        registration = nil
    }

    // MARK: Background

    /// The permitted "<bundle id>.pairing.*" identifier from Info.plist, made concrete.
    private var taskIdentifier: String? {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let wildcard = permitted.first(where: { $0.hasSuffix(".pairing.*") }) else { return nil }
        return String(wildcard.dropLast()) + "session"
    }

    private func beginBackground() {
        grace = UIApplication.shared.beginBackgroundTask(withName: "Madeira pairing") {
            MainActor.assumeIsolated {
                let pairing = OnDevicePairing.shared
                if pairing.continued == nil && pairing.active {
                    pairing.cancel(reason: "iOS stopped Madeira in the background before pairing finished. Try again, and pair from Settings straight away.")
                }
                pairing.endGrace()
            }
        }
        if #available(iOS 26.0, *) { submitContinued() } else { backgroundLimited = true }
    }

    @available(iOS 26.0, *)
    private func submitContinued() {
        guard let identifier = taskIdentifier else { backgroundLimited = true; return }
        if registered != identifier {
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                MainActor.assumeIsolated { OnDevicePairing.shared.attach(task) }
            }
            guard ok else { log("register refused"); backgroundLimited = true; return }
            registered = identifier
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Pairing with Madeira",
                                                       subtitle: "Settings › Privacy & Security › Developer Mode")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            log("continued-processing submitted")
        } catch {
            log("continued-processing refused")
            backgroundLimited = true
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        guard active else { task.setTaskCompleted(success: false); return }
        continued = task
        task.progress.totalUnitCount = 2
        if case .pin(let pin) = phase {
            task.updateTitle("Pairing code \(pin)", subtitle: "Enter it on this \(Self.deviceKind) to pair with Madeira")
            task.progress.completedUnitCount = 1
        }
        task.expirationHandler = {
            DispatchQueue.main.async {
                OnDevicePairing.shared.continued = nil
                OnDevicePairing.shared.cancel(reason: "iOS stopped the pairing in the background. Try again.")
            }
        }
        log("continued-processing running")
    }

    private func endBackground(success: Bool) {
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        continued = nil
        endGrace()
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    // MARK: Notifications

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "madeira.pairing.\(UUID().uuidString)",
                                                                     content: content, trigger: nil))
    }
}

/// What an on-device pairing is doing: the steps while Madeira waits, the PIN,
/// and the outcome. Empty when no pairing has been started.
struct OnDevicePairingPanel: View {
    @ObservedObject private var pairing = OnDevicePairing.shared

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    var body: some View {
        switch pairing.phase {
        case .idle:
            EmptyView()
        case .waiting:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for your \(device)…").font(.headline)
                }
                Text("Open Settings › Privacy & Security › Developer Mode, scroll down and tap **Pair with \(OnDevicePairing.hostName)**. Keep Wi-Fi on.")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if pairing.backgroundLimited {
                    Text("This installation can only wait about 30 seconds in the background, so go to Settings straight away.")
                        .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                cancel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .pin(let pin):
            VStack(spacing: 8) {
                Text("Enter this code on your \(device)").font(.subheadline)
                Text(pin).font(.system(size: 40, weight: .bold, design: .monospaced)).tracking(6)
                    .textSelection(.enabled)
                    .accessibilityLabel("Pairing code \(pin.map(String.init).joined(separator: " "))")
                cancel
            }
            .frame(maxWidth: .infinity)
        case .paired(let name):
            Label("Paired with \(name)", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.subheadline).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cancel: some View {
        Button("Cancel pairing", role: .cancel) { pairing.cancel() }
            .font(.subheadline.weight(.semibold))
    }
}
