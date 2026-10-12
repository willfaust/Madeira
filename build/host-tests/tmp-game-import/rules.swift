// MARK: - Rules

/// One game description from a `.lua` script or a Steam `.manifest`/`.acf`
/// app record, normalized before anything is downloaded, extracted or
/// inspected. `installDir` is the game's folder relative to drive_c; `exe`
/// is relative to that folder.
struct GameImportPlan: Equatable, Sendable {
    enum Source: Equatable, Sendable { case lua, manifest }
    let title: String
    let source: Source
    let installDir: String
    let exe: String?
    /// An https `.zip` address the script carries, downloaded into the
    /// install folder. A manifest never has one.
    let download: URL?
    let appID: Int?

    /// The executable's path relative to drive_c.
    var exeRelative: String? { exe.map { installDir + "/" + $0 } }
}

enum GameImportError: LocalizedError, Equatable {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Parsing and planning rules for importing a game. The `.lua` side is a
/// one-table dialect of our own — `game = { name = "…", exe = "…",
/// installdir = "…", download = "https://….zip", appid = 4242 }` — read with
/// a bounded parser that recognizes only assignments, strings, integers,
/// booleans, nil and nested tables; it never executes anything. The
/// `.manifest` side is Valve's own AppState record. Foundation only, so the
/// host tests compile this section as is.
enum GameImportRules {
    static let maxScriptBytes = 1 << 20

    // MARK: descriptor parsing

    /// The plan a descriptor file describes, by extension.
    static func plan(data: Data, fileName: String) throws -> GameImportPlan {
        let ext = fileName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        switch ext {
        case "lua": return try plan(luaScript: data)
        case "manifest", "acf", "vdf": return try plan(manifest: data)
        default: throw GameImportError.message("Choose a .lua script or a Steam .manifest/.acf file.")
        }
    }

    /// The plan a `.lua` script describes. `name` is required; with a
    /// `download` the `exe` may be left out when the archive holds exactly
    /// one executable, and `installdir` defaults to the title made safe.
    static func plan(luaScript: Data) throws -> GameImportPlan {
        var reader = try LuaReader(data: luaScript)
        let top = try reader.document()
        guard let game = top["game"]?.fields else { throw GameImportError.message("The script has no game = { … } table.") }
        guard let name = game["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw GameImportError.message("The script's game table needs a name.")
        }
        let title = String(name.prefix(200))
        let appID = game["appid"]?.number
        if let appID, !(appID > 0 && UInt64(appID) < UInt64(UInt32.max)) {
            throw GameImportError.message("The script's appid is not a Steam App ID.")
        }
        var exe: String?
        if let raw = game["exe"]?.string {
            guard let normalized = relativeExe(raw), normalized.lowercased().hasSuffix(".exe") else {
                throw GameImportError.message("The script's exe must be a Windows path to an .exe file, like game\\bin\\game.exe.")
            }
            exe = normalized
        }
        var download: URL?
        if let raw = game["download"]?.string {
            guard let url = downloadURL(raw) else {
                throw GameImportError.message("The script's download must be an https address to a .zip archive.")
            }
            download = url
        }
        guard exe != nil || download != nil else {
            throw GameImportError.message("The script needs an exe path, or a download to install from.")
        }
        let folder: String
        if let explicit = game["installdir"]?.string {
            guard validFolderName(explicit) else { throw GameImportError.message("The script's installdir must be one folder name under drive_c.") }
            folder = explicit
        } else if download != nil, let safe = folderName(forTitle: title) {
            folder = safe
        } else {
            throw GameImportError.message("The script needs an installdir (one folder name under drive_c).")
        }
        return GameImportPlan(title: title, source: .lua, installDir: folder, exe: exe, download: download, appID: appID)
    }

