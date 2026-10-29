// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Combine
import WebKit
import ContentKit
import GOGClientKit

@MainActor final class GOGGames: ObservableObject {
    static let shared = GOGGames()
    @Published private(set) var games: [GOGGame] = []
    @Published private(set) var signedIn = false
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var progress = 0.0
    @Published var error: String?
    private let session: GOGSession
    private let log: ContentKit.Logger
    private var worker: Task<Void, Never>?
    private var galaxy: GalaxyListener?
    private var gameID: UUID?
    private var watching: AnyCancellable?

    static var layout: InstallLayout {
        let state = LibraryModel.documents.appendingPathComponent("GOG", isDirectory: true)
        return InstallLayout(stagingRoot: state.appendingPathComponent("staging"),
            gamesRoot: LibraryModel.drive.appendingPathComponent("GOG Games"), stateRoot: state)
    }
    private var installer: GOGInstaller { GOGInstaller(layout: Self.layout, session: session, log: log) }

    private init() {
        let log = ContentKit.Logger { line in LogStore.shared.log("[gog] " + line) }
        self.log = log
        session = GOGSession(store: KeychainSecretStore(service: "org.madeira.gog"), log: log)
        watching = LibraryModel.shared.$current.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] current in
            guard let self, let id = self.gameID, current != id else { return }
            self.galaxy?.stop(); self.galaxy = nil; self.gameID = nil
        }
    }

    func refresh() {
        guard !busy else { return }
        perform {
            self.signedIn = await self.session.state == .signedIn
            if self.signedIn { self.games = try await GOGLibrary.owned(self.session) }
        }
    }

    func signIn(_ code: ContentKit.Secret<String>) {
        perform {
            try await self.session.signIn(code: code)
            self.signedIn = true
            self.games = try await GOGLibrary.owned(self.session)
        }
    }

    func signOut() {
        guard !busy, LibraryModel.shared.current == nil else { return }
        perform { await self.session.signOut(); self.games = []; self.signedIn = false }
    }

    func installed(_ id: String) -> Bool { installer.loadRecord(id) != nil }

    func install(_ game: GOGGame, repair: Bool = false) {
        guard LibraryModel.shared.current == nil, !SteamOwnedLibrary.shared.hasActiveDownload,
              !EpicLibrary.shared.hasActiveDownload else {
            error = "Finish the current game or download first."; return
        }
        perform {
            let installer = self.installer
            let progress: @Sendable (InstallEngine.Progress) -> Void = { p in
                Task { @MainActor in self.progress = p.bytesTotal == 0 ? 0 : Double(p.bytesDone) / Double(p.bytesTotal) }
            }
            self.status = repair ? "Checking and repairing \(game.title)" : "Installing or updating \(game.title)"
            if repair { _ = try await installer.repair(productID: game.id, progress: progress) }
            else { _ = try await installer.install(productID: game.id, owned: Set(self.games.map(\.id)), progress: progress) }
            guard let record = installer.loadRecord(game.id) else { throw LibraryError.message("GOG did not save the install record.") }
            let ids = await installer.dependencyIDs(productID: game.id)
            let deps = try await installer.dependencyRepository(for: ids)
            _ = try await installer.placeDependencies(installer.missingDependencies(deps, installDir: record.installDir),
                productID: game.id, installDir: record.installDir)
            let root = Self.layout.gamesRoot.appendingPathComponent(record.installDir)
            let infoURL = try InstallFS.resolveInside(root, "goggame-\(game.id).info", createParents: false)
            struct Info: Decodable {
                struct PlayTask: Decodable { var isPrimary: Bool?; var type: String?; var path: String?; var arguments: String?; var workingDir: String? }
                var playTasks: [PlayTask]?
            }
            let info = try JSONDecoder().decode(Info.self, from: Data(contentsOf: infoURL))
            let tasks = (info.playTasks ?? []).filter { ($0.type ?? "FileTask") == "FileTask" && $0.path != nil }
            guard let task = tasks.first(where: { $0.isPrimary == true }) ?? tasks.first,
                  let path = task.path else { throw LibraryError.message("Choose this game's executable from Add game. GOG did not provide a launch task.") }
            let executable = try InstallFS.resolveInside(root, path.replacingOccurrences(of: "\\", with: "/"), createParents: false)
            let gamePath = try Self.relative(executable)
            var entry = LibraryModel.shared.entries.first(where: { $0.gogProductID == game.id })
                ?? (try? LibraryModel.inspect(executable))
                ?? LibraryEntry(title: game.title, relativePath: gamePath, bits: 64)
            let support = await installer.supportCommands(productID: game.id)
            let script = try GOGLaunchManifest.make(executable: path, arguments: task.arguments ?? "",
                dependencies: deps, support: support, build: record.buildID, workingDirectory: task.workingDir ?? "")
            let wrapper = root.appendingPathComponent("madeira-gog-launch.exe")
            guard let helper = Bundle.main.url(forResource: "madeira-gog-launch", withExtension: "exe", subdirectory: "arm64ec-windows") else {
                throw LibraryError.message("The GOG launcher is missing from this build.")
            }
            try Data(contentsOf: helper).write(to: wrapper, options: .atomic)
            try script.write(to: root.appendingPathComponent("madeira-gog-launch.bin"), options: .atomic)
            entry.relativePath = try Self.relative(wrapper)
            entry.bits = 64
            entry.title = game.title
            entry.gogProductID = game.id
            entry.workingDirectory = "C:\\" + (try Self.relative(root)).replacingOccurrences(of: "/", with: "\\")
            LibraryModel.shared.save(entry)
            self.status = "Ready: \(game.title)"
        }
    }

    private static func relative(_ url: URL) throws -> String {
        guard let path = LibraryModel.relativeToDrive(url) else { throw LibraryError.message("The GOG path is outside the Windows drive.") }
        return path
    }

    func verify(_ game: GOGGame) {
        perform {
            let report = try await self.installer.verify(productID: game.id)
            self.status = report.bad.isEmpty ? "\(game.title): all \(report.files) files passed." : "\(report.bad.count) files need repair."
        }
    }

    // Called immediately before Wine starts, including launches from saved library entries.
    func prepareLaunch(_ entry: LibraryEntry) throws {
        galaxy?.stop(); galaxy = nil; gameID = nil
        guard let id = entry.gogProductID, let client = installer.loadRecord(id)?.galaxy else { return }
        let service = GalaxyService(client: client, tokens: session, log: log)
        let listener = GalaxyListener(service: service, log: log)
        try listener.start()
        galaxy = listener
        gameID = entry.id
    }

    func cancel() { worker?.cancel() }

    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; progress = 0
        worker = Task {
            do { try await body() }
            catch is CancellationError { status = "Paused. Install or update again to resume." }
            catch { self.error = error.localizedDescription }
            busy = false; worker = nil
        }
    }
}

