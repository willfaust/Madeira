// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Game details › Mods: everything that needs no screen. A mod is unpacked once
//  into its own folder (<Application Support>/Mods/<game>/<mod>/files); turning it
//  on copies its files into the game's folder, turning it off takes them out again.
//  Every original file a mod replaces is moved to <game store>/backups first and
//  moved back when no mod covers it any more, so a game returns to its own bytes.
//  mods.json is the manifest: the mods in install order, and for every file a mod
//  wrote, which mods have it (the latest one on wins) and its backup.
//
//  A mod never writes outside the game's folder, never replaces a Steam file
//  (steam_api*.dll, steamclient*.dll and the rest of Valve's) and never replaces a
//  program the game already has (its .exe): it stops with a plain sentence first,
//  before any file is touched.
//
//  Also here: FOMOD installers (fomod/ModuleConfig.xml, read with XMLParser), where
//  a mod's files go (the game's Data folder or the game folder), plugins.txt for
//  Bethesda games, Fallout.ini's loose-file switch, and the winhttp line BepInEx
//  needs in the game's own config.
//
//  Foundation only: tests/host/check-mods.py compiles this file with a test harness.
//

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: Errors

enum ModError: LocalizedError, Equatable {
    case valveFile(String)
    case gameProgram(String)
    case outside(String)
    case link(String)
    case noFiles
    case badInstaller(String)
    case missingSource(String)
    case unknownFile(String)
    case rar(String)
    case encrypted

    var errorDescription: String? {
        switch self {
        case .valveFile(let name): return "This mod tries to replace \(name), a Steam file Madeira never changes. Nothing was changed."
        case .gameProgram(let name): return "This mod tries to replace the game's program (\(name)). Madeira never changes it, so nothing was changed."
        case .outside(let name): return "This mod has a file that would land outside the game's folder (\(name)). Nothing was changed."
        case .link(let name): return "This mod has a shortcut file Madeira will not copy (\(name)). Nothing was changed."
        case .noFiles: return "There are no files in this mod."
        case .badInstaller(let why): return "This mod's installer could not be read (\(why))."
        case .missingSource(let name): return "This mod's installer names a file the mod does not have (\(name))."
        case .unknownFile(let name): return "Madeira can't open \(name). Choose a .zip, .7z, .rar or .fomod file, or a folder."
        case .rar(let why): return ".rar files can't be opened on this device (\(why)). Unpack it on a computer and choose the folder, or use a .zip or .7z."
        case .encrypted: return "This archive has a password. Madeira can't open it."
        }
    }
}

// MARK: Paths

