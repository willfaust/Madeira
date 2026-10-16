// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Epic Cloud saves in the app: when the sync runs, what it shows on a game's page, and the
// switches. The protocol and the decision are in EpicCloudSaves.swift (tests/host/check-epic-cloud.py
// checks them against Legendary). docs/EPIC.md, "Cloud saves".

import SwiftUI

/// Settings › Epic Games: whether saves sync, and whether this device's newer saves are sent
/// without being asked. `env.MADEIRA_EPIC_CLOUD = 0` turns the sync off; downloads and the
/// comparison are on by default, uploading is not (`env.MADEIRA_EPIC_CLOUD_AUTO_UPLOAD = 1`).
@MainActor final class EpicCloudSetting: ObservableObject {
    static let shared = EpicCloudSetting()
    @Published var on = MadeiraConfig.flag("MADEIRA_EPIC_CLOUD", fallback: true) {
        didSet {
            guard on != oldValue else { return }
            MadeiraConfig.set("env.MADEIRA_EPIC_CLOUD", on ? nil : "0")
            LogStore.shared.log("[epic-cloud] setting on=\(on ? 1 : 0)")
            if on { EpicCloud.shared.startupCheck() }
        }
    }
    @Published var autoUpload = MadeiraConfig.flag("MADEIRA_EPIC_CLOUD_AUTO_UPLOAD", fallback: false) {
        didSet {
            guard autoUpload != oldValue else { return }
            MadeiraConfig.set("env.MADEIRA_EPIC_CLOUD_AUTO_UPLOAD", autoUpload ? "1" : nil)
            LogStore.shared.log("[epic-cloud] setting auto-upload=\(autoUpload ? 1 : 0)")
        }
    }
}

@MainActor final class EpicCloud: ObservableObject {
    static let shared = EpicCloud()

    enum Phase: Equatable {
        case idle, checking, downloading, uploading, ready
        case unsupported            // the game has no cloud saves
        case failed(String)
    }
    struct State {
        var phase = Phase.idle
        var verdict: EpicSaveVerdict?
        var deviceFiles = 0, cloudFiles = 0
        var deviceDate: Date?, cloudDate: Date?
        var deviceBytes: UInt64 = 0, cloudBytes: UInt64 = 0
        var note: String?
    }
    @Published private(set) var states: [String: State] = [:]
    private var busy = Set<String>()

    // What is remembered between runs: the game's save folder rule and the last state both sides agreed on.
    private struct Record: Codable {
        var config: EpicSaveConfig?
        var noCloud = false
        var baseline: EpicSaveBaseline?
    }
    private var records: [String: Record] = {
        guard let data = try? Data(contentsOf: EpicCloud.storeURL),
              let value = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return value
    }()
    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("epic-cloud-sync.json")
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    static var enabled: Bool { EpicCloudSetting.shared.on }
    func state(_ app: String) -> State { states[app] ?? State() }
    private func update(_ app: String, _ change: (inout State) -> Void) {
        var s = states[app] ?? State()
        change(&s)
        states[app] = s
    }
    private func log(_ text: String) { LogStore.shared.log("[epic-cloud] " + text) }

