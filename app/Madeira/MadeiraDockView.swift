// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

/// State of the Madeira Dock sheet: sign-in, Valve's client components, the
/// installed games and the last Dock result.
@MainActor
final class MadeiraDockModel: ObservableObject {
    static let shared = MadeiraDockModel()

    @Published private(set) var games: [DockGame] = []
    @Published private(set) var clientInstalled = false
    @Published private(set) var preparing = false
    @Published private(set) var progress = ""
    @Published var error: String?
    /// The last Dock launch's outcome, from the host report.
    @Published var status: String?
    /// Opt-in per launch: a 512 MB JIT pool instead of the standard one.
    @Published var compactPool = SteamSignIn.flag("MADEIRA_DOCK_COMPACT_POOL", default: false)
    /// App ID -> number of one-time install programs in the game's Steam install scripts.
    @Published private(set) var installPrograms: [Int: Int] = [:]
    /// App ID -> the game's One-time installs choice (true: Run at next start).
    @Published private(set) var installRunNext: [Int: Bool] = [:]
    /// App ID -> the Record as done / Reset request its next Dock start applies.
    @Published private(set) var installRequest: [Int: DockInstallRequest] = [:]

    private var watch: Task<Void, Never>?

    func refresh() {
        clientInstalled = MadeiraDock.clientInstalled
        let drive = MadeiraDock.drive, prefix = MadeiraDock.prefix
        Task.detached(priority: .userInitiated) {
            let found = MadeiraDock.games(drive: drive)
            var programs: [Int: Int] = [:], runNext: [Int: Bool] = [:], requests: [Int: DockInstallRequest] = [:]
            if DockInstallers.choiceEnabled {
                let ledger = DockInstallLedger.load(prefix: prefix)
                for game in found where game.installed {
                    let count = DockInstallers.programCount(game, drive: drive)
                    if count > 0 { programs[game.id] = count; runNext[game.id] = ledger.runsNext(game.id) }
                    if count > 0, let request = ledger.request(game.id) { requests[game.id] = request }
                }
            }
            let counts = programs, choices = runNext, pendingRequests = requests
            await MainActor.run {
                self.games = found; self.installPrograms = counts; self.installRunNext = choices
                self.installRequest = pendingRequests
            }
        }
    }

    /// The game's One-time installs choice, saved next to the prefix's registry files.
    func setRunsInstallers(_ appID: Int, _ run: Bool) {
        DockInstallers.setRunsNext(appID, run, prefix: MadeiraDock.prefix)
        installRunNext[appID] = run
    }

    /// Saves (nil: cancels) the game's Record as done / Reset request; its next Dock start
    /// applies it while no session runs.
    func setInstallRequest(_ appID: Int, _ request: DockInstallRequest?) {
        DockInstallers.setRequest(appID, request, prefix: MadeiraDock.prefix)
        installRequest[appID] = request
    }

    /// Downloads and unpacks Valve's client components (no Wine session).
    func prepareClient() {
        guard !preparing else { return }
        preparing = true; error = nil; progress = "Starting…"
        Task { @MainActor in
            do {
                try await SteamRuntimeInstaller.shared.prepare(prefix: MadeiraDock.prefix) { text in
                    await MainActor.run { self.progress = text }
                }
                SteamLog.event("[dock-setup] client components ready")
            } catch {
                self.error = error.localizedDescription
                SteamLog.event("[dock-setup] client components failed: \(error.localizedDescription)"
                               + (SteamRuntimeFiles.lastConflict.map { " (at \($0))" } ?? ""))
            }
            preparing = false
            refresh()
        }
    }

