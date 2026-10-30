// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Wine Gecko, the HTML engine Wine's mshtml (Internet Explorer's web view) loads.
// Without it, the first program that shows a web page (an installer or a
// launcher) stops on Wine's "Wine Gecko Installer" window, whose download went
// through Wine's own networking and hung at 8% (urlmon "Not handling error 997").
//
// Madeira downloads the same files that window would, Wine's x86 and x86_64
// MSIs from WineHQ (32-bit programs use the first; 64-bit ones, ARM64EC here,
// where clang also defines __x86_64__, the second), with iOS networking, checks
// them against the SHA-256s in Wine's source (wine/dlls/appwiz.cpl/addons.c
// GECKO_SHA, held equal by tests/host/check-wine-gecko.py) and keeps them in
// Library/Application Support/WineGecko, out of backups. WineProcessBridge.m
// links them into each session's Wine download cache (<prefix>/.cache/wine,
// appwiz's install_from_cache), so Wine installs Gecko from there with no
// download window the first time a program asks.
//
// They come on their own, once, on Wi-Fi (not on cellular or in Low Data Mode),
// or from Settings › Web pages in programs at any time. Madeira does not
// redistribute Wine Gecko. Log tag: [wine-gecko].

import Foundation
import CryptoKit
import SwiftUI

/// What Wine's appwiz.cpl pins: one MSI for i386, one for x86_64 (ARM64EC).
struct WineGeckoPin {
    static let version = "2.47.4"
    static let all = [
        WineGeckoPin(arch: "x86", sha256: "26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6"),
        WineGeckoPin(arch: "x86_64", sha256: "e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f"),
    ]
    let arch: String
    let sha256: String
    var fileName: String { "wine-gecko-\(Self.version)-\(arch).msi" }
    var url: URL { URL(string: "https://dl.winehq.org/wine/wine-gecko/\(Self.version)/\(fileName)")! }
}

@MainActor final class WineGeckoModel: ObservableObject {
    static let shared = WineGeckoModel()

    @Published private(set) var progress: Double?          // the downloads' fraction, while they run
    @Published private(set) var installed = false
    @Published var error: String?
    private var observation: NSKeyValueObservation?
    private var automatic = false
    private var queue: [WineGeckoPin] = []
    private var count = 0

