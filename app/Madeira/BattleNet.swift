//
//  BattleNet.swift
//  Madeira
//
//  [battle-net] Blizzard's Battle.net app in the library (Nov 2026).
//
//  - Add a Program › Battle.net, at the top of the list: before Battle.net is
//    installed it downloads Blizzard's official installer into drive_c and adds
//    it; once Battle.net is installed it adds Battle.net itself. Both get their
//    recommended settings (GameRecommendations.battleNet / battleNetSetup): the
//    Wine desktop with Windows services first.
//  - Game details › Launch arguments on Battle.net: one button per Blizzard game.
//    It adds --exec="launch <code>", so Play opens Battle.net and starts that game.
//
//  Off with env.MADEIRA_BATTLE_NET = 0 (no row in Add a Program, no game buttons;
//  the recommended settings stay).
//

import SwiftUI

enum BattleNet {
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_BATTLE_NET", fallback: true) }

    /// Blizzard's own download link for the Windows installer (the one battle.net's
    /// download page uses for the Battle.net app).
    static let installerURL = URL(string: "https://www.battle.net/download/getInstallerForGame?os=win&version=LIVE&gameProgram=BATTLENET_APP")!

    /// Where the installer is saved, inside drive_c.
    static let installerRelative = "users/Public/Downloads/Battle.net-Setup.exe"
    /// Where the installer puts Battle.net by default.
    static let launcherRelatives = ["Program Files (x86)/Battle.net/Battle.net Launcher.exe",
                                    "Program Files (x86)/Battle.net/Battle.net.exe"]

    /// The programs that are Battle.net itself (the lowercased file name).
    static let launcherNames: Set<String> = ["battle.net launcher.exe", "battle.net.exe"]

    static func isBattleNet(_ entry: LibraryEntry) -> Bool {
        let name = entry.relativePath.split(separator: "/").last.map { $0.lowercased() } ?? ""
        return launcherNames.contains(name)
    }

    /// Battle.net's program in drive_c, when it is installed.
    static var installedLauncher: URL? {
        let drive = LibraryModel.drive
        return launcherRelatives.map { drive.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The games Battle.net starts with --exec="launch <code>" (Blizzard's own codes).
    struct Game: Hashable {
        let title: String
        let code: String
    }
    static let games: [Game] = [
        Game(title: "StarCraft", code: "S1"), Game(title: "StarCraft II", code: "S2"),
        Game(title: "Warcraft III", code: "W3"), Game(title: "World of Warcraft", code: "WoW"),
        Game(title: "Diablo III", code: "D3"), Game(title: "Hearthstone", code: "WTCG"),
        Game(title: "Heroes of the Storm", code: "Hero"), Game(title: "Overwatch", code: "Pro"),
    ]
    static func argument(_ code: String) -> String { "--exec=\"launch \(code)\"" }

    /// The arguments with `code`'s game chosen (or taken off when it already was);
    /// one game at a time, every other argument kept.
    static func toggled(_ text: String, code: String) -> String {
        let flag = argument(code)
        let had = LaunchFlagChips.contains(text, flag)
        var parts = LaunchFlagChips.tokens(text).filter { !$0.lowercased().hasPrefix("--exec=\"launch ") }
        if !had { parts.append(flag) }
        return parts.joined(separator: " ")
    }

    /// Downloads the installer into drive_c (again, when a copy is already there).
    static func downloadInstaller() async throws -> URL {
        let destination = LibraryModel.drive.appendingPathComponent(installerRelative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        LogStore.shared.log("[battle-net] download start")
        let (temporary, response) = try await URLSession.shared.download(from: installerURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let size = ((try? FileManager.default.attributesOfItem(atPath: temporary.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard (200..<300).contains(status), size > 0 else {
            try? FileManager.default.removeItem(at: temporary)
            LogStore.shared.log("[battle-net] download failed status=\(status) bytes=\(size)", level: .error)
            throw LibraryError.message(L("Battle.net's installer could not be downloaded. Check the internet connection and try again."))
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        LogStore.shared.log("[battle-net] download done bytes=\(size)")
        return destination
    }
}

/// Add a Program: the Battle.net row, at the top of drive_c's list.
struct BattleNetAddRow: View {
    var select: (LibraryEntry) -> Void
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let installed = BattleNet.installedLauncher != nil
        Section {
            Button {
                Task { await add() }
            } label: {
                HStack {
                    Label(installed ? L("Add Battle.net") : L("Get Battle.net"), systemImage: "arrow.down.app")
                    Spacer()
                    if working { ProgressView() }
                }
            }.disabled(working)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } footer: {
            Text(installed ? L("Battle.net is installed. Add it to start Blizzard games.")
                           : L("Downloads Blizzard's installer. Play it and sign in, then come back here and tap Add Battle.net."))
        }
    }

    private func add() async {
        working = true; error = nil
        defer { working = false }
        do {
            let launcher = BattleNet.installedLauncher
            let program: URL
            if let launcher { program = launcher } else { program = try await BattleNet.downloadInstaller() }
            var entry = try LibraryModel.inspect(program)
            entry.title = launcher != nil ? "Battle.net" : L("Battle.net installer")
            LogStore.shared.log("[battle-net] added \(launcher != nil ? "launcher" : "installer")")
            select(entry)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Game details › Launch arguments on Battle.net: one button per Blizzard game.
struct BattleNetGameChips: View {
    @Binding var arguments: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start a game with Battle.net").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BattleNet.games, id: \.code) { game in
                        let on = LaunchFlagChips.contains(arguments, BattleNet.argument(game.code))
                        Button(game.title) { arguments = BattleNet.toggled(arguments, code: game.code) }
                            .buttonStyle(.bordered).tint(on ? Color.accentColor : Color.gray)
                            .font(.caption)
                            .accessibilityValue(on ? L("On") : L("Off"))
                    }
                }
            }
        }
    }
}