    /// Copies of the saves a download replaced, where the Files app shows them
    /// (Madeira › Epic Cloud Backups): `<game> (<app>)/<time>/...`.
    static var backupsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Epic Cloud Backups", isDirectory: true)
    }
    private static func backup(for record: EpicInstalledGame) -> URL {
        let safe = String(record.game.title.map { "/\\:*?\"<>|".contains($0) ? "-" : $0 }.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return backupsFolder.appendingPathComponent(safe.isEmpty ? record.appName : "\(safe) (\(record.appName))", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
    }

    // MARK: what a run needs

    private struct Context {
        var record: EpicInstalledGame
        var config: EpicSaveConfig
        var folder: URL
        var account: String
        var transport: EpicCloudHTTP
    }
    private struct Looked {
        var context: Context
        var device: [EpicDeviceSave]
        var latest: (snapshot: EpicCloudSnapshot, all: [EpicCloudObject])?
        var verdict: EpicSaveVerdict
    }

    /// The game's catalog entry says where its saves are (customAttributes.CloudSaveFolder).
    private func fetchConfig(_ game: EpicGame, token: String) async throws -> EpicSaveConfig? {
        guard let id = game.catalogItemId, !game.namespace.isEmpty else { return nil }
        var components = URLComponents(string: "https://catalog-public-service-prod06.ol.epicgames.com/catalog/api/shared/namespace/\(game.namespace)/bulk/items")!
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "includeDLCDetails", value: "true"),
                                 URLQueryItem(name: "includeMainGameDetails", value: "true"),
                                 URLQueryItem(name: "country", value: "US"), URLQueryItem(name: "locale", value: "en-US")]
        var request = URLRequest(url: components.url!)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(EpicCloudHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EpicContentError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0) }
        let items = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return EpicSaveConfig.from(customAttributes: (items?[id] as? [String: Any])?["customAttributes"] as? [String: Any])
    }

    private func context(_ app: String) async throws -> Context? {
        guard let record = EpicInstaller.shared.installed[app] else { return nil }
        let token = try await EpicAuth.shared.validAccessToken()
        guard let account = EpicAuth.shared.accountID else { throw EpicAuthError.notSignedIn }
        var stored = records[app] ?? Record()
        if stored.config == nil && !stored.noCloud {
            if let config = try await fetchConfig(record.game, token: token) { stored.config = config } else { stored.noCloud = true }
            records[app] = stored
            persist()
        }
        guard let config = stored.config else { return nil }
        let drive = LibraryModel.drive
        guard let user = SteamCloudPaths.userFolder(drive: drive)?.url else {
            throw EpicContentError.invalid("The Wine prefix has no user folder yet. Start a game once, then sync.")
        }
        let paths = EpicSavePaths(drive: drive, userFolder: user,
                                  installFolder: drive.appendingPathComponent(record.installDir, isDirectory: true), accountID: account)
        guard let folder = paths.resolve(config.folder) else {
            throw EpicContentError.invalid("This game keeps its saves in a place Madeira does not know yet.")
        }
        return Context(record: record, config: config, folder: folder, account: account,
                       transport: EpicCloudHTTP(token: token, accountID: account))
    }

    nonisolated private static func scan(_ folder: URL, _ config: EpicSaveConfig) async throws -> [EpicDeviceSave] {
        try await Task.detached(priority: .utility) { try EpicSaveScan.scan(folder, config: config) }.value
    }

    private func look(_ app: String) async throws -> Looked? {
        guard let context = try await context(app) else { return nil }
        let device = try await Self.scan(context.folder, context.config)
        let latest = try await EpicCloudSaves.latest(app: app, transport: context.transport)
        let deviceMap = Dictionary(device.map { ($0.path, $0.sha) }, uniquingKeysWith: { a, _ in a })
        let verdict = EpicSavePlanner.decide(device: deviceMap, cloud: latest?.snapshot.files, baseline: records[app]?.baseline)
        return Looked(context: context, device: device, latest: latest, verdict: verdict)
    }

    private func show(_ app: String, _ looked: Looked) {
        update(app) { s in
            s.phase = .ready
            s.verdict = looked.verdict
            s.deviceFiles = looked.device.count
            s.deviceBytes = looked.device.reduce(0) { $0 + $1.size }
            s.deviceDate = looked.device.map(\.modified).max()
            s.cloudFiles = looked.latest?.snapshot.files.count ?? 0
            s.cloudBytes = looked.latest?.snapshot.sizes.values.reduce(0, +) ?? 0
            s.cloudDate = looked.latest?.snapshot.date
        }
    }

    // MARK: actions

    /// Compares the device with the cloud. `automatic` (opening the page, starting Madeira) also
    /// downloads a newer cloud save and, only if the setting asks for it, uploads a newer device save.
    func check(_ app: String, automatic: Bool = true) async {
        guard Self.enabled, EpicAuth.shared.signedIn, !busy.contains(app) else { return }
        busy.insert(app); defer { busy.remove(app) }
        update(app) { $0.phase = .checking; $0.note = nil }
        do {
            guard let looked = try await look(app) else {
                update(app) { $0.phase = .unsupported }
                return
            }
            show(app, looked)
            log("app=\(app) check verdict=\(looked.verdict) device=\(looked.device.count) cloud=\(looked.latest?.snapshot.files.count ?? 0)")
            if looked.verdict == .inSync || looked.verdict == .empty { remember(app, looked) }
            guard automatic else { return }
            switch looked.verdict {
            case .download: await download(app, looked)
            case .upload where EpicCloudSetting.shared.autoUpload: await upload(app, looked)
            default: break
            }
        } catch {
            fail(app, error)
        }
    }

    /// The Sync now button: does what the comparison says. A conflict waits for the user's choice.
    func syncNow(_ app: String) async {
        guard Self.enabled, EpicAuth.shared.signedIn, !busy.contains(app) else { return }
        busy.insert(app); defer { busy.remove(app) }
        update(app) { $0.phase = .checking; $0.note = nil }
        do {
            guard let looked = try await look(app) else { update(app) { $0.phase = .unsupported }; return }
            show(app, looked)
            switch looked.verdict {
            case .download: await download(app, looked)
            case .upload: await upload(app, looked)
            case .inSync, .empty: remember(app, looked); update(app) { $0.note = looked.verdict == .empty ? "No saves yet." : "Already in sync." }
            case .conflict: update(app) { $0.note = "The saves differ. Choose which to keep." }
            }
        } catch {
            fail(app, error)
        }
    }

    /// The user's choice for a conflict: Epic's saves come down, or this device's go up as a new snapshot.
    func resolve(_ app: String, useCloud: Bool) async {
        guard Self.enabled, EpicAuth.shared.signedIn, !busy.contains(app) else { return }
        busy.insert(app); defer { busy.remove(app) }
        update(app) { $0.phase = .checking; $0.note = nil }
        do {
            guard let looked = try await look(app) else { update(app) { $0.phase = .unsupported }; return }
            show(app, looked)
            if useCloud {
                guard looked.latest != nil else { update(app) { $0.note = "Epic has no saves for this game." }; return }
                await download(app, looked)
            } else {
                await upload(app, looked)
            }
        } catch {
            fail(app, error)
        }
    }

    func startupCheck() {
        guard Self.enabled, EpicAuth.shared.signedIn else { return }
        Task {
            for app in EpicInstaller.shared.installed.keys.sorted() {
                await check(app, automatic: true)
            }
        }
    }

    private func remember(_ app: String, _ looked: Looked) {
        var record = records[app] ?? Record()
        record.baseline = EpicSaveBaseline(device: Dictionary(looked.device.map { ($0.path, $0.sha) }, uniquingKeysWith: { a, _ in a }),
                                           cloud: looked.latest?.snapshot.files ?? [:], snapshot: looked.latest?.snapshot.buildVersion)
        records[app] = record
        persist()
    }

    private func download(_ app: String, _ looked: Looked) async {
        guard let latest = looked.latest else { return }
        update(app) { $0.phase = .downloading }
        do {
            let result = try await EpicCloudSaves.download(latest.snapshot, all: latest.all, into: looked.context.folder,
                                                           backup: Self.backup(for: looked.context.record), transport: looked.context.transport)
            let after = try await Self.scan(looked.context.folder, looked.context.config)
            var record = records[app] ?? Record()
            record.baseline = EpicSaveBaseline(device: Dictionary(after.map { ($0.path, $0.sha) }, uniquingKeysWith: { a, _ in a }),
                                               cloud: latest.snapshot.files, snapshot: latest.snapshot.buildVersion)
            records[app] = record
            persist()
            log("app=\(app) downloaded files=\(result.files) backed-up=\(result.backedUp)")
            var next = looked
            next.device = after
            next.verdict = .inSync
            show(app, next)
            update(app) { $0.note = "Downloaded \(result.files) save file\(result.files == 1 ? "" : "s")."
                + (result.backedUp > 0 ? " \(result.backedUp) replaced on this device \(result.backedUp == 1 ? "was" : "were") backed up." : "") }
        } catch {
            fail(app, error)
        }
    }

    private func upload(_ app: String, _ looked: Looked) async {
        update(app) { $0.phase = .uploading }
        do {
            let result = try await EpicCloudSaves.upload(looked.device, app: app, accountID: looked.context.account,
                                                         config: looked.context.config, transport: looked.context.transport)
            let map = Dictionary(looked.device.map { ($0.path, $0.sha) }, uniquingKeysWith: { a, _ in a })
            var record = records[app] ?? Record()
            record.baseline = EpicSaveBaseline(device: map, cloud: map, snapshot: result.version)
            records[app] = record
            persist()
            log("app=\(app) uploaded files=\(result.files) snapshot=\(result.version)")
            var next = looked
            next.verdict = .inSync
            show(app, next)
            update(app) { $0.cloudFiles = result.files; $0.cloudDate = EpicCloudSaves.date(ofBuildVersion: result.version)
                $0.note = "Uploaded \(result.files) save file\(result.files == 1 ? "" : "s") as a new snapshot." }
        } catch {
            fail(app, error)
        }
    }

    private func fail(_ app: String, _ error: Error) {
        let message = (error as? EpicAuthError)?.message ?? error.localizedDescription
        log("app=\(app) failed: \(message)")
        update(app) { $0.phase = .failed(message) }
    }
}

