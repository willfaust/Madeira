// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// Portions follow Playport's GOGInstallScript (github.com/playportdev/playport,
// app/PlayportKit/Sources/PlayportKit/GOGInstallScript.swift, GPL-3.0-or-later):
// the script's shape and which actions matter.

import Foundation

// A GOG build's install script, `goggame-<product>.script` (docs/GOG.md, "Install
// script"): JSON with the product's id and `actions`. GOG Galaxy runs it after an
// install with its script interpreter. Its `setRegistry` actions are the values a
// game or its launcher reads to find itself: The Witcher: Enhanced Edition's
// launcher.exe quits at once, without a word, when HKLM\Software\CD Projekt Red\
// The Witcher has no InstallFolder. Madeira writes those values into the prefix
// before a play, like a Steam install script's "Registry" section
// (SteamInstallRegistry). Other actions (savePath, setIni, installSDB, Execute) are
// left out and logged. Log tag: [gog-script].

struct GOGInstallScript: Equatable, Sendable {
    struct Action: Equatable, Sendable {
        var name: String
        /// `install.action`: `setRegistry`, `savePath`, `Execute`, ...
        var kind: String
        /// `install.arguments` as text (numbers and booleans too); lists and objects are left out.
        var arguments: [String: String]
        /// nil: every language.
        var languages: [String]?
        /// nil: both.
        var osBitness: [String]?
    }

    /// One registry value the script sets.
    struct Value: Equatable, Sendable {
        enum Root: Equatable, Sendable { case machine, user }
        enum Content: Equatable, Sendable { case string(String), dword(UInt32) }
        var root: Root
        /// Under the root, `\` separators ("Software\CD Projekt Red\The Witcher").
        var key: String
        /// "" is the key's default value.
        var name: String
        var data: Content
        /// A string made from the game's folder: rewritten when the folder moves.
        var followsInstall: Bool
    }

    struct Plan: Equatable, Sendable {
        var values: [Value] = []
        /// What was left out, for the log.
        var notes: [String] = []
    }

    var productID: String
    var actions: [Action]