    /// Follows the host's report until it records a result, or the session ends
    /// without one, then removes any unconsumed sign-in transfer.
    func watchReport() {
        watch?.cancel()
        let starting = DockInstallers.installsOnly ? "Running this game's one-time installs…"
                                                   : "Madeira Dock is starting. Valve's client signs in and checks the license."
        let plan = DockInstallers.note
        status = plan.map { $0 + "\n" + starting } ?? starting
        if let plan { LogStore.shared.log("[dock-installers] " + plan) }
        watch = Task { @MainActor in
            var idle = 0, started = false, offered = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let report = MadeiraDock.pollReport()
                DockOffline.observe(report.fields)
                // The game's one-time installs run before the host writes its first field.
                if DockInstallers.script != nil {
                    let progress = DockInstallers.poll(drive: MadeiraDock.drive)
                    if report.fields["probe-start-bits"] == nil, report.result == nil, let progress { status = progress }
                }
                if report.result != nil {
                    if let failure = report.failure {
                        status = failure
                        LogStore.shared.log("[madeira-dock] " + failure, level: .error)
                    } else {
                        status = "Madeira Dock finished normally."
                        LogStore.shared.log("[madeira-dock] host finished (result 0)")
                    }
                    break
                }
                // Steam still counts another session of this account as playing
                // (launch refusal 35); the host asks again for up to three minutes.
                if report.fields["launch-session-wait"] != nil, report.fields["launch-client-error"] == "35" {
                    status = "Steam says this account is still playing in another session. Waiting for Steam to end it (up to 3 minutes)…"
                }
                // The session starts after the JIT pool is set up; count only once it ran.
                let running = wine_process_is_running() != 0 || wineserver_is_running() != 0
                if running { started = true; idle = 0 } else { idle += 1 }
                if !started && idle >= 150 {
                    status = "The Dock session did not start. See the log."
                    break
                }
                // madeira-bcd: a program an installer started (a launcher, a helper) can keep a
                // session of one-time installs open after its batch ended. The wineserver writes
                // the registry to disk every 30 s, so 45 s after the batch a restart loses nothing.
                if DockInstallers.installsOnly, running, !offered, let finished = DockInstallers.finishedAt,
                   Date().timeIntervalSince(finished) >= 45 {
                    offered = true
                    let ended = DockInstallers.poll(drive: MadeiraDock.drive) ?? "One-time installs finished."
                    status = ended + "\n" + DockInstallers.restartWords
                    LogStore.shared.log("[dock-installers] the session still runs 45 s after the installs ended (a program they started); the restart is offered now")
                    LibraryModel.shared.restartNotice = DockInstallers.restartNotice(ended)
                    LibraryModel.shared.installsRestartReady = true
                }
                if started && idle >= 5 {
                    if DockInstallers.installsOnly {
                        // madeira-bcd: a session of one-time installs ends after its batch, and the
                        // game starts in the next app run (DockInstallers.installsOnly). The
                        // wineserver has stopped by now, so the registry is on disk.
                        let ended = DockInstallers.poll(drive: MadeiraDock.drive) ?? "One-time installs ended."
                        status = ended + "\n" + DockInstallers.restartWords
                        LogStore.shared.log("[dock-installers] the installs-only session ended; the game starts after Madeira is restarted")
                        LibraryModel.shared.restartNotice = DockInstallers.restartNotice(DockInstallers.poll(drive: MadeiraDock.drive))
                        LibraryModel.shared.installsRestartReady = true
                    } else {
                        status = "Madeira Dock stopped before reporting a result. Export the log."
                        LogStore.shared.log("[madeira-dock] session ended without a host result", level: .error)
                    }
                    break
                }
            }
            MadeiraDock.cleanup()
            // The host is done with the sign-in: the app's own Steam connection may come
            // back once no session runs (SteamOwnedLibrary).
            SteamOwnedLibrary.shared.dockEnded()
        }
    }
}