/// A game's Epic Cloud saves, on its Game details page below the Epic Games section.
struct EpicCloudSection: View {
    let appName: String
    @ObservedObject private var cloud = EpicCloud.shared
    @ObservedObject private var setting = EpicCloudSetting.shared
    @ObservedObject private var installer = EpicInstaller.shared
    @State private var confirmCloud = false
    @State private var confirmDevice = false

    private static func when(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "unknown date" }
    private static func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file) }
    private static func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }

    var body: some View {
        let state = cloud.state(appName)
        if setting.on, installer.installed[appName] != nil, state.phase != .unsupported {
            Section {
                rows(state)
            } header: {
                Text("Epic Cloud saves")
            } footer: {
                Text("Saves are compared with Epic's cloud when Madeira starts and when this page opens, not while you play. A newer cloud save is downloaded and the files it replaces are kept in Files › Madeira › Epic Cloud Backups. This device's newer saves are uploaded as a new snapshot when you press Sync now\(setting.autoUpload ? " or automatically" : ""); older snapshots stay in the cloud. When both sides changed, nothing is replaced until you choose.")
            }
            .task { await cloud.check(appName, automatic: true) }
        }
    }

    @ViewBuilder private func rows(_ state: EpicCloud.State) -> some View {
        switch state.phase {
        case .idle, .checking:
            HStack(spacing: 10) { ProgressView(); Text("Checking Epic's cloud…").foregroundStyle(.secondary) }
        case .downloading:
            HStack(spacing: 10) { ProgressView(); Text("Downloading saves…").foregroundStyle(.secondary) }
        case .uploading:
            HStack(spacing: 10) { ProgressView(); Text("Uploading saves…").foregroundStyle(.secondary) }
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.orange)
            Button("Try again") { Task { await cloud.check(appName, automatic: false) } }
        case .unsupported:
            EmptyView()
        case .ready:
            ready(state)
        }
    }

    @ViewBuilder private func ready(_ state: EpicCloud.State) -> some View {
        switch state.verdict {
        case .conflict:
            Label("The saves on this device and in Epic's cloud differ", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Epic's cloud: \(Self.when(state.cloudDate)) · \(Self.files(state.cloudFiles)) · \(Self.size(state.cloudBytes))")
                Text("This device: \(Self.when(state.deviceDate)) · \(Self.files(state.deviceFiles)) · \(Self.size(state.deviceBytes))")
            }.font(.caption).foregroundStyle(.secondary)
            Text("Nothing is changed until you choose which to keep.").font(.caption).foregroundStyle(.secondary)
            Button("Keep Epic's saves…") { confirmCloud = true }
                .confirmationDialog("Use Epic's saves on this device? The files they replace are copied to Files › Madeira › Epic Cloud Backups first.",
                                    isPresented: $confirmCloud, titleVisibility: .visible) {
                    Button("Use Epic's saves", role: .destructive) { Task { await cloud.resolve(appName, useCloud: true) } }
                    Button("Cancel", role: .cancel) {}
                }
            Button("Keep this device's saves…") { confirmDevice = true }
                .confirmationDialog("Upload this device's saves as Epic's newest snapshot? Other devices will get them. The older snapshots stay in the cloud.",
                                    isPresented: $confirmDevice, titleVisibility: .visible) {
                    Button("Upload this device's saves", role: .destructive) { Task { await cloud.resolve(appName, useCloud: false) } }
                    Button("Cancel", role: .cancel) {}
                }
        case .upload:
            Label("This device has newer saves", systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary)
            summary(state)
            Button("Sync now") { Task { await cloud.syncNow(appName) } }
        case .download:
            Label("Epic's cloud has newer saves", systemImage: "icloud.and.arrow.down").foregroundStyle(.secondary)
            summary(state)
            Button("Sync now") { Task { await cloud.syncNow(appName) } }
        case .empty:
            Text("No saves in Epic's cloud or on this device for this game.").foregroundStyle(.secondary)
            Button("Sync now") { Task { await cloud.syncNow(appName) } }
        default:
            Label("In sync", systemImage: "checkmark.icloud").foregroundStyle(.secondary)
            summary(state)
            Button("Sync now") { Task { await cloud.syncNow(appName) } }
        }
        if let note = state.note { Text(note).font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func summary(_ state: EpicCloud.State) -> some View {
        if state.cloudFiles > 0 { LabeledContent("Epic's cloud", value: "\(Self.when(state.cloudDate)) · \(Self.files(state.cloudFiles))") }
        if state.deviceFiles > 0 { LabeledContent("This device", value: "\(Self.when(state.deviceDate)) · \(Self.files(state.deviceFiles))") }
    }
}

/// Settings › Epic Games: the Epic Cloud saves switches (shown while signed in).
struct EpicCloudSettingRows: View {
    @ObservedObject private var setting = EpicCloudSetting.shared
    var body: some View {
        Toggle("Sync saves with Epic Cloud", isOn: $setting.on)
        if setting.on {
            Toggle("Upload newer saves automatically", isOn: $setting.autoUpload)
        }
    }
}
