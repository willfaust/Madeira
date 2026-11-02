// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Combine
import Foundation

// GOG Galaxy's game services for a GOG game's play (docs/GOG.md, "Galaxy"): a game
// built with GOG's Galaxy SDK talks to GOG's client on 127.0.0.1:9977 for its
// sign-in, achievements, stats, leaderboards and play time. While a GOG game runs,
// Madeira answers there itself (GalaxyListener and GalaxyService, ported from
// Playport), with a token GOG mints for that game from Madeira's GOG sign-in. Some
// SDK versions first ask Windows to start the "GalaxyCommunication" service, so the
// prefix gets a do-nothing service of that name (build/gog-galaxy-service).
// Without a sign-in, or when the port is taken, the game simply runs offline, as a
// GOG game does without GOG's client. `env.MADEIRA_GOG_GALAXY = 0` turns it off,
// in madeira.cfg or in one game's own config.
// Log tag: [galaxy] (request names and statuses only; never a token or secret).

@MainActor final class GOGGalaxy {
    static let shared = GOGGalaxy()

    static var enabled: Bool { SteamSignIn.flag("MADEIRA_GOG_GALAXY", default: true) }   // GOG Galaxy's game services (sign-in, achievements, stats, leaderboards) for GOG games, answered by Madeira on 127.0.0.1:9977 while one runs (docs/GOG.md, "Galaxy"); 0 turns them off, in madeira.cfg or in one game's own config

    /// Whether this game's play gets the service: its own config (Game details ›
    /// This game's config) wins over madeira.cfg. A game's lines are applied only
    /// after this runs, so they are read here; spaces inside the key are ignored
    /// ("env. MADEIRA_GOG_GALAXY = 0" counts).
    static func enabled(for entry: LibraryEntry) -> Bool {
        let key = "env.MADEIRA_GOG_GALAXY"
        let own = MadeiraConfig.parse(entry.gameConfigText ?? "")
        if let value = own.first(where: { $0.key.filter { !$0.isWhitespace } == key })?.value {
            return value != "0"
        }
        return enabled
    }

    /// Where GOG's own client and Heroic's comet put the service's program.
    static let serviceWindowsPath = "C:\\ProgramData\\GOG.com\\Galaxy\\redists\\GalaxyCommunication.exe"
    /// Wine keeps CurrentControlSet as a link to ControlSet001 in system.reg.
    static let serviceKey = "System\\ControlSet001\\Services\\GalaxyCommunication"

    private var listener: GalaxyListener?
    private var entryID: UUID?
    private var watching: AnyCancellable?

    private init() {}

    /// Called right before a library game starts, while no session runs. Starts the
    /// service for a GOG game whose build has a Galaxy client; stops any earlier one.
    func prepare(_ entry: LibraryEntry) {
        stop()
        guard let product = entry.gogProductID else { return }
        guard Self.enabled(for: entry) else {
            GOGLog.event("[galaxy] off for this play (env.MADEIRA_GOG_GALAXY=0)")
            return
        }
        guard GOGLibrary.shared.signedIn,
              let client = GOGLibrary.shared.installed[product]?.galaxy else { return }
        registerService()
        let log = GalaxyLogger { line in GOGLog.event(line) }
        let listener = GalaxyListener(service: GalaxyService(client: client, tokens: GOGAPI.shared, log: log), log: log)
        do {
            try listener.start()
        } catch {
            GOGLog.event("[galaxy] not started for id=\(product): \(error); the game runs offline")
            return
        }
        self.listener = listener
        entryID = entry.id
        watching = LibraryModel.shared.$current.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] current in
            MainActor.assumeIsolated {
                guard let self, current != self.entryID else { return }
                self.stop()
            }
        }
    }

    func stop() {
        watching = nil
        listener?.stop()
        listener = nil
        entryID = nil
    }

    /// The GalaxyCommunication service in the prefix: its program and registry key.
    /// Only while no session runs (the wineserver holds the registry then).
    private func registerService() {
        guard wineserver_is_running() == 0, wine_process_is_running() == 0 else { return }
        let drive = LibraryModel.drive
        guard let target = GOGSetup.hostURL(Self.serviceWindowsPath, drive: drive),
              let bundled = Bundle.main.url(forResource: "madeira-galaxy-service", withExtension: "exe", subdirectory: "aarch64-windows")
        else { return }
        let fm = FileManager.default
        do {
            let data = try Data(contentsOf: bundled)
            if (try? Data(contentsOf: target)) != data {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            let values: [SteamInstallValue] = [
                .init(hive: .machine, key: Self.serviceKey, name: "DisplayName", data: .string("GalaxyCommunication"), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "ImagePath", data: .string("\"" + Self.serviceWindowsPath + "\""), followsInstall: true),
                .init(hive: .machine, key: Self.serviceKey, name: "ObjectName", data: .string("LocalSystem"), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "Type", data: .dword(0x10), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "Start", data: .dword(3), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "ErrorControl", data: .dword(1), followsInstall: false),
            ]
            let prefix = drive.deletingLastPathComponent()
            let changed = try SteamInstallRegistry.write(values, prefix: prefix)
            if changed > 0 { GOGLog.event("[galaxy] GalaxyCommunication service registered values=\(changed)") }
        } catch {
            GOGLog.event("[galaxy] GalaxyCommunication service not registered: \(error.localizedDescription)")
        }
    }
}