    /// The plan a Steam `.manifest`/`.acf` app record describes: title and
    /// install folder only — the executable is chosen from the folder.
    static func plan(manifest: Data) throws -> GameImportPlan {
        guard manifest.count <= maxScriptBytes else { throw GameImportError.message("This manifest is too large.") }
        var parser = try SteamKeyValues(manifest)
        let root = try parser.read()
        guard let state = root["AppState"] else { throw GameImportError.message("This file is not a Steam app manifest.") }
        guard let appID = state["appid"]?.string.flatMap({ Int($0) }), appID > 0, UInt64(appID) < UInt64(UInt32.max) else {
            throw GameImportError.message("This manifest's App ID is not valid.")
        }
        guard let folder = state["installdir"]?.string, validFolderName(folder) else {
            throw GameImportError.message("This manifest's installdir is not one folder name.")
        }
        let name = state["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return GameImportPlan(title: name.isEmpty ? "App \(appID)" : String(name.prefix(200)), source: .manifest,
                              installDir: SteamRuntimeFiles.relativeRoot + "/steamapps/common/" + folder,
                              exe: nil, download: nil, appID: appID)
    }

    // MARK: path rules

    /// One folder name: no separators, drive letters, parent references or
    /// control characters (as Dock validates Steam's installdir).
    static func validFolderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 240 && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains(":") && !name.contains("\"") &&
            !name.unicodeScalars.contains { $0.value < 32 } && !name.hasSuffix(" ") && !name.hasSuffix(".")
    }

    /// A relative path of folder names ("steamapps/common/Game"), 1…16 parts.
    static func validRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return (1...16).contains(parts.count) && parts.allSatisfy(validFolderName)
    }

    /// "C:\\Games\\g.exe", "Games\\g.exe" or "Games/g.exe" → "Games/g.exe".
    static func relativeExe(_ raw: String) -> String? {
        var path = raw.replacingOccurrences(of: "\\", with: "/")
        if path.lowercased().hasPrefix("c:/") { path = String(path.dropFirst(3)) }
        while path.hasPrefix("/") { path = String(path.dropFirst()) }
        guard validRelativePath(path) else { return nil }
        return path
    }

    /// The install folder a title stands for: characters a folder name
    /// cannot carry become spaces ("Half-Life: Source" → "Half-Life Source").
    static func folderName(forTitle title: String) -> String? {
        let cleaned = title.unicodeScalars.map { scalar in
            scalar.value < 32 || "/\\:*?\"<>|".unicodeScalars.contains(scalar) ? " " : String(scalar)
        }.joined()
        var name = cleaned.split(separator: " ").joined(separator: " ")
        while name.hasSuffix(".") { name = String(name.dropFirst()) }
        guard name.utf8.count <= 120, validFolderName(name) else { return nil }
        return name
    }

    // MARK: download rules

    /// An https address of a .zip archive: the app's transport security
    /// allows nothing else, and the extractor reads zip only.
    static func downloadURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.path.lowercased().hasSuffix(".zip") else { return nil }
        return url
    }

    // MARK: locating the executable

    /// `.exe` paths under a folder, relative to it, bounded and sorted.
    static func executables(under folder: URL, limit: Int = 1024) -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        var pending = [""]
        while result.count < limit, let relative = pending.popLast() {
            let url = relative.isEmpty ? folder : folder.appendingPathComponent(relative)
            guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { continue }
            for name in names.prefix(256) {
                let child = relative.isEmpty ? name : relative + "/" + name
                if child.split(separator: "/").count > 16 { continue }
                let childURL = url.appendingPathComponent(name)
                if childURL.hasDirectoryPath { pending.append(child) }
                else if name.lowercased().hasSuffix(".exe") { result.append(child) }
            }
        }
        return result.sorted()
    }

    /// The executable to add: the plan's own if it is there, otherwise the
    /// folder's only one. A readable error when there is none or several.
    static func locatedExe(plan: GameImportPlan, drive: URL) throws -> String {
        if let relative = plan.exeRelative,
           FileManager.default.fileExists(atPath: drive.appendingPathComponent(relative).path) {
            return relative
        }
        let found = executables(under: drive.appendingPathComponent(plan.installDir, isDirectory: true))
        guard found.count == 1 else {
            throw GameImportError.message(plan.exe == nil
                ? "The game folder has \(found.count) executables. Add an exe path to the script."
                : "The script's exe is not in the game folder, which has \(found.count) executables.")
        }
        return plan.installDir + "/" + found[0]
    }
}