enum ModPath {
    /// A relative path with "/" separators, made safe to join under a folder, or nil.
    static func clean(_ raw: String) -> String? {
        var name = raw.replacingOccurrences(of: "\\", with: "/")
        while name.hasPrefix("./") { name.removeFirst(2) }
        guard !name.hasPrefix("/"), !name.contains(":"), !name.contains("\u{0}") else { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// `relative` under `base`, each existing part matched without regard to case (the
    /// game sees C: without case, the device's disk does not): "data/Meshes/x.nif" over
    /// "Data/meshes" gives "Data/meshes/x.nif". Parts that do not exist keep their case.
    static func existing(_ relative: String, under base: URL) -> String {
        let fm = FileManager.default
        // An archive can hold "Extras/" and "extras/" both: each match is tried until one has the whole path.
        func whole(_ parts: ArraySlice<String>, _ at: URL) -> [String]? {
            guard let part = parts.first else { return [] }
            let names = ((try? fm.contentsOfDirectory(atPath: at.path)) ?? []).filter { $0.caseInsensitiveCompare(part) == .orderedSame }
            for name in names.sorted(by: { ($0 == part ? 0 : 1, $0) < ($1 == part ? 0 : 1, $1) }) {
                if let rest = whole(parts.dropFirst(), at.appendingPathComponent(name)) { return [name] + rest }
            }
            return nil
        }
        let split = relative.split(separator: "/").map(String.init)
        if let found = whole(split[...], base) { return found.joined(separator: "/") }
        var current = base
        var out: [String] = []
        var matching = true
        for part in relative.split(separator: "/").map(String.init) {
            var name = part
            if matching {
                if fm.fileExists(atPath: current.appendingPathComponent(part).path) {
                    name = part
                } else if let found = ((try? fm.contentsOfDirectory(atPath: current.path)) ?? [])
                            .first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                    name = found
                } else {
                    matching = false
                }
            }
            out.append(name)
            current = current.appendingPathComponent(name)
        }
        return out.joined(separator: "/")
    }

    /// The child of `folder` named `name` in any case, or nil.
    static func child(_ name: String, of folder: URL) -> URL? {
        guard let found = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return folder.appendingPathComponent(found)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// Every regular file under `folder`, relative, sorted; a symbolic link stops it.
    static func files(in folder: URL) throws -> [String] {
        let fm = FileManager.default
        // Both sides with their links followed (/var is /private/var on the device).
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        var out: [String] = []
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let path = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                .appendingPathComponent(url.lastPathComponent).path
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
            if values.isSymbolicLink == true { throw ModError.link(relative) }
            if values.isRegularFile == true { out.append(relative) }
        }
        return out.sorted()
    }

    /// Whether `url` (once its folders' links are followed) is inside `folder`.
    static func inside(_ url: URL, _ folder: URL) -> Bool {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        var parent = url.deletingLastPathComponent()
        // Folders that do not exist yet are resolved from the first one that does.
        var tail: [String] = [url.lastPathComponent]
        while !FileManager.default.fileExists(atPath: parent.path), parent.path.count > 1 {
            tail.insert(parent.lastPathComponent, at: 0)
            parent = parent.deletingLastPathComponent()
        }
        let resolved = tail.reduce(parent.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL.path
        return resolved.hasPrefix(root + "/")
    }
}

// MARK: FOMOD

/// A small element tree from XMLParser, names and attribute keys in lower case
/// (installers are written by hand, in every case).
final class ModXMLNode {
    let name: String
    let attributes: [String: String]
    var children: [ModXMLNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> ModXMLNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [ModXMLNode] { children.filter { $0.name == name } }
    func attr(_ name: String) -> String? { attributes[name] }
}

private final class ModXMLTree: NSObject, XMLParserDelegate {
    var root: ModXMLNode?
    private var stack: [ModXMLNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict where attributes[key.lowercased()] == nil { attributes[key.lowercased()] = value }
        let node = ModXMLNode(name: local.lowercased(), attributes: attributes)
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }

    static func parse(_ data: Data) -> ModXMLNode? {
        let tree = ModXMLTree()
        let parser = XMLParser(data: data)
        parser.delegate = tree
        return parser.parse() ? tree.root : nil
    }
}

enum FomodGroupKind: String, Equatable {
    case exactlyOne = "selectexactlyone", atMostOne = "selectatmostone", atLeastOne = "selectatleastone"
    case any = "selectany", all = "selectall"
    /// One choice at most: shown as round buttons.
    var single: Bool { self == .exactlyOne || self == .atMostOne }
}

enum FomodPluginKind: String, Equatable {
    case required = "required", recommended = "recommended", optional = "optional"
    case notUsable = "notusable", couldBeUsable = "couldbeusable"
    init(_ raw: String?) { self = FomodPluginKind(rawValue: (raw ?? "").lowercased()) ?? .optional }
}

/// One <file> or <folder> to install: `source` in the mod, `destination` under the
/// folder the mod installs into.
struct FomodItem: Equatable {
    var source: String
    var destination: String
    var priority: Int
    var folder: Bool
}

indirect enum FomodCondition: Equatable {
    case flag(String, String)
    case file(String, String)
    case all([FomodCondition])
    case any([FomodCondition])
    case always

    /// `fileState` says "active", "inactive" or "missing" for a plugin's name.
    func holds(_ flags: [String: String], fileState: (String) -> String) -> Bool {
        switch self {
        case .flag(let name, let value): return (flags[name.lowercased()] ?? "") == value
        case .file(let name, let state): return fileState(name) == state
        case .all(let parts): return parts.allSatisfy { $0.holds(flags, fileState: fileState) }
        case .any(let parts): return parts.isEmpty || parts.contains { $0.holds(flags, fileState: fileState) }
        case .always: return true
        }
    }
}

struct FomodFlag: Equatable {
    var name: String
    var value: String
}

struct FomodPlugin: Equatable {
    var name: String
    var description: String
    var image: String?
    var items: [FomodItem]
    var flags: [FomodFlag]
    var kind: FomodPluginKind
    var patterns: [(FomodCondition, FomodPluginKind)]

    static func == (a: FomodPlugin, b: FomodPlugin) -> Bool {
        a.name == b.name && a.description == b.description && a.image == b.image && a.items == b.items && a.flags == b.flags
            && a.kind == b.kind && a.patterns.count == b.patterns.count
            && zip(a.patterns, b.patterns).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    /// The plugin's kind with the flags chosen so far: the first pattern that holds, else its default.
    func kind(_ flags: [String: String], fileState: (String) -> String) -> FomodPluginKind {
        patterns.first { $0.0.holds(flags, fileState: fileState) }?.1 ?? kind
    }
}

struct FomodGroup: Equatable {
    var name: String
    var kind: FomodGroupKind
    var plugins: [FomodPlugin]
}

struct FomodStep: Equatable {
    var name: String
    var visible: FomodCondition?
    var groups: [FomodGroup]
}

struct FomodConfig: Equatable {
    var moduleName: String
    var required: [FomodItem]
    var steps: [FomodStep]
    var conditional: [(FomodCondition, [FomodItem])]

    static func == (a: FomodConfig, b: FomodConfig) -> Bool {
        a.moduleName == b.moduleName && a.required == b.required && a.steps == b.steps
            && a.conditional.count == b.conditional.count && zip(a.conditional, b.conditional).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    /// ModuleConfig.xml's text. A file whose declared encoding is wrong (common: "UTF-16"
    /// on a UTF-8 file) is read again as the text it really is.
    static func parse(_ data: Data) throws -> FomodConfig {
        if let root = ModXMLTree.parse(data), root.name == "config" { return try parse(root) }
        var text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16) }
        text = text ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        guard var body = text else { throw ModError.badInstaller("not text") }
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        if let range = body.range(of: "?>"), body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<?xml") {
            body = String(body[range.upperBound...])
        }
        guard let root = ModXMLTree.parse(Data(body.utf8)) else { throw ModError.badInstaller("not XML") }
        guard root.name == "config" else { throw ModError.badInstaller("no <config>") }
        return try parse(root)
    }

    private static func ordered<T>(_ list: [T], _ order: String?, name: (T) -> String) -> [T] {
        // The schema's default order is Ascending: by name. Most installers say Explicit.
        switch (order ?? "ascending").lowercased() {
        case "explicit": return list
        case "descending": return list.sorted { name($0).localizedStandardCompare(name($1)) == .orderedDescending }
        default: return list.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        }
    }

    static func items(_ node: ModXMLNode?) -> [FomodItem] {
        guard let node else { return [] }
        return node.children.compactMap { child in
            guard child.name == "file" || child.name == "folder", let source = child.attr("source") else { return nil }
            let folder = child.name == "folder"
            var destination = child.attr("destination") ?? source
            // A file's empty destination is the folder's top, under its own name.
            if !folder && (destination.isEmpty || destination.hasSuffix("/") || destination.hasSuffix("\\")) {
                destination += source.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? source
            }
            return FomodItem(source: source, destination: destination, priority: Int(child.attr("priority") ?? "") ?? 0, folder: folder)
        }
    }

    static func condition(_ node: ModXMLNode) -> FomodCondition {
        var parts: [FomodCondition] = []
        for child in node.children {
            switch child.name {
            case "flagdependency": parts.append(.flag(child.attr("flag") ?? "", child.attr("value") ?? ""))
            case "filedependency": parts.append(.file(child.attr("file") ?? "", (child.attr("state") ?? "active").lowercased()))
            case "dependencies": parts.append(condition(child))
            default: parts.append(.always)   // game, FOMM and script extender versions: not checked
            }
        }
        return (node.attr("operator") ?? "and").lowercased() == "or" ? .any(parts) : .all(parts)
    }

    private static func parse(_ root: ModXMLNode) throws -> FomodConfig {
        let name = root.child("modulename")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var steps: [FomodStep] = []
        if let list = root.child("installsteps") {
            let parsed: [FomodStep] = list.all("installstep").map { step in
                let groupsNode = step.child("optionalfilegroups")
                let groups: [FomodGroup] = (groupsNode?.all("group") ?? []).map { group in
                    let pluginsNode = group.child("plugins")
                    let plugins: [FomodPlugin] = (pluginsNode?.all("plugin") ?? []).map { plugin in
                        var kind = FomodPluginKind.optional
                        var patterns: [(FomodCondition, FomodPluginKind)] = []
                        if let descriptor = plugin.child("typedescriptor") {
                            if let type = descriptor.child("type") { kind = FomodPluginKind(type.attr("name")) }
                            if let dependent = descriptor.child("dependencytype") {
                                kind = FomodPluginKind(dependent.child("defaulttype")?.attr("name"))
                                for pattern in dependent.child("patterns")?.all("pattern") ?? [] {
                                    guard let deps = pattern.child("dependencies") else { continue }
                                    patterns.append((condition(deps), FomodPluginKind(pattern.child("type")?.attr("name"))))
                                }
                            }
                        }
                        let flags = (plugin.child("conditionflags")?.all("flag") ?? []).map {
                            FomodFlag(name: $0.attr("name") ?? "", value: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        return FomodPlugin(name: plugin.attr("name") ?? "",
                                           description: plugin.child("description")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                           image: plugin.child("image")?.attr("path"), items: items(plugin.child("files")),
                                           flags: flags, kind: kind, patterns: patterns)
                    }
                    return FomodGroup(name: group.attr("name") ?? "", kind: FomodGroupKind(rawValue: (group.attr("type") ?? "").lowercased()) ?? .any,
                                      plugins: ordered(plugins, pluginsNode?.attr("order")) { $0.name })
                }
                return FomodStep(name: step.attr("name") ?? "", visible: step.child("visible").map(condition),
                                 groups: ordered(groups, groupsNode?.attr("order")) { $0.name })
            }
            steps = ordered(parsed, list.attr("order")) { $0.name }
        }
        var conditional: [(FomodCondition, [FomodItem])] = []
        for pattern in root.child("conditionalfileinstalls")?.child("patterns")?.all("pattern") ?? [] {
            guard let deps = pattern.child("dependencies") else { continue }
            conditional.append((condition(deps), items(pattern.child("files"))))
        }
        let config = FomodConfig(moduleName: name, required: items(root.child("requiredinstallfiles")), steps: steps, conditional: conditional)
        guard !config.required.isEmpty || !config.steps.isEmpty || !config.conditional.isEmpty else { throw ModError.badInstaller("it installs nothing") }
        return config
    }
}

/// The choices on a FOMOD installer's pages: which plugin of each group is picked, the
/// flags they set, which pages show, and the files that follow.
struct FomodChoices {
    let config: FomodConfig
    /// selected[step][group]: the picked plugins' indexes.
    var selected: [[Set<Int>]]
    private var prepared: Set<Int> = []
    let fileState: (String) -> String

    init(_ config: FomodConfig, fileState: @escaping (String) -> String = { _ in "missing" }) {
        self.config = config
        self.fileState = fileState
        selected = config.steps.map { $0.groups.map { _ in [] } }
    }

    /// The flags set by the pages before `step` that show.
    func flags(before step: Int) -> [String: String] {
        var flags: [String: String] = [:]
        for index in 0..<min(step, config.steps.count) where visible(index, flags) {
            for (g, group) in config.steps[index].groups.enumerated() {
                for p in selected[index][g].sorted() {
                    for flag in group.plugins[p].flags { flags[flag.name.lowercased()] = flag.value }
                }
            }
        }
        return flags
    }

    var finalFlags: [String: String] { flags(before: config.steps.count) }

    private func visible(_ step: Int, _ flags: [String: String]) -> Bool {
        config.steps[step].visible?.holds(flags, fileState: fileState) ?? true
    }

    func isVisible(_ step: Int) -> Bool { visible(step, flags(before: step)) }

    /// The next page that shows after `step` (-1: from the start), or nil.
    func next(after step: Int) -> Int? {
        var index = step + 1
        while index < config.steps.count {
            if isVisible(index) { return index }
            index += 1
        }
        return nil
    }

    func previous(before step: Int) -> Int? {
        var index = step - 1
        while index >= 0 {
            if isVisible(index) { return index }
            index -= 1
        }
        return nil
    }

    func kind(_ step: Int, _ group: Int, _ plugin: Int) -> FomodPluginKind {
        config.steps[step].groups[group].plugins[plugin].kind(flags(before: step), fileState: fileState)
    }

    /// Picks each group's starting choices the first time its page shows: the required
    /// and recommended ones, and for a group that needs one, the first that can be used.
    mutating func prepare(_ step: Int) {
        guard step >= 0, step < config.steps.count, !prepared.contains(step) else { return }
        prepared.insert(step)
        for (g, group) in config.steps[step].groups.enumerated() {
            let kinds = group.plugins.indices.map { kind(step, g, $0) }
            let usable = group.plugins.indices.filter { kinds[$0] != .notUsable }
            let wanted = usable.filter { kinds[$0] == .required || kinds[$0] == .recommended }
            var pick: Set<Int>
            switch group.kind {
            case .all: pick = Set(usable)
            case .exactlyOne: pick = Set((wanted.first ?? usable.first).map { [$0] } ?? [])
            case .atMostOne: pick = Set(wanted.first.map { [$0] } ?? [])
            case .atLeastOne: pick = wanted.isEmpty ? Set(usable.prefix(1)) : Set(wanted)
            case .any: pick = Set(wanted)
            }
            selected[step][g] = pick
        }
    }

    /// Whether the plugin's choice can change on its page.
    func locked(_ step: Int, _ group: Int, _ plugin: Int) -> Bool {
        let type = self.kind(step, group, plugin)
        let picked = selected[step][group].contains(plugin)
        return type == .notUsable || config.steps[step].groups[group].kind == .all || (type == .required && picked)
    }

    mutating func toggle(_ step: Int, _ group: Int, _ plugin: Int) {
        guard !locked(step, group, plugin) else { return }
        let kind = config.steps[step].groups[group].kind
        var picked = selected[step][group]
        let on = picked.contains(plugin)
        switch kind {
        case .exactlyOne: picked = [plugin]
        case .atMostOne: picked = on ? [] : [plugin]
        case .atLeastOne: if on { if picked.count > 1 { picked.remove(plugin) } } else { picked.insert(plugin) }
        case .any: if on { picked.remove(plugin) } else { picked.insert(plugin) }
        case .all: break
        }
        // A required plugin of a single-choice group stays.
        if kind.single, let required = config.steps[step].groups[group].plugins.indices.first(where: { self.kind(step, group, $0) == .required }) {
            picked = [required]
        }
        selected[step][group] = picked
    }

    /// What the choices install: the required files, the picked plugins' on the pages
    /// that show, and the conditional files whose flags hold; in priority order (a
    /// later item wins over an earlier one for the same file).
    var items: [FomodItem] {
        var list = config.required
        for (s, step) in config.steps.enumerated() where isVisible(s) {
            for (g, group) in step.groups.enumerated() {
                for p in selected[s][g].sorted() { list += group.plugins[p].items }
            }
        }
        let flags = finalFlags
        for (condition, items) in config.conditional where condition.holds(flags, fileState: fileState) { list += items }
        return list.enumerated().sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }.map(\.element)
    }

    /// The files to copy: destination (relative) and the mod's file, a later item winning.
    /// `root` is the folder that holds fomod/.
    func plan(root: URL) throws -> [(destination: String, source: URL)] {
        var out: [String: (String, URL)] = [:]
        for item in items {
            guard let source = ModPath.clean(item.source) else { throw ModError.outside(item.source) }
            let url = root.appendingPathComponent(ModPath.existing(source, under: root))
            guard FileManager.default.fileExists(atPath: url.path) else { throw ModError.missingSource(item.source) }
            let destination = item.destination.trimmingCharacters(in: .whitespaces)
            if item.folder {
                let base = destination.isEmpty ? "" : (ModPath.clean(destination) ?? "\u{0}")
                guard base != "\u{0}" else { throw ModError.outside(destination) }
                for file in try ModPath.files(in: url) {
                    let target = base.isEmpty ? file : base + "/" + file
                    out[target.lowercased()] = (target, url.appendingPathComponent(file))
                }
            } else {
                guard let target = ModPath.clean(destination) else { throw ModError.outside(destination) }
                out[target.lowercased()] = (target, url)
            }
        }
        return out.values.sorted { $0.0 < $1.0 }.map { (destination: $0.0, source: $0.1) }
    }
}

// MARK: Where a mod's files are, where they go

enum ModKind: String, Codable, Equatable {
    case fomod, gameFolder, data, bepinex, plain
}

enum ModLayout {
    static let pluginExtensions: Set<String> = ["esp", "esm", "esl"]
    /// Folders a Bethesda game reads from Data.
    static let dataFolders: Set<String> = ["meshes", "textures", "sound", "music", "scripts", "interface", "menus", "shaders",
                                           "strings", "video", "materials", "lodsettings", "seq", "fonts", "grass", "trees",
                                           "distantlod", "lod", "facegen", "skse", "f4se", "nvse", "fose", "obse", "sounds", "mcm"]
    static let archiveExtensions: Set<String> = ["bsa", "ba2"]

    static func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    static func hasPlugins(_ folder: URL) -> Bool {
        names(folder).contains { pluginExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    static func looksLikeData(_ folder: URL) -> Bool {
        names(folder).contains { name in
            let ext = (name as NSString).pathExtension.lowercased()
            return pluginExtensions.contains(ext) || archiveExtensions.contains(ext)
                || (dataFolders.contains(name.lowercased()) && ModPath.isDirectory(folder.appendingPathComponent(name)))
        }
    }

    static func isBepInEx(_ folder: URL) -> Bool {
        names(folder).contains { ["bepinex", "winhttp.dll", "doorstop_config.ini"].contains($0.lowercased()) }
    }

    static func hasFomod(_ folder: URL) -> URL? {
        guard let fomod = ModPath.child("fomod", of: folder), ModPath.isDirectory(fomod),
              let config = ModPath.child("ModuleConfig.xml", of: fomod) else { return nil }
        return config
    }

    /// The mod's own top folder inside what was unpacked: the folder with
    /// fomod/ModuleConfig.xml, else one with a Data folder, else one with plugins, else
    /// one with BepInEx, else the top (past a lone wrapper folder). The shallowest wins.
    static func find(in folder: URL) -> (root: URL, kind: ModKind, fomod: URL?) {
        var levels: [[URL]] = [[folder]]
        for _ in 0..<4 {
            let next = levels.last!.flatMap { parent in
                names(parent).sorted().map { parent.appendingPathComponent($0) }.filter { ModPath.isDirectory($0) && $0.lastPathComponent.lowercased() != "fomod" }
            }
            if next.isEmpty { break }
            levels.append(next)
        }
        let all = levels.flatMap { $0 }
        if let match = all.lazy.compactMap({ dir in hasFomod(dir).map { (dir, $0) } }).first { return (match.0, .fomod, match.1) }
        if let dir = all.first(where: { dir in ModPath.child("Data", of: dir).map(ModPath.isDirectory) ?? false }) {
            // A Data folder that is itself all the mod has: the folder above holds it.
            return (dir, .gameFolder, nil)
        }
        if let dir = all.first(where: hasPlugins) { return (dir, .data, nil) }
        if let dir = all.first(where: isBepInEx) { return (dir, .bepinex, nil) }
        var top = folder
        while true {
            let inside = names(top)
            guard inside.count == 1 else { break }
            let only = top.appendingPathComponent(inside[0])
            guard ModPath.isDirectory(only), !dataFolders.contains(inside[0].lowercased()) else { break }
            top = only
        }
        return (top, looksLikeData(top) ? .data : .plain, nil)
    }

    /// Where the mod's files go, relative to the game's folder: "Data" (in the game's own
    /// case) when the game has a Data folder and the mod is made of what Data holds, else
    /// "" (the game's folder).
    static func target(gameFolder: URL, content: URL, kind: ModKind) -> String {
        if kind == .bepinex || kind == .gameFolder { return "" }
        // A mod with its own Data folder goes into the game's folder, its Data on the game's.
        if let own = ModPath.child("Data", of: content), ModPath.isDirectory(own) { return "" }
        guard let data = ModPath.child("Data", of: gameFolder), ModPath.isDirectory(data) else { return "" }
        return kind == .fomod || kind == .data || looksLikeData(content) ? data.lastPathComponent : ""
    }
}

// MARK: Bethesda games

enum BethesdaGame: String, Codable, CaseIterable {
    case falloutNV, fallout3, oblivion, skyrim, skyrimSE, fallout4

    var appIDs: [Int] {
        switch self {
        case .falloutNV: return [22380]
        case .fallout3: return [22300, 22370]
        case .oblivion: return [22330]
        case .skyrim: return [72850]
        case .skyrimSE: return [489830]
        case .fallout4: return [377160]
        }
    }
    var programs: [String] {
        switch self {
        case .falloutNV: return ["FalloutNV.exe"]
        case .fallout3: return ["Fallout3.exe"]
        case .oblivion: return ["Oblivion.exe"]
        case .skyrim: return ["TESV.exe"]
        case .skyrimSE: return ["SkyrimSE.exe"]
        case .fallout4: return ["Fallout4.exe"]
        }
    }
    /// AppData/Local/<this>/plugins.txt, and My Games/<this> for the .ini.
    var folder: String {
        switch self {
        case .falloutNV: return "FalloutNV"
        case .fallout3: return "Fallout3"
        case .oblivion: return "Oblivion"
        case .skyrim: return "Skyrim"
        case .skyrimSE: return "Skyrim Special Edition"
        case .fallout4: return "Fallout4"
        }
    }
    /// Skyrim Special Edition and Fallout 4 list every plugin, a "*" in front of those that are on.
    var starred: Bool { self == .skyrimSE || self == .fallout4 }
    /// The game's own master, which the older games want at the top of a new plugins.txt.
    var master: String {
        switch self {
        case .falloutNV: return "FalloutNV.esm"
        case .fallout3: return "Fallout3.esm"
        case .oblivion: return "Oblivion.esm"
        case .skyrim: return "Skyrim.esm"
        case .skyrimSE: return "Skyrim.esm"
        case .fallout4: return "Fallout4.esm"
        }
    }
    /// Fallout NV and 3 read loose files over their .bsa only with this switch in Fallout.ini.
    var needsInvalidation: Bool { self == .falloutNV || self == .fallout3 }

    static func detect(steamAppID: Int?, program: String?, gameFolder: URL?) -> BethesdaGame? {
        if let id = steamAppID, let game = allCases.first(where: { $0.appIDs.contains(id) }) { return game }
        if let program, let game = allCases.first(where: { $0.programs.contains { $0.caseInsensitiveCompare(program) == .orderedSame } }) { return game }
        if let gameFolder {
            let names = ModLayout.names(gameFolder)
            return allCases.first { game in game.programs.contains { p in names.contains { $0.caseInsensitiveCompare(p) == .orderedSame } } }
        }
        return nil
    }
}

enum PluginsTxt {
    private static func newline(_ text: String) -> String { text.contains("\r\n") || text.isEmpty ? "\r\n" : "\n" }
    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.isEmpty }
    }
    private static func bare(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("*") ? String(t.dropFirst()) : t
    }
    private static func isMaster(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "esm" || ext == "esl"
    }

    /// plugins.txt with `names` on (masters with the masters, the rest at the end);
    /// `text` nil: a new file, which the older games start with their own master.
    static func adding(_ names: [String], to text: String?, game: BethesdaGame) -> String {
        var list = lines(text ?? "")
        if text == nil, !game.starred { list = [game.master] }
        let nl = newline(text ?? "")
        for name in names.sorted(by: { isMaster($0) && !isMaster($1) }) {
            let entry = game.starred ? "*" + name : name
            if let i = list.firstIndex(where: { !$0.hasPrefix("#") && bare($0).caseInsensitiveCompare(name) == .orderedSame }) {
                list[i] = entry
                continue
            }
            if isMaster(name), let i = list.firstIndex(where: { !$0.hasPrefix("#") && !isMaster(bare($0)) }) {
                list.insert(entry, at: i)
            } else {
                list.append(entry)
            }
        }
        return list.joined(separator: nl) + nl
    }

    static func removing(_ names: [String], from text: String, game: BethesdaGame) -> String {
        let nl = newline(text)
        let list = lines(text).filter { line in
            line.hasPrefix("#") || !names.contains { bare(line).caseInsensitiveCompare($0) == .orderedSame }
        }
        return list.isEmpty ? "" : list.joined(separator: nl) + nl
    }
}

enum IniEdit {
    /// `text` with key=value under [section], every other byte kept: the key's line is
    /// rewritten, or added at the end of the section, or a new section is added.
    static func setting(_ text: String, section: String, key: String, value: String) -> String {
        let nl = text.contains("\r\n") || text.isEmpty ? "\r\n" : "\n"
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }
        var current = ""
        var sectionEnd: Int?
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                if current.caseInsensitiveCompare(section) == .orderedSame { break }
                current = String(line[line.index(after: line.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                if current.caseInsensitiveCompare(section) == .orderedSame { sectionEnd = i + 1 }
                continue
            }
            guard current.caseInsensitiveCompare(section) == .orderedSame else { continue }
            if !line.isEmpty { sectionEnd = i + 1 }
            if let eq = line.firstIndex(of: "="), !line.hasPrefix(";"),
               line[..<eq].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame {
                lines[i] = key + "=" + value
                return lines.joined(separator: nl) + (endsWithNewline ? nl : "")
            }
        }
        if let end = sectionEnd {
            lines.insert(key + "=" + value, at: end)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines += ["[" + section + "]", key + "=" + value]
        }
        return lines.joined(separator: nl) + (endsWithNewline || sectionEnd == nil ? nl : "")
    }
}

/// The line in the game's own config (GameProfiles.swift) that lets BepInEx load:
/// Wine takes the mod's winhttp.dll before its own.
enum ModConfigLines {
    static let note = "# Mods: BepInEx loads through the game's winhttp.dll (taken out when no BepInEx mod is on)"
    static let entry = "winhttp=n,b"
    private static let key = "env.WINEDLLOVERRIDES"

    private static func overrideLine(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let eq = t.firstIndex(of: "="), t[..<eq].trimmingCharacters(in: .whitespaces) == key else { return nil }
        return t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    }

    /// The config with winhttp=n,b, and whether it was added (false: winhttp was set already).
    static func adding(_ text: String) -> (text: String, added: Bool) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if let i = lines.lastIndex(where: { overrideLine($0) != nil }), let value = overrideLine(lines[i]) {
            let entries = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            if entries.contains(where: { $0.lowercased().hasPrefix("winhttp=") || $0.lowercased().hasPrefix("winhttp,") }) { return (text, false) }
            lines[i] = key + " = " + (entries.filter { !$0.isEmpty } + [entry]).joined(separator: ";")
        } else {
            lines += [note, key + " = " + entry]
        }
        return (lines.joined(separator: "\n") + "\n", true)
    }

    static func removing(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for i in lines.indices.reversed() {
            guard let value = overrideLine(lines[i]) else { continue }
            let rest = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != entry }
            if rest.isEmpty { lines.remove(at: i) } else { lines[i] = key + " = " + rest.joined(separator: ";") }
        }
        lines.removeAll { $0 == note }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

// MARK: Turning mods on and off

struct ModRecord: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var enabled: Bool
    /// Install order: a later mod wins a file over an earlier one.
    var order: Int
    /// The files to copy, relative to the game's mod store.
    var content: String
    /// Where they go, relative to the game's folder ("" or "Data").
    var target: String
    var kind: ModKind
    /// Its .esp/.esm/.esl files (in Data), for plugins.txt.
    var plugins: [String]
    var bepinex: Bool
}

struct ModDeployedFile: Codable, Equatable {
    /// The file, relative to the game's folder, in the case it has on disk.
    var path: String
    /// The game's own file it replaced, in backups/; nil when nothing was there.
    var backup: String?
    /// The mods that have this file, in install order (the last one's is on disk),
    /// and each one's file inside its content.
    var owners: [String]
    var sources: [String: String]
}

struct ModManifest: Codable, Equatable {
    var version = 1
    var mods: [ModRecord] = []
    /// Keyed by the lower-case path.
    var files: [String: ModDeployedFile] = [:]
    /// Folders a mod made in the game's folder (taken out again once empty).
    var folders: [String] = []
    /// The config line BepInEx needs was added by Mods.
    var addedOverride = false
    /// plugins.txt files Mods made (relative to drive_c), and .ini files it backed up.
    var madePluginLists: [String] = []
    var iniBackups: [String] = []
}

/// What Mods touches for one game.
struct ModGame {
    var id: String
    var gameFolder: URL
    /// drive_c, for plugins.txt and Fallout.ini.
    var drive: URL
    /// The game's program, relative to its folder, when known.
    var program: String?
    var bethesda: BethesdaGame?
    var readConfig: () -> String
    var writeConfig: (String) -> Void
}

final class ModStore {
    let folder: URL
    let game: ModGame
    private(set) var manifest: ModManifest
    /// Things to tell the person after a change ("play once, then…").
    private(set) var notes: [String] = []

    var manifestURL: URL { folder.appendingPathComponent("mods.json") }
    var backups: URL { folder.appendingPathComponent("backups", isDirectory: true) }

    init(folder: URL, game: ModGame) {
        self.folder = folder
        self.game = game
        let url = folder.appendingPathComponent("mods.json")
        manifest = (try? JSONDecoder().decode(ModManifest.self, from: Data(contentsOf: url))) ?? ModManifest()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    var mods: [ModRecord] { manifest.mods.sorted { $0.order < $1.order } }
    func contentURL(_ mod: ModRecord) -> URL { folder.appendingPathComponent(mod.content, isDirectory: true) }
    func modFolder(_ id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }

    /// A new mod's record, after the others; not on yet.
    @discardableResult
    func add(id: String, name: String, content: String, target: String, kind: ModKind) throws -> ModRecord {
        let url = folder.appendingPathComponent(content, isDirectory: true)
        func plugins(_ folder: URL) -> [String] {
            ModLayout.names(folder).filter { ModLayout.pluginExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        }
        // Plugins are at the top of a mod that goes into Data, or in a mod's own Data folder.
        let list = target.isEmpty ? (ModPath.child("Data", of: url).map(plugins) ?? []) : plugins(url)
        let record = ModRecord(id: id, name: name, enabled: false, order: (manifest.mods.map(\.order).max() ?? 0) + 1,
                               content: content, target: target, kind: kind, plugins: list.sorted(),
                               bepinex: ModLayout.isBepInEx(url))
        manifest.mods.append(record)
        try save()
        return record
    }

    private static let valvePrefixes = ["steam_api", "steamclient", "tier0_s", "vstdlib_s", "gameoverlayrenderer", "steamwebhelper",
                                        "steamerrorreporter", "steamservice", "openvr_api", "steam."]

    /// Stops a file that may not be written, before anything is.
    func guardFile(_ relative: String) throws {
        let name = (relative as NSString).lastPathComponent
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ["dll", "exe", "so", "dylib"].contains(ext), Self.valvePrefixes.contains(where: { lower.hasPrefix($0) }) {
            throw ModError.valveFile(name)
        }
        if ext == "exe" {
            let actual = ModPath.existing(relative, under: game.gameFolder)
            let tracked = manifest.files[relative.lowercased()] != nil
            if let program = game.program, program.caseInsensitiveCompare(actual) == .orderedSame { throw ModError.gameProgram(name) }
            if !tracked, FileManager.default.fileExists(atPath: game.gameFolder.appendingPathComponent(actual).path) {
                throw ModError.gameProgram(name)
            }
        }
        guard ModPath.inside(game.gameFolder.appendingPathComponent(ModPath.existing(relative, under: game.gameFolder)), game.gameFolder) else {
            throw ModError.outside(relative)
        }
    }

    /// The mod's files: (relative to the game's folder, inside its content).
    func files(of mod: ModRecord) throws -> [(String, String)] {
        let content = contentURL(mod)
        let list = try ModPath.files(in: content).filter { !$0.lowercased().hasPrefix("fomod/") }
        return list.map { (mod.target.isEmpty ? $0 : mod.target + "/" + $0, $0) }
    }

    private func put(_ source: URL, at relative: String) throws {
        let fm = FileManager.default
        let target = game.gameFolder.appendingPathComponent(relative)
        // Folders the game did not have are noted, to go again when empty.
        var made: [String] = []
        var parent = target.deletingLastPathComponent()
        while !fm.fileExists(atPath: parent.path), parent.path.count > game.gameFolder.path.count {
            made.append(String(parent.standardizedFileURL.path.dropFirst(game.gameFolder.standardizedFileURL.path.count + 1)))
            parent = parent.deletingLastPathComponent()
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        for folder in made where !manifest.folders.contains(folder) { manifest.folders.append(folder) }
        if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            try fm.removeItem(at: target)
        }
        try fm.copyItem(at: source, to: target)
    }

    /// Turns a mod on: its files into the game's folder, the originals they replace
    /// backed up first; then plugins.txt, Fallout.ini and the BepInEx line.
    func enable(_ id: String, progress: (Int, Int) -> Void = { _, _ in }) throws {
        guard let index = manifest.mods.firstIndex(where: { $0.id == id }) else { return }
        notes = []
        let mod = manifest.mods[index]
        let list = try files(of: mod)
        guard !list.isEmpty else { throw ModError.noFiles }
        for (relative, _) in list { try guardFile(relative) }
        let fm = FileManager.default
        let orders = Dictionary(manifest.mods.map { ($0.id, $0.order) }, uniquingKeysWith: { a, _ in a })
        do {
            for (n, (relative, inside)) in list.enumerated() {
                let key = relative.lowercased()
                var state: ModDeployedFile
                if let known = manifest.files[key] {
                    state = known
                } else {
                    let actual = ModPath.existing(relative, under: game.gameFolder)
                    state = ModDeployedFile(path: actual, backup: nil, owners: [], sources: [:])
                    let current = game.gameFolder.appendingPathComponent(actual)
                    if fm.fileExists(atPath: current.path) {
                        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
                        let name = UUID().uuidString + "-" + current.lastPathComponent
                        try fm.moveItem(at: current, to: backups.appendingPathComponent(name))
                        state.backup = name
                    }
                    manifest.files[key] = state
                }
                state.owners.removeAll { $0 == id }
                state.owners.append(id)
                state.owners.sort { (orders[$0] ?? 0) < (orders[$1] ?? 0) }
                state.sources[id] = inside
                manifest.files[key] = state
                if state.owners.last == id { try put(contentURL(mod).appendingPathComponent(inside), at: state.path) }
                if n % 50 == 0 { progress(n, list.count) }
            }
            manifest.mods[index].enabled = true
            try save()
        } catch {
            // Half on is not on: what was written goes again.
            try? disable(id)
            throw error
        }
        progress(list.count, list.count)
        try? updatePlugins(mod, on: true)
        // Loose files (a texture mod, no plugin) need the switch as much as plugins do.
        if let bethesda = game.bethesda, bethesda.needsInvalidation, !mod.target.isEmpty || mod.kind == .gameFolder {
            try? invalidateOlderFiles(bethesda)
        }
        updateConfig()
        try save()
    }

    /// Turns a mod off: its files out, and where another mod that is on has the same
    /// file, that one's back; where none has, the game's own file is back.
    func disable(_ id: String) throws {
        guard let index = manifest.mods.firstIndex(where: { $0.id == id }) else { return }
        notes = []
        let fm = FileManager.default
        let mods = Dictionary(manifest.mods.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, var state) in manifest.files where state.owners.contains(id) {
            let wasOn = state.owners.last == id
            state.owners.removeAll { $0 == id }
            state.sources[id] = nil
            let target = game.gameFolder.appendingPathComponent(state.path)
            if state.owners.isEmpty {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                if let backup = state.backup {
                    try fm.moveItem(at: backups.appendingPathComponent(backup), to: target)
                }
                manifest.files[key] = nil
            } else {
                if wasOn, let top = state.owners.last, let mod = mods[top], let inside = state.sources[top] {
                    try put(contentURL(mod).appendingPathComponent(inside), at: state.path)
                }
                manifest.files[key] = state
            }
        }
        // Folders a mod made, deepest first, once nothing is left in them.
        for folder in manifest.folders.sorted(by: { $0.count > $1.count }) {
            let url = game.gameFolder.appendingPathComponent(folder)
            if ((try? fm.contentsOfDirectory(atPath: url.path)) ?? ["?"]).isEmpty {
                try? fm.removeItem(at: url)
                manifest.folders.removeAll { $0 == folder }
            } else if !fm.fileExists(atPath: url.path) {
                manifest.folders.removeAll { $0 == folder }
            }
        }
        let mod = manifest.mods[index]
        manifest.mods[index].enabled = false
        try? updatePlugins(mod, on: false)
        updateConfig()
        try save()
    }

    /// Off, then its unpacked files and its record go.
    func remove(_ id: String) throws {
        guard manifest.mods.contains(where: { $0.id == id }) else { return }
        try disable(id)
        try? FileManager.default.removeItem(at: modFolder(id))
        manifest.mods.removeAll { $0.id == id }
        try save()
    }

    // MARK: plugins.txt, Fallout.ini, the BepInEx line

    /// The prefix's users (not Public), relative to drive_c.
    private var users: [String] {
        let base = game.drive.appendingPathComponent("users")
        return ModLayout.names(base).filter { $0.caseInsensitiveCompare("Public") != .orderedSame && ModPath.isDirectory(base.appendingPathComponent($0)) }
            .sorted().map { "users/" + $0 }
    }

    private func updatePlugins(_ mod: ModRecord, on: Bool) throws {
        guard let bethesda = game.bethesda, !mod.plugins.isEmpty else { return }
        let fm = FileManager.default
        for user in users {
            let relative = user + "/AppData/Local/" + bethesda.folder + "/plugins.txt"
            let url = game.drive.appendingPathComponent(ModPath.existing(relative, under: game.drive))
            let old = try? String(contentsOf: url, encoding: .utf8)
            if on {
                if old == nil { manifest.madePluginLists.append(relative) }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PluginsTxt.adding(mod.plugins, to: old, game: bethesda).write(to: url, atomically: true, encoding: .utf8)
            } else if let old {
                let text = PluginsTxt.removing(mod.plugins, from: old, game: bethesda)
                let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") }
                if manifest.madePluginLists.contains(relative), lines.isEmpty || lines == [bethesda.master] {
                    try fm.removeItem(at: url)
                    manifest.madePluginLists.removeAll { $0 == relative }
                } else {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// Fallout NV and 3: loose files win over the .bsa only with bInvalidateOlderFiles=1.
    private func invalidateOlderFiles(_ bethesda: BethesdaGame) throws {
        let fm = FileManager.default
        var found = false
        for user in users {
            let relative = user + "/Documents/My Games/" + bethesda.folder + "/Fallout.ini"
            let url = game.drive.appendingPathComponent(ModPath.existing(relative, under: game.drive))
            guard let data = try? Data(contentsOf: url) else { continue }
            found = true
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            var edited = IniEdit.setting(text, section: "Archive", key: "bInvalidateOlderFiles", value: "1")
            edited = IniEdit.setting(edited, section: "Archive", key: "SInvalidationFile", value: "")
            guard edited != text else { continue }
            if !manifest.iniBackups.contains(relative) {
                try fm.createDirectory(at: backups, withIntermediateDirectories: true)
                let name = relative.replacingOccurrences(of: "/", with: "_")
                if !fm.fileExists(atPath: backups.appendingPathComponent(name).path) {
                    try fm.copyItem(at: url, to: backups.appendingPathComponent(name))
                }
                manifest.iniBackups.append(relative)
            }
            try edited.write(to: url, atomically: true, encoding: .utf8)
        }
        if !found { notes.append("ini-missing") }
    }

    /// The BepInEx line is in the game's config while a BepInEx mod is on.
    private func updateConfig() {
        let wanted = manifest.mods.contains { $0.enabled && $0.bepinex }
        if wanted && !manifest.addedOverride {
            let result = ModConfigLines.adding(game.readConfig())
            if result.added { game.writeConfig(result.text); manifest.addedOverride = true }
        } else if !wanted && manifest.addedOverride {
            game.writeConfig(ModConfigLines.removing(game.readConfig()))
            manifest.addedOverride = false
        }
    }
}