    /// Library/Application Support/WineGecko; WineProcessBridge.m looks for the MSIs in it.
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WineGecko", isDirectory: true)
    }
    static func file(_ pin: WineGeckoPin) -> URL { root.appendingPathComponent(pin.fileName) }
    static var missing: [WineGeckoPin] { WineGeckoPin.all.filter { !FileManager.default.fileExists(atPath: file($0).path) } }
    /// Both are here.
    static var available: Bool { missing.isEmpty }

    var busy: Bool { progress != nil }

    private init() { refresh() }

    func refresh() { installed = Self.available }

    var status: String {
        if let progress { return "Downloading… \(Int((progress * 100).rounded()))%" }
        return installed ? "Wine Gecko \(WineGeckoPin.version) is ready" : "Not downloaded"
    }

    private func log(_ line: String) { LogStore.shared.log("[wine-gecko] " + line) }

    /// On Wi-Fi only, quietly: called at app start. Without Wi-Fi the next start
    /// tries again; after any other failure, a day later.
    func installAutomatically() {
        guard !busy, !Self.available, !UserDefaults.standard.bool(forKey: "wine-gecko-removed") else { return }
        let key = "wine-gecko-auto-tried"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard now - last > 86_400 else { return }
        UserDefaults.standard.set(now, forKey: key)
        install(automatic: true)
    }

    func install(automatic: Bool = false) {
        guard !busy, !Self.available else { return }
        self.automatic = automatic
        error = nil
        if !automatic { UserDefaults.standard.removeObject(forKey: "wine-gecko-removed") }
        let root = Self.root
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var url = root; try url.setResourceValues(values)
        } catch {
            fail("Could not prepare the Wine Gecko folder: \(error.localizedDescription)"); return
        }
        queue = Self.missing
        count = queue.count
        progress = 0
        next()
    }

    /// Downloads the first file still queued, one after the other.
    private func next() {
        guard let pin = queue.first else {
            progress = nil
            refresh()
            log("ready \(WineGeckoPin.version)")
            return
        }
        log("download \(pin.url.absoluteString)\(automatic ? " (automatic, Wi-Fi only)" : "")")
        let configuration = URLSessionConfiguration.default
        if automatic {
            configuration.allowsExpensiveNetworkAccess = false     // not on cellular or a hotspot
            configuration.allowsConstrainedNetworkAccess = false   // not in Low Data Mode
        }
        let session = URLSession(configuration: configuration)
        let partial = Self.root.appendingPathComponent(pin.fileName + ".partial"), target = Self.file(pin)
        let task = session.downloadTask(with: pin.url) { temp, response, failure in
            // The temporary file is removed when this returns: check and move it first.
            var outcome: Error? = failure
            if failure == nil, let temp {
                do {
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw WineMonoInstallError.message("WineHQ answered \(http.statusCode).")
                    }
                    guard try WineMonoInstaller.sha256(of: temp) == pin.sha256 else {
                        throw WineMonoInstallError.message("The download does not match Wine Gecko \(WineGeckoPin.version) (\(pin.arch)).")
                    }
                    let fm = FileManager.default
                    try? fm.removeItem(at: partial)
                    try fm.moveItem(at: temp, to: partial)
                    try? fm.removeItem(at: target)
                    try fm.moveItem(at: partial, to: target)
                } catch { outcome = error }
            }
            let result = outcome
            Task { @MainActor in WineGeckoModel.shared.finished(error: result) }
        }
        session.finishTasksAndInvalidate()
        let done = Double(count - queue.count), total = Double(max(count, 1))
        observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let f = progress.fractionCompleted
            Task { @MainActor in
                let model = WineGeckoModel.shared
                if model.progress != nil { model.progress = (done + f) / total }
            }
        }
        task.resume()
    }

    private func finished(error failure: Error?) {
        observation = nil
        guard let failure else {
            queue.removeFirst()
            next()
            return
        }
        queue = []
        progress = nil
        refresh()
        let message = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        if automatic {
            // No Wi-Fi now: the next app start tries again; anything else waits a day.
            if let url = failure as? URLError, url.networkUnavailableReason != nil || url.code == .notConnectedToInternet {
                UserDefaults.standard.removeObject(forKey: "wine-gecko-auto-tried")
            }
            log("automatic download not done: \(message)")
        } else {
            fail("The download failed: \(message)")
        }
    }

    private func fail(_ message: String) {
        progress = nil
        error = message
        log("failed: \(message)")
    }

    /// Settings › Remove. Prefixes that already installed Gecko keep it; new ones
    /// show Wine's download window again. Not downloaded again on its own after this.
    func remove() {
        guard !busy else { return }
        for pin in WineGeckoPin.all { try? FileManager.default.removeItem(at: Self.file(pin)) }
        UserDefaults.standard.set(true, forKey: "wine-gecko-removed")
        refresh()
        log("removed")
    }
}

// MARK: - Settings › Web pages in programs

struct WineGeckoSettingsSection: View {
    @ObservedObject private var gecko = WineGeckoModel.shared
    @State private var confirmRemove = false

    var body: some View {
        Section {
            LabeledContent("Wine Gecko", value: gecko.status)
            if let progress = gecko.progress { ProgressView(value: progress) }
            if let error = gecko.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !gecko.busy {
                if gecko.installed {
                    Button("Remove Wine Gecko", role: .destructive) { confirmRemove = true }
                } else {
                    Button { gecko.install() } label: {
                        Label(gecko.error == nil ? "Download Wine Gecko" : "Try again", systemImage: "arrow.down.circle")
                    }
                }
            }
        } header: {
            Text("Web pages in programs")
        } footer: {
            Text("Installers and launchers that show web pages use Wine Gecko, the Wine project's open-source HTML engine. Madeira gets it from WineHQ by itself on Wi-Fi, so Wine never stops to download it.")
        }
        .confirmationDialog("Remove Wine Gecko?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { gecko.remove() }
        } message: {
            Text("Programs that have used it keep it. Others ask Wine to download it again.")
        }
        .onAppear { gecko.refresh() }
    }
}