    /// nil for a file that is not an install script.
    static func parse(_ data: Data) -> GOGInstallScript? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard bytes.count < 4 << 20,
              let root = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let actions = root["actions"] as? [[String: Any]] else { return nil }
        let product = (root["productId"] as? String) ?? (root["productId"] as? NSNumber)?.stringValue ?? ""
        return GOGInstallScript(productID: product, actions: actions.map { action in
            let install = action["install"] as? [String: Any] ?? [:]
            var arguments: [String: String] = [:]
            for (key, value) in install["arguments"] as? [String: Any] ?? [:] {
                if let text = value as? String { arguments[key] = text }
                else if let number = value as? NSNumber { arguments[key] = number.stringValue }
            }
            return Action(name: action["name"] as? String ?? "", kind: install["action"] as? String ?? "",
                          arguments: arguments, languages: action["languages"] as? [String],
                          osBitness: action["osBitness"] as? [String])
        })
    }

    /// What a play writes for a game in `folder` (its Windows path, "C:\GOG Games\..."),
    /// installed in `language` ("en-US"). The prefix is 64-bit Windows.
    func plan(folder: String, language: String) -> Plan {
        var plan = Plan()
        for action in actions {
            let label = "\(productID) \(action.name.isEmpty ? action.kind : action.name)"
            if let languages = action.languages, !languages.contains(where: { Self.language($0, matches: language) }) { continue }
            if let bits = action.osBitness, !bits.contains("64") { continue }
            switch action.kind.lowercased() {
            case "setregistry": registry(action, folder: folder, label: label, into: &plan)
            case "execute" where Self.knownExecuteValues[productID] != nil:
                // The program (a Galaxy-only setup exe in GOG's support folder) is not
                // downloaded; write the values it is known to set instead.
                for value in Self.knownExecuteValues[productID] ?? [] {
                    var value = value
                    if case .string(let text) = value.data, let expanded = Self.expand(text, folder: folder) {
                        value.data = .string(expanded)
                        value.followsInstall = expanded != text
                    }
                    plan.values.removeAll { $0.root == value.root && $0.key.lowercased() == value.key.lowercased() && $0.name.lowercased() == value.name.lowercased() }
                    plan.values.append(value)
                }
                plan.notes.append("\(label): Execute \(action.arguments["executable"] ?? "") replaced by its known registry values")
            case "":            plan.notes.append("\(label): no action")
            default:            plan.notes.append("\(label): \(action.kind) left out")
            }
        }
        return plan
    }

    /// Values a product's Execute action (a setup exe GOG Galaxy runs from the support
    /// folder) writes, for products whose script has no setRegistry actions. `{app}` is
    /// the game's folder. The Witcher: Enhanced Edition (1207658924) runs
    /// galaxy_the_witcher_enhanced_edition_*.exe; launcher.exe and System\witcher.exe
    /// both quit at once without these (device-tested by hand on build 64, 2026-11-01;
    /// values as Games Nebula's GOG script sets them).
    static let knownExecuteValues: [String: [Value]] = [
        "1207658924": [
            Value(root: .machine, key: "Software\\CD Projekt Red\\The Witcher", name: "InstallFolder", data: .string("{app}"), followsInstall: true),
            Value(root: .machine, key: "Software\\CD Projekt Red\\The Witcher", name: "IsDjinniInstalled", data: .dword(1), followsInstall: false),
            Value(root: .machine, key: "Software\\CD Projekt Red\\The Witcher", name: "Language", data: .string("3"), followsInstall: false),
            Value(root: .machine, key: "Software\\CD Projekt Red\\The Witcher", name: "RegionVersion", data: .string("US"), followsInstall: false),
        ],
    ]

    private func registry(_ action: Action, folder: String, label: String, into plan: inout Plan) {
        let args = action.arguments
        let subkey = (args["subkey"] ?? "").replacingOccurrences(of: "/", with: "\\")
            .split(separator: "\\").joined(separator: "\\")
        let root: Value.Root
        switch (args["root"] ?? "").uppercased() {
        case "HKEY_LOCAL_MACHINE", "HKLM": root = .machine
        case "HKEY_CURRENT_USER", "HKCU": root = .user
        default: plan.notes.append("\(label): root \(args["root"] ?? "") left out"); return
        }
        guard !subkey.isEmpty else { plan.notes.append("\(label): no subkey"); return }
        // A key without a value marks it for cloud saves or the uninstaller.
        guard let name = args["valueName"] else { return }
        let raw = args["valueData"] ?? ""
        guard let text = Self.expand(raw, folder: folder) else {
            plan.notes.append("\(label): \(subkey) \"\(name)\" uses an unknown placeholder; left out")
            return
        }
        let data: Value.Content
        switch (args["valueType"] ?? "string").lowercased() {
        case "string", "sz", "reg_sz", "expandstring":
            data = .string(text)
        case "dword", "reg_dword":
            let digits = text.trimmingCharacters(in: .whitespaces)
            guard let number = digits.lowercased().hasPrefix("0x") ? UInt32(digits.dropFirst(2), radix: 16) : UInt32(digits) else {
                plan.notes.append("\(label): \(subkey) \"\(name)\" is not a number; left out")
                return
            }
            data = .dword(number)
        case let other:
            plan.notes.append("\(label): \(subkey) \"\(name)\" of type \(other) left out")
            return
        }
        let value = Value(root: root, key: subkey, name: name, data: data, followsInstall: text != raw)
        // A later action for the same value wins, as when the interpreter runs them in order.
        plan.values.removeAll { $0.root == value.root && $0.key.lowercased() == value.key.lowercased() && $0.name.lowercased() == value.name.lowercased() }
        plan.values.append(value)
    }

    /// `{app}` and `{supportDir}` (Madeira keeps the script in the game's folder) as the
    /// folder, `/` after it as `\`; nil for another placeholder.
    static func expand(_ text: String, folder: String) -> String? {
        guard text.contains("{") else { return text }
        var out = text
        for token in ["{app}", "{supportDir}"] {
            out = out.replacingOccurrences(of: token, with: folder, options: .caseInsensitive)
        }
        guard !out.contains("{") else { return nil }
        guard out.hasPrefix(folder) else { return out }
        return folder + out.dropFirst(folder.count).replacingOccurrences(of: "/", with: "\\")
    }

    /// An action's language (`*`, `en-US`, or a bare `en`) covers the install's.
    static func language(_ wanted: String, matches language: String) -> Bool {
        wanted == "*" || wanted.lowercased() == language.lowercased()
            || (!wanted.contains("-") && wanted.lowercased() == language.split(separator: "-").first.map { $0.lowercased() })
    }

    /// `goggame-<digits>.script`.
    static func isScriptName(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasPrefix("goggame-"), lower.hasSuffix(".script") else { return false }
        let digits = lower.dropFirst("goggame-".count).dropLast(".script".count)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// The install scripts at the root of a game's folder (one per product that ships one).
    static func scripts(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(isScriptName).sorted().map { folder.appendingPathComponent($0) }
    }
}