/// A bounded reader for the one-table Lua dialect import scripts use. It
/// recognizes assignments (with an optional `local` qualifier), strings,
/// integers, booleans, nil and nested tables, and line and block comments;
/// anything else fails with a readable message, as does any file over the
/// size, token, string or depth caps. Nothing is executed.
private struct LuaReader {
    enum Value {
        case text(String)
        case integer(Int)
        case boolean(Bool)
        case nothing
        case table([String: Value])
        var fields: [String: Value] { if case .table(let value) = self { return value }; return [:] }
        var string: String? { if case .text(let value) = self { return value }; return nil }
        var number: Int? { if case .integer(let value) = self { return value }; return nil }
    }

    private let bytes: [UInt8]
    private var position = 0
    private var tokens = 0

    init(data: Data) throws {
        guard data.count <= GameImportRules.maxScriptBytes else { throw GameImportError.message("This script is too large.") }
        bytes = Array(data)
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { position = 3 }
    }

    /// The script's top-level assignments.
    mutating func document() throws -> [String: Value] {
        var fields: [String: Value] = [:]
        while true {
            try skip()
            guard position < bytes.count else { return fields }
            let byte = bytes[position]
            if byte == UInt8(ascii: ";") || byte == UInt8(ascii: ",") { position += 1; continue }
            if word("local") { continue }
            guard let name = try identifier() else { throw unexpected() }
            try skip()
            try expect(UInt8(ascii: "="), hint: "after \"\(name)\"")
            fields[name.lowercased()] = try value(depth: 1)
        }
    }

