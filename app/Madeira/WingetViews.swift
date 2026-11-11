// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

/// Software: the winget source's apps, searched from Stores. Nothing here needs Wine.
struct WingetPage: View {
    let open: (String) -> Void
    @ObservedObject private var catalog = WingetCatalog.shared
    @State private var text = ""
    @State private var results: [WingetPackage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField(L("Search software"), text: $text)
                .textFieldStyle(.plain).autocorrectionDisabled().textInputAutocapitalization(.never)
                .padding(12).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: NewLook.cardRadius, style: .continuous))
            switch catalog.state {
            case .idle, .loading: ProgressView(L("Getting the software list")).frame(maxWidth: .infinity).padding(.top, 24)
            case .failed(let message):
                ContentUnavailableView(L("Couldn't get the software list"), systemImage: "wifi.exclamationmark", description: Text(message))
                Button(L("Try again")) { Task { await catalog.load(force: true) } }.frame(maxWidth: .infinity)
            case .ready:
                if text.trimmingCharacters(in: .whitespaces).count < 2 {
                    Text(String(format: L("%@ apps from the winget source. Type a name to find one."), catalog.count.formatted()))
                        .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
                } else if results.isEmpty { ContentUnavailableView.search(text: text) }
                else { WingetResults(results: results, open: open) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)
        .task { await catalog.load() }
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            results = await catalog.search(text)
        }
    }
}

struct WingetResults: View {
    let results: [WingetPackage]
    let open: (String) -> Void
    var body: some View {
        NewLookSection(title: nil) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, p in
                NewLookSearchRow(id: "wg-" + p.id, last: index == results.count - 1, title: p.name,
                                 note: p.id + " · " + p.latest, action: { open(p.id) }) { NewLookBadge(symbol: "shippingbox") }
            }
        }
    }
}

/// One package: its manifest, fetched and checked when the page opens.
struct WingetDetailPage: View {
    let id: String
    @ObservedObject private var catalog = WingetCatalog.shared
    @ObservedObject private var installs = WingetInstalls.shared
    @ObservedObject private var library = LibraryModel.shared
    @State private var manifest: WingetManifest?
    @State private var error: String?
    @State private var working = false
    @State private var actionError: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        NewLookScrollPage { _ in
            VStack(alignment: .leading, spacing: 16) {
                if let m = manifest { content(m) }
                else if let error { ContentUnavailableView(L("Couldn't load this app"), systemImage: "wifi.exclamationmark", description: Text(error)) }
                else { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
            }
        }
        .navigationTitle(catalog.package(id: id)?.name ?? id)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard manifest == nil, let package = catalog.package(id: id) else { error = L("This app is not in the list."); return }
            do { manifest = try await WingetCatalog.manifest(for: package) }
            catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private func content(_ m: WingetManifest) -> some View {
        HStack(spacing: 16) {
            AsyncImage(url: URL(string: m.iconURL)) { $0.resizable().scaledToFit() } placeholder: { NewLookBadge(symbol: "shippingbox") }
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(m.name).font(.title2.bold())
                Text(m.publisher).font(.subheadline).foregroundStyle(.secondary)
                Text([m.version, m.releaseDate].filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        if !m.shortDescription.isEmpty { Text(m.shortDescription).font(.body) }
        installSection(m)
        NewLookSection(title: L("Installers")) {
            ForEach(Array(m.installers.enumerated()), id: \.offset) { index, i in
                HStack {
                    Text([i.type, i.architecture, i.scope].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        if !m.license.isEmpty || !m.packageURL.isEmpty {
            NewLookSection(title: L("About")) {
                VStack(alignment: .leading, spacing: 8) {
                    if !m.license.isEmpty { Text(m.license).font(.subheadline) }
                    if let url = URL(string: m.packageURL), !m.packageURL.isEmpty {
                        Button(L("Website")) { openURL(url) }.font(.subheadline)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension WingetDetailPage {
    @ViewBuilder fileprivate func installSection(_ m: WingetManifest) -> some View {
        let choice = WingetPlan.choose(m.installers)
        let record = installs.records[m.id]
        let waiting = installs.pending.flatMap { $0.id == m.id ? $0 : nil }
        NewLookSection(title: nil) {
            VStack(alignment: .leading, spacing: 12) {
                if let record {
                    Label(String(format: L("Installed %@"), record.version), systemImage: "checkmark.circle.fill").font(.headline)
                    if WingetPlan.isNewer(m.version, than: record.version) {
                        action(String(format: L("Update to %@"), m.version), primary: true) { await prepare(m) }
                    }
                    if let first = installs.programs(for: m.id).first {
                        action(L("Add to library"), primary: false) { addToLibrary(first, name: m.name) }
                    }
                    action(L("Uninstall"), primary: false) { await uninstall(m.id) }
                } else if let waiting {
                    Text(waiting.kind == .install ? L("The installer is ready in your library. Open it and tap Play to install.")
                                                  : L("The uninstaller is ready in your library. Open it and tap Play."))
                        .font(.subheadline)
                    action(L("Open it"), primary: true) { library.showDetail = waiting.entry }
                } else {
                    switch choice {
                    case .success: action(L("Install"), primary: true) { await prepare(m) }
                    case .failure(let why): Text(Self.reason(why)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("Runs the publisher's installer inside Madeira's Windows. Nothing is installed on your iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let note = installs.messages[m.id] { Text(note).font(.footnote).foregroundStyle(.orange) }
                if let actionError { Text(actionError).font(.footnote).foregroundStyle(.red) }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func action(_ title: String, primary: Bool, run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: {
            HStack { Text(title).font(.headline); Spacer(); if working { ProgressView() } }
                .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 44)
                .background(primary ? NewLookColor.button : Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: NewLook.cardRadius, style: .continuous))
                .foregroundStyle(primary ? Color.white : Color.primary)
        }
        .buttonStyle(.plain).disabled(working)
    }

    private func prepare(_ m: WingetManifest) async {
        working = true; actionError = nil; defer { working = false }
        do {
            let entry = try await installs.prepare(m)
            library.save(entry)
            library.showDetail = entry.id
        } catch let refusal as WingetRefusal { actionError = Self.reason(refusal) }
        catch { actionError = error.localizedDescription }
    }

    private func uninstall(_ id: String) async {
        actionError = nil
        do {
            let entry = try installs.prepareUninstall(id)
            library.save(entry)
            library.showDetail = entry.id
        } catch { actionError = error.localizedDescription }
    }

    private func addToLibrary(_ program: URL, name: String) {
        guard var entry = library.entry(running: program) ?? (try? LibraryModel.inspect(program)) else { return }
        entry.title = name
        library.save(entry)
        library.showDetail = entry.id
    }

    static func reason(_ r: WingetRefusal) -> String {
        switch r {
        case .noInstaller: return L("This app has no installer Madeira can use.")
        case .onlyArm: return L("This app only comes in an ARM version. Madeira runs x64 and x86 programs.")
        case .packaged(let type): return String(format: L("This app is a Windows Store package (%@). Madeira cannot install those."), type)
        case .needsSilentSwitch: return L("This installer has no silent mode, so it would open a window nobody can use.")
        case .noNestedFile: return L("This archive does not say which file to run.")
        }
    }
}

