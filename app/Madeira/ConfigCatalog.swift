import SwiftUI

/// One option Madeira reads from Documents/madeira.cfg: a plain key
/// ("vram-mb = 4352") or an environment switch the app exports before Wine
/// starts ("env.MADEIRA_SWAP_COVERAGE = classic"). The list itself is
/// ConfigCatalog.generated.swift, written by build/tools/gen-config-catalog.py
/// from the code that reads each option; check-config-catalog.py fails when it
/// falls behind the code.
struct ConfigOption: Identifiable {
    enum Kind { case bool, int, text, choice }
    struct Choice: Hashable { let value: String; let label: String }

    let key: String
    let title: String
    let kind: Kind
    let defaultValue: String
    let category: String
    let note: String
    let choices: [Choice]
    let sources: [String]
    var id: String { key }
    var displayTitle: String { title.isEmpty ? key : title }

    init(key: String, title: String, kind: Kind, defaultValue: String, category: String, note: String,
         choices: [(String, String)], sources: [String]) {
        self.key = key; self.title = title; self.kind = kind; self.defaultValue = defaultValue
        self.category = category; self.note = note; self.sources = sources
        self.choices = choices.map { Choice(value: $0.0, label: $0.1) }
    }
}

enum ConfigCatalog {
    /// Categories in the order the catalog lists them.
    static let categories: [String] = {
        var seen = Set<String>()
        return generated.map(\.category).filter { seen.insert($0).inserted }
    }()
    static let keys = Set(generated.map(\.key))
}

/// Settings › All settings: every catalogued option, editable in place.
/// Writing goes through MadeiraConfig.set, which keeps comments and every other
/// line of madeira.cfg; an option set back to Default is removed from the file.
struct AllSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = MadeiraConfig.all()
    @State private var search = ""
    @State private var changed = false
    @State private var newKey = ""
    @State private var newValue = ""

    private func matches(_ o: ConfigOption) -> Bool {
        search.isEmpty || [o.key, o.title, o.note, o.category].contains { $0.localizedCaseInsensitiveContains(search) }
    }
    private var otherKeys: [String] {
        values.keys.filter { !ConfigCatalog.keys.contains($0) && (search.isEmpty || $0.localizedCaseInsensitiveContains(search)) }.sorted()
    }

    private func binding(_ key: String) -> Binding<String?> {
        Binding(get: { values[key] }, set: { new in
            let v = new?.trimmingCharacters(in: .whitespaces)
            let stored = (v?.isEmpty ?? true) ? nil : v
            guard stored != values[key] else { return }
            MadeiraConfig.set(key, stored)
            values = MadeiraConfig.all()
            changed = true
            LogStore.shared.log("[all-settings] \(key) = \(stored ?? "(default)")")
        })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Every other option Madeira reads from madeira.cfg. JIT pool, video memory, the swap tier, the sync engine and eco mode are in Settings › Memory & sync; the Direct3D 9/12 routes, the Vulkan driver and windowed mode in Settings › Graphics. Most options are read when Madeira starts, so close it from the app switcher after a change. Default leaves the option out of the file. Swipe left on a row to reset it.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if changed {
                        Text("Restart Madeira (close it from the app switcher) for changes to apply.").font(.footnote).foregroundStyle(.orange)
                    }
                }
                ForEach(ConfigCatalog.categories, id: \.self) { category in
                    let options = ConfigCatalog.generated.filter {
                        $0.category == category && !RuntimeMemorySyncSettings.featuredKeys.contains($0.key) && matches($0)
                    }
                    if !options.isEmpty {
                        Section(category) {
                            ForEach(options) { ConfigOptionRow(option: $0, value: binding($0.key)) }
                        }
                    }
                }
                if !otherKeys.isEmpty {
                    Section {
                        ForEach(otherKeys, id: \.self) { key in
                            ConfigOptionRow(option: ConfigOption(key: key, title: "", kind: .text, defaultValue: "",
                                                                 category: "", note: "", choices: [], sources: []),
                                            value: binding(key))
                        }
                    } header: { Text("Other entries in madeira.cfg") } footer: {
                        Text("Set in your madeira.cfg but not read by name in Madeira's code, for example FEX options passed as env.FEX_*.")
                    }
                }
                Section {
                    TextField("key, or env.NAME", text: $newKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    TextField("value", text: $newValue)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    Button("Add to madeira.cfg") {
                        let k = newKey.trimmingCharacters(in: .whitespaces)
                        guard !k.isEmpty, !k.contains("="), !k.hasPrefix("#") else { return }
                        binding(k).wrappedValue = newValue
                        newKey = ""; newValue = ""
                    }
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: { Text("Add an entry") } footer: {
                    Text("For anything not listed, such as env.FEX_TSOENABLED = 1.")
                }
            }
            .searchable(text: $search, prompt: "Search options")
            .navigationTitle("All settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { values = MadeiraConfig.all() }
        }
    }
}

