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
    @State private var manifest: WingetManifest?
    @State private var error: String?
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