/// Madeira Dock sheet, opened from the developer interface.
struct MadeiraDockView: View {
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var signIn = SteamSignInModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showSignIn = false
    let start: (DockGame, Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Madeira Dock starts an installed Steam game through Valve's own Steam client, without the Steam desktop window. Valve's client signs in with your account and decides whether the game may run.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Steam account") {
                    if let name = signIn.accountName {
                        LabeledContent("Signed in", value: name)
                    } else {
                        Button("Sign in to Steam") { showSignIn = true }
                    }
                }
                Section {
                    if dock.clientInstalled {
                        Label("Valve's client components are installed", systemImage: "checkmark.circle")
                    } else if dock.preparing {
                        HStack(spacing: 12) { ProgressView(); Text(dock.progress).foregroundStyle(.secondary) }
                    } else {
                        Button("Download Valve's client components (about 73 MB)") { dock.prepareClient() }
                    }
                } header: { Text("Steam client") } footer: {
                    Text("Downloaded from Valve's update servers and checked against pinned SHA-256 sums. Existing Steam files are kept.")
                }
                Section {
                    if dock.games.isEmpty {
                        Text("No installed Steam games were found in the Steam library in drive_c.").foregroundStyle(.secondary)
                    }
                    ForEach(dock.games) { game in
                        Button { start(game, dock.compactPool); dismiss() } label: {
                            HStack {
                                Text(game.name)
                                Spacer()
                                if !game.installed { Text("Not fully installed").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(!game.installed || !dock.clientInstalled || !signIn.signedIn)
                    }
                    Toggle("Smaller JIT pool (512 MB) for this launch", isOn: $dock.compactPool)
                } header: { Text("Installed games") } footer: {
                    Text("Games Steam's client has installed in this prefix. Only Steam's default launch option is used.")
                }
                if !dock.installPrograms.isEmpty {
                    Section {
                        ForEach(dock.games.filter { dock.installPrograms[$0.id] != nil }) { game in
                            Picker(game.name, selection: Binding(get: { dock.installRunNext[game.id] ?? true },
                                                                 set: { dock.setRunsInstallers(game.id, $0) })) {
                                Text("Run at next start").tag(true)
                                Text("Skip").tag(false)
                            }
                            .pickerStyle(.menu)
                            DockInstallRequestRows(dock: dock, appID: game.id, name: game.name)
                        }
                    } header: { Text("One-time installs") } footer: {
                        Text("Programs from a game's Steam install script, such as runtime setups, that Steam's desktop client runs before a first start. A Dock start runs the ones not yet recorded as done before Valve's client starts; the choice then changes to Skip. Record as done and Reset take effect at the game's next Dock start.")
                    }
                }
                if let status = dock.status {
                    Section("Dock status") { Text(status) }
                }
                if let error = dock.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Madeira Dock").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { dock.refresh(); signIn.refresh() }
            .sheet(isPresented: $showSignIn) { SteamSignInView() }
        }
    }
}

/// A game's One-time installs requests, under its Run at next start / Skip choice: Record as
/// done (an installer that did its work but never closed, so it was never recorded) and
/// Reset (remove what they installed and forget the records, so the installers run again;
/// madeira-bcd: DockReset.swift). Each is saved now and applied at
/// the game's next Dock start, while no session runs (DockInstallers.applyRequest); until
/// then it can be cancelled.
struct DockInstallRequestRows: View {
    @ObservedObject var dock: MadeiraDockModel
    let appID: Int
    let name: String
    @State private var confirmRecord = false
    @State private var confirmReset = false

    var body: some View {
        Group {
            if let request = dock.installRequest[appID] {
                HStack {
                    Text(request == .record ? "Next start: one-time installs recorded as done."
                         : request == .resetSignOut ? "Next start: one-time installs and Rockstar sign-in removed, then installed again."
                         : "Next start: one-time installs removed, then installed again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dock.setInstallRequest(appID, nil) }.font(.caption)
                }
            } else {
                Button("Record as done…") { confirmRecord = true }
                Button("Reset one-time installs…", role: .destructive) { confirmReset = true }
            }
        }
        .confirmationDialog("Record \(name)'s one-time installs as done?", isPresented: $confirmRecord, titleVisibility: .visible) {
            Button("Record as done") { dock.setInstallRequest(appID, .record) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("For an installer that finished its work but never closed, so Madeira never saw it end. At the next start the game's own install-script programs are recorded as done, as a finished run would be, and are not run again. Nothing is installed or removed.")
        }
        // madeira-bcd: a reset removes what the installers put in (DockReset.swift), into a backup.
        .confirmationDialog("Reset \(name)'s one-time installs?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset at next start", role: .destructive) { dock.setInstallRequest(appID, .reset) }
            Button("Reset and sign out of Rockstar", role: .destructive) { dock.setInstallRequest(appID, .resetSignOut) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("At the next start Madeira removes what the one-time installs put into Wine: the Rockstar Games Launcher, Social Club, the Visual C++ 2015-2022 runtimes (x86 and x64) and the Vulkan runtime. That start then runs only the installers again, as on a new device; after it, restart Madeira and start the game. Games sharing these installs (GTA V, Red Dead Redemption 2) install them again at their next start too. The game files and saves stay. Everything removed is kept in the madeira-reset-backup folder in Madeira's Documents. Sign out also removes the Rockstar sign-in.")
        }
    }
}