/// One option: its control, what the code says about it, its key and default.
struct ConfigOptionRow: View {
    let option: ConfigOption
    @Binding var value: String?
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if !option.note.isEmpty {
                Text(option.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if !option.title.isEmpty { Text(option.key).font(.caption2.monospaced()) }
                if !option.defaultValue.isEmpty { Text("default \(option.defaultValue)").font(.caption2) }
                if value != nil { Text("set").font(.caption2.weight(.semibold)).foregroundStyle(.tint) }
            }
            .foregroundStyle(.secondary)
        }
        .swipeActions {
            if value != nil { Button("Reset", role: .destructive) { value = nil; draft = "" } }
        }
    }

    @ViewBuilder private var control: some View {
        switch option.kind {
        case .bool:
            Picker(option.displayTitle, selection: Binding(get: { value ?? "" }, set: { value = $0.isEmpty ? nil : $0 })) {
                Text("Default").tag("")
                Text("On").tag("1")
                Text("Off").tag("0")
                if let v = value, !["1", "0"].contains(v) { Text(v).tag(v) }
            }
        case .choice:
            Picker(option.displayTitle, selection: Binding(get: { value ?? "" }, set: { value = $0.isEmpty ? nil : $0 })) {
                ForEach(option.choices, id: \.self) { Text($0.label).tag($0.value) }
                if let v = value, !option.choices.contains(where: { $0.value == v }) { Text("Custom: \(v)").tag(v) }
            }
        case .int, .text:
            HStack {
                Text(option.displayTitle).lineLimit(2)
                Spacer(minLength: 12)
                TextField("Default", text: $draft)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(option.kind == .int ? .numbersAndPunctuation : .default)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                    .focused($editing)
                    .onSubmit { value = draft }
                    .frame(maxWidth: 170)
            }
            .onAppear { draft = value ?? "" }
            .onChange(of: value) { _, v in if !editing { draft = v ?? "" } }
            .onChange(of: editing) { _, on in if !on, draft != (value ?? "") { value = draft } }
        }
    }
}

/// Settings search: the All settings options that match, editable in place.
/// The options with a row of their own in Settings › Memory & sync or Settings › Graphics are left out.
struct SettingsSearchResults: View {
    let query: String
    /// Bumped when a Settings sheet closes, so the rows re-read madeira.cfg.
    var refresh = 0
    @State private var values: [String: String] = MadeiraConfig.all()
    private static let limit = 60

    private var hits: [ConfigOption] {
        ConfigCatalog.generated.filter { o in
            !RuntimeMemorySyncSettings.featuredKeys.contains(o.key)
                && [o.key, o.title, o.note, o.category].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    private func binding(_ key: String) -> Binding<String?> {
        Binding(get: { values[key] }, set: { new in
            let v = new?.trimmingCharacters(in: .whitespaces)
            let stored = (v?.isEmpty ?? true) ? nil : v
            guard stored != values[key] else { return }
            MadeiraConfig.set(key, stored)
            values = MadeiraConfig.all()
            LogStore.shared.log("[settings-search] \(key) = \(stored ?? "(default)")")
        })
    }

    var body: some View {
        let hits = self.hits
        Section {
            if hits.isEmpty {
                Text("No other options match \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary)
            }
            ForEach(hits.prefix(Self.limit)) { ConfigOptionRow(option: $0, value: binding($0.key)) }
        } header: {
            Text(hits.isEmpty ? "Options" : "Options (\(hits.count))")
        } footer: {
            if hits.count > Self.limit {
                Text("Showing \(Self.limit) of \(hits.count). Refine the search, or open All settings.")
            } else if !hits.isEmpty {
                Text("Most options are read when Madeira starts: close it from the app switcher after a change.")
            }
        }
        .onChange(of: refresh) { _, _ in values = MadeiraConfig.all() }
    }
}