struct GOGGamesView: View {
    var play: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = GOGGames.shared
    @ObservedObject private var library = LibraryModel.shared
    @State private var signingIn = false

    var body: some View {
        List {
            Section {
                if model.signedIn {
                    Button("Refresh library") { model.refresh() }
                    Button("Sign out", role: .destructive) { model.signOut() }
                } else { Button("Sign in to GOG") { signingIn = true } }
            }.disabled(model.busy || library.current != nil)
            if !model.status.isEmpty { Text(model.status) }
            if model.busy {
                ProgressView(value: model.progress)
                Button("Pause") { model.cancel() }
            }
            ForEach(model.games) { game in
                Section(game.title) {
                    Button(model.installed(game.id) ? "Update" : "Install") { model.install(game) }
                    if model.installed(game.id) {
                        if let entry = library.entries.first(where: { $0.gogProductID == game.id }) {
                            Button("Play") { play(entry) }
                        }
                        Button("Verify files") { model.verify(game) }
                        Button("Repair files") { model.install(game, repair: true) }
                    }
                }.disabled(model.busy || library.current != nil)
            }
        }
        .navigationTitle("GOG games")
        .task { model.refresh() }
        .onChange(of: library.current) { _, id in if id != nil { dismiss() } }
        .sheet(isPresented: $signingIn) {
            NavigationStack {
                GOGSignIn { code in signingIn = false; model.signIn(code) }
                    .navigationTitle("Sign in to GOG")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { signingIn = false } } }
            }
        }
        .alert("GOG", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private struct GOGSignIn: UIViewRepresentable {
    let complete: (ContentKit.Secret<String>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(complete) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.load(URLRequest(url: GOGAPI.loginURL))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let complete: (ContentKit.Secret<String>) -> Void
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }
        private var finished = false
        init(_ complete: @escaping (ContentKit.Secret<String>) -> Void) { self.complete = complete }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if let code = GOGAPI.code(fromRedirect: url) {
                decisionHandler(.cancel)
                if !finished { finished = true; complete(code) }
            } else { decisionHandler(url.scheme == "https" ? .allow : .cancel) }
        }
    }
}
