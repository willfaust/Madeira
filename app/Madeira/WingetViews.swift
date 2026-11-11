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
                NewLookSearchRow(id: "wg-" + p.id, last: index == results.count - 1, inset: 16, title: p.name,
                                 note: p.id + " · " + p.latest, action: { open(p.id) }) { EmptyView() }
            }
        }
    }
}

/// One package: its manifest, fetched and checked when the page opens. Shows what `winget show` does.
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
        NewLookScrollPage(title: manifest?.name ?? catalog.package(id: id)?.name ?? id) { _ in
            VStack(alignment: .leading, spacing: 16) {
                if let m = manifest { content(m) }
                else if let error { ContentUnavailableView(L("Couldn't load this app"), systemImage: "wifi.exclamationmark", description: Text(error)) }
                else { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
            }
        }
        .task {
            guard manifest == nil, let package = catalog.package(id: id) else { error = L("This app is not in the list."); return }
            do { manifest = try await WingetCatalog.manifest(for: package) }
            catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private func content(_ m: WingetManifest) -> some View {
        HStack(spacing: 16) {
            // The app's own icon when its manifest has one (about a quarter do), else the Windows glyph.
            AsyncImage(url: URL(string: m.iconURL)) { $0.resizable().scaledToFit() } placeholder: { NewLookSoftwareIcon(size: 64) }
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 64 * 0.27, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(m.name).font(.title2.bold())
                Text(m.publisher).font(.subheadline).foregroundStyle(.secondary)
                Text([m.version, m.releaseDate].filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        if !m.shortDescription.isEmpty { Text(m.shortDescription).font(.body) }
        installSection(m)
        about(m)
        if !m.agreements.isEmpty { agreements(m) }
        installers(m)
    }

    private func about(_ m: WingetManifest) -> some View {
        var rows: [(String, String, String?)] = [
            (L("Publisher"), m.publisher, m.publisherURL), (L("Author"), m.author, nil), (L("Identifier"), m.id, nil),
            (L("Version"), m.version, nil), (L("Release date"), m.releaseDate, nil),
            (L("License"), m.license, m.licenseURL), (L("Copyright"), m.copyright, m.copyrightURL),
            (L("Privacy"), m.privacyURL.isEmpty ? "" : L("Privacy statement"), m.privacyURL),
            (L("Support"), m.supportURL.isEmpty ? "" : L("Publisher support"), m.supportURL),
            (L("Website"), m.packageURL.isEmpty ? "" : m.packageURL, m.packageURL),
            (L("Commands"), m.commands.joined(separator: ", "), nil), (L("Moniker"), m.moniker, nil),
            (L("Tags"), m.tags.joined(separator: ", "), nil),
        ]
        for d in m.documentation where !d.url.isEmpty { rows.append((L("Documentation"), d.label.isEmpty ? d.url : d.label, d.url)) }
        rows = rows.filter { !$0.1.isEmpty }
        return VStack(alignment: .leading, spacing: 16) {
            NewLookSection(title: L("About")) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    infoRow(row.0, row.1, url: row.2)
                        .overlay(alignment: .bottom) { if index < rows.count - 1 { Divider().padding(.leading, 16) } }
                }
            }
            if !m.description.isEmpty {
                NewLookSection(title: L("Description")) { text(m.description) }
            }
            if !m.releaseNotes.isEmpty {
                NewLookSection(title: L("Release notes")) {
                    VStack(alignment: .leading, spacing: 8) {
                        text(m.releaseNotes)
                        if let url = URL(string: m.releaseNotesURL), !m.releaseNotesURL.isEmpty {
                            Button(L("Read the release notes")) { openURL(url) }.font(.subheadline).padding(.horizontal, 16).padding(.bottom, 12)
                        }
                    }
                }
            }
        }
    }

    private func agreements(_ m: WingetManifest) -> some View {
        NewLookSection(title: L("Agreements")) {
            ForEach(Array(m.agreements.enumerated()), id: \.offset) { _, a in
                VStack(alignment: .leading, spacing: 4) {
                    if !a.label.isEmpty { Text(a.label).font(.subheadline.weight(.semibold)) }
                    if !a.text.isEmpty { Text(a.text).font(.footnote).foregroundStyle(.secondary) }
                    if let url = URL(string: a.url), !a.url.isEmpty { Button(a.url) { openURL(url) }.font(.footnote) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func installers(_ m: WingetManifest) -> some View {
        NewLookSection(title: L("Installers")) {
            ForEach(Array(m.installers.enumerated()), id: \.offset) { index, i in
                VStack(alignment: .leading, spacing: 4) {
                    Text([i.type, i.architecture, i.scope, i.locale].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline.weight(.semibold))
                    if let url = URL(string: i.url) { Button(url.host ?? i.url) { openURL(url) }.font(.footnote) }
                    if !i.sha256.isEmpty { Text("SHA-256 " + i.sha256).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    if !i.productCode.isEmpty { Text(L("Product code") + " " + i.productCode).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { if index < m.installers.count - 1 { Divider().padding(.leading, 16) } }
            }
        }
    }

    private func text(_ value: String) -> some View {
        Text(value).font(.subheadline).padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(_ label: String, _ value: String, url: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
            if let url, let link = URL(string: url), !url.isEmpty {
                Button(value) { openURL(link) }.font(.subheadline).multilineTextAlignment(.leading)
            } else { Text(value).font(.subheadline).textSelection(.enabled) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
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