    private mutating func value(depth: Int) throws -> Value {
        guard depth <= 8 else { throw GameImportError.message("The script is nested too deeply.") }
        try skip()
        guard position < bytes.count else { throw GameImportError.message("The script ends where a value is expected.") }
        try countToken()
        let byte = bytes[position]
        if byte == UInt8(ascii: "{") { position += 1; return .table(try tableFields(depth: depth)) }
        if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") { return .text(try string()) }
        if byte == UInt8(ascii: "-") || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) { return .integer(try number()) }
        if let name = try identifier() {
            switch name.lowercased() {
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            case "nil": return .nothing
            default: throw GameImportError.message("The script uses \"\(name)\", which this importer does not read.")
            }
        }
        throw unexpected()
    }

    private mutating func tableFields(depth: Int) throws -> [String: Value] {
        var fields: [String: Value] = [:]
        while true {
            try skip()
            guard position < bytes.count else { throw GameImportError.message("The script ends inside a table.") }
            if bytes[position] == UInt8(ascii: "}") { position += 1; return fields }
            if bytes[position] == UInt8(ascii: ",") || bytes[position] == UInt8(ascii: ";") { position += 1; continue }
            let saved = position
            if let name = try identifier() {
                try skip()
                if position < bytes.count && bytes[position] == UInt8(ascii: "=") {
                    position += 1
                    fields[name.lowercased()] = try value(depth: depth + 1)
                    continue
                }
                position = saved
            }
            _ = try value(depth: depth + 1)  // a bare value: read and dropped
        }
    }

    private mutating func string() throws -> String {
        let quote = bytes[position]; position += 1
        var value: [UInt8] = []
        while position < bytes.count {
            let byte = bytes[position]; position += 1
            if byte == quote { return String(decoding: value, as: UTF8.self) }
            if byte == UInt8(ascii: "\\") {
                guard position < bytes.count else { break }
                let escape = bytes[position]; position += 1
                switch escape {
                case UInt8(ascii: "a"): value.append(7)
                case UInt8(ascii: "b"): value.append(8)
                case UInt8(ascii: "f"): value.append(12)
                case UInt8(ascii: "n"): value.append(10)
                case UInt8(ascii: "r"): value.append(13)
                case UInt8(ascii: "t"): value.append(9)
                case UInt8(ascii: "v"): value.append(11)
                case UInt8(ascii: "\n"): break
                case UInt8(ascii: "\r"):
                    if position < bytes.count, bytes[position] == UInt8(ascii: "\n") { position += 1 }
                default:
                    if escape >= UInt8(ascii: "0") && escape <= UInt8(ascii: "9") {
                        var digits = String(UnicodeScalar(escape))
                        while digits.count < 3, position < bytes.count,
                              bytes[position] >= UInt8(ascii: "0"), bytes[position] <= UInt8(ascii: "9") {
                            digits.append(String(UnicodeScalar(bytes[position]))); position += 1
                        }
                        guard let code = UInt8(digits) else { throw GameImportError.message("The script has an invalid character code.") }
                        value.append(code)
                    } else {
                        value.append(escape)
                    }
                }
            } else {
                value.append(byte)
            }
            guard value.count <= 16_384 else { throw GameImportError.message("The script contains an oversized value.") }
        }
        throw GameImportError.message("The script ends inside a text value.")
    }

    private mutating func number() throws -> Int {
        var text = ""
        if position < bytes.count, bytes[position] == UInt8(ascii: "-") { text = "-"; position += 1 }
        guard position < bytes.count, bytes[position] >= UInt8(ascii: "0"), bytes[position] <= UInt8(ascii: "9") else { throw unexpected() }
        while position < bytes.count, bytes[position] >= UInt8(ascii: "0"), bytes[position] <= UInt8(ascii: "9") {
            text.append(String(UnicodeScalar(bytes[position]))); position += 1
            guard text.count <= 19 else { throw GameImportError.message("The script has an out-of-range number.") }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") || bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            throw GameImportError.message("The script's numbers must be whole numbers.")
        }
        guard let value = Int(text) else { throw GameImportError.message("The script has an out-of-range number.") }
        return value
    }

    private mutating func identifier() throws -> String? {
        guard position < bytes.count else { return nil }
        let first = bytes[position]
        guard (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z")) || (first >= UInt8(ascii: "A") && first <= UInt8(ascii: "Z")) || first == UInt8(ascii: "_") else { return nil }
        var name = String(UnicodeScalar(first)); position += 1
        while position < bytes.count {
            let byte = bytes[position]
            if (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "_") {
                name.append(String(UnicodeScalar(byte))); position += 1
                guard name.count <= 128 else { throw GameImportError.message("The script has an oversized name.") }
            } else { break }
        }
        return name
    }

    private mutating func word(_ text: String) -> Bool {
        let saved = position
        guard let name = try? identifier(), name.lowercased() == text else {
            position = saved
            return false
        }
        return true
    }

    private mutating func expect(_ byte: UInt8, hint: String) throws {
        guard position < bytes.count, bytes[position] == byte else {
            throw GameImportError.message("The script is missing an = \(hint).")
        }
        position += 1
    }

    private mutating func skip() throws {
        while position < bytes.count {
            let byte = bytes[position]
            if byte <= 32 { position += 1; continue }
            if byte == UInt8(ascii: "-"), position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "-") {
                if position + 3 < bytes.count, bytes[position + 2] == UInt8(ascii: "["), bytes[position + 3] == UInt8(ascii: "[") {
                    var index = position + 4
                    while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "]") && bytes[index + 1] == UInt8(ascii: "]")) { index += 1 }
                    guard index + 1 < bytes.count else { throw GameImportError.message("The script has an unterminated comment.") }
                    position = index + 2
                } else {
                    while position < bytes.count, bytes[position] != UInt8(ascii: "\n") { position += 1 }
                }
                continue
            }
            return
        }
    }

    private mutating func countToken() throws {
        tokens += 1
        guard tokens <= 20_000 else { throw GameImportError.message("The script has too many entries.") }
    }

    private func unexpected() -> GameImportError {
        .message("The script has a character this importer does not read.")
    }
}

