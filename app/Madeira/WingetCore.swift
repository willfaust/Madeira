// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import SQLite3
#if canImport(CryptoKit)
import CryptoKit
#endif

// The winget source without Wine: the index (a SQLite file in source2.msix), a package's version
// list (versionData.mszyml: a header, "CK", raw DEFLATE of YAML) and its merged manifest (YAML).
// Foundation, SQLite3 and CryptoKit only, so tests/host/check-winget.py compiles it.
// Every file is pinned by the one before: index row hash = sha256(versionData),
// version s256H = sha256(manifest), installer InstallerSha256 = sha256(download).

func wingetSHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: YAML subset (what merged manifests use: maps, lists, scalars, block scalars)

indirect enum WingetYAML {
    case scalar(String), map([String: WingetYAML]), list([WingetYAML])

    var string: String? { if case .scalar(let s) = self { return s }; return nil }
    var items: [WingetYAML] { if case .list(let l) = self { return l }; return [] }
    subscript(key: String) -> WingetYAML? { if case .map(let m) = self { return m[key] }; return nil }

    static func parse(_ text: String) -> WingetYAML? {
        var rows: [Row] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw), trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" { continue }
            rows.append(Row(indent: line.prefix { $0 == " " }.count, text: trimmed))
        }
        guard let first = rows.first else { return nil }
        var parser = Parser(rows: rows)
        return parser.node(first.indent)
    }

    fileprivate struct Row { var indent: Int; var text: String }

    fileprivate struct Parser {
        var rows: [Row]
        var i = 0
        init(rows: [Row]) { self.rows = rows }

        static func isDash(_ t: String) -> Bool { t == "-" || t.hasPrefix("- ") }

        /// "Key: value" -> (Key, value); nil when the line is not a key (a scalar, a flow value).
        static func split(_ t: String) -> (String, String)? {
            guard let first = t.first, first != "\"", first != "'", first != "[", first != "{" else { return nil }
            if t.hasSuffix(":") { return (String(t.dropLast()), "") }
            guard let r = t.range(of: ": ") else { return nil }
            return (String(t[..<r.lowerBound]), String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces))
        }

        static func unquote(_ s: String) -> String {
            if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") { return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
            if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
                return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\\", with: "\\")
            }
            return s
        }

        mutating func node(_ indent: Int) -> WingetYAML {
            guard i < rows.count else { return .scalar("") }
            let t = rows[i].text
            if Self.isDash(t) { return list(indent) }
            if Self.split(t) != nil { return map(indent) }
            i += 1
            return .scalar(Self.unquote(t))
        }

        mutating func list(_ indent: Int) -> WingetYAML {
            var out: [WingetYAML] = []
            while i < rows.count, rows[i].indent == indent, Self.isDash(rows[i].text) {
                let t = rows[i].text
                let rest = t == "-" ? "" : String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    i += 1
                    if i < rows.count, rows[i].indent > indent { out.append(node(rows[i].indent)) } else { out.append(.scalar("")) }
                } else {
                    let child = indent + 1 + t.dropFirst().prefix { $0 == " " }.count
                    rows[i] = Row(indent: child, text: rest)
                    out.append(node(child))
                }
            }
            return .list(out)
        }

        mutating func map(_ indent: Int) -> WingetYAML {
            var out: [String: WingetYAML] = [:]
            while i < rows.count, rows[i].indent == indent, !Self.isDash(rows[i].text), let (key, value) = Self.split(rows[i].text) {
                i += 1
                if value.isEmpty {
                    if i < rows.count, rows[i].indent > indent { out[key] = node(rows[i].indent) }
                    // a list may sit at its key's own indent ("Installers:" then "- Architecture: x64")
                    else if i < rows.count, rows[i].indent == indent, Self.isDash(rows[i].text) { out[key] = list(indent) }
                    else { out[key] = .scalar("") }
                } else if value.hasPrefix("|") || value.hasPrefix(">") {
                    var parts: [String] = []
                    while i < rows.count, rows[i].indent > indent { parts.append(rows[i].text); i += 1 }
                    out[key] = .scalar(parts.joined(separator: value.hasPrefix("|") ? "\n" : " "))
                } else {
                    var text = value
                    while i < rows.count, rows[i].indent > indent { text += " " + rows[i].text; i += 1 }
                    out[key] = .scalar(Self.unquote(text))
                }
            }
            return .map(out)
        }
    }
}

// MARK: Manifest

struct WingetInstaller: Equatable {
    var architecture = "", type = "", url = "", sha256 = ""
    var scope: String?, nestedType: String?, nestedFiles: [String] = []
    /// Silent, SilentWithProgress, Interactive, Custom, Log, InstallLocation.
    var switches: [String: String] = [:]
    var successCodes: [Int] = [], elevation: String?
    var abortsTerminal = false, hasDependencies = false
}

struct WingetAgreement: Equatable { var label: String, text: String, url: String }

struct WingetManifest: Equatable {
    var id = "", name = "", publisher = "", version = ""
    var shortDescription = "", description = "", license = "", licenseURL = "", packageURL = "", iconURL = "", releaseDate = ""
    var tags: [String] = [], agreements: [WingetAgreement] = []
    var installers: [WingetInstaller] = []

    /// Parses a merged manifest. The top level holds defaults an installer may override.
    static func parse(_ text: String) -> WingetManifest? {
        guard let top = WingetYAML.parse(text), let id = top["PackageIdentifier"]?.string, !id.isEmpty else { return nil }
        func s(_ y: WingetYAML?, _ key: String) -> String { y?[key]?.string ?? "" }
        var m = WingetManifest()
        m.id = id; m.name = s(top, "PackageName"); m.publisher = s(top, "Publisher"); m.version = s(top, "PackageVersion")
        m.shortDescription = s(top, "ShortDescription"); m.description = s(top, "Description")
        m.license = s(top, "License"); m.licenseURL = s(top, "LicenseUrl"); m.packageURL = s(top, "PackageUrl")
        m.releaseDate = s(top, "ReleaseDate")
        m.tags = (top["Tags"]?.items ?? []).compactMap(\.string)
        let icons = (top["Icons"]?.items ?? []).filter { $0["IconUrl"]?.string != nil }
        m.iconURL = s(icons.first { $0["IconFileType"]?.string == "png" } ?? icons.first, "IconUrl")
        m.agreements = (top["Agreements"]?.items ?? []).map {
            WingetAgreement(label: s($0, "AgreementLabel"), text: s($0, "Agreement"), url: s($0, "AgreementUrl"))
        }
        for item in top["Installers"]?.items ?? [] {
            func pick(_ key: String) -> WingetYAML? { item[key] ?? top[key] }
            var i = WingetInstaller()
            i.architecture = s(item, "Architecture"); i.url = s(item, "InstallerUrl"); i.sha256 = s(item, "InstallerSha256").lowercased()
            i.type = pick("InstallerType")?.string ?? ""
            i.scope = pick("Scope")?.string; i.nestedType = pick("NestedInstallerType")?.string
            i.nestedFiles = (pick("NestedInstallerFiles")?.items ?? []).compactMap { $0["RelativeFilePath"]?.string }
            for source in [top["InstallerSwitches"], item["InstallerSwitches"]] {
                if case .map(let map)? = source { for (k, v) in map { if let v = v.string { i.switches[k] = v } } }
            }
            i.successCodes = (pick("InstallerSuccessCodes")?.items ?? []).compactMap { $0.string.flatMap { Int($0) } }
            i.elevation = pick("ElevationRequirement")?.string
            i.abortsTerminal = pick("InstallerAbortsTerminal")?.string == "true"
            i.hasDependencies = pick("Dependencies") != nil
            m.installers.append(i)
        }
        return m
    }
}

// MARK: Version list

struct WingetVersion: Equatable { var version: String, path: String, sha256: String }

enum WingetVersionData {
    /// A 28-byte header, "CK", then raw DEFLATE of YAML; the versions newest first.
    static func decode(_ data: Data) -> [WingetVersion]? {
        let marker: Int
        if data.count > 30, data[28] == 0x43, data[29] == 0x4b { marker = 28 }
        else if let r = data.range(of: Data([0x43, 0x4b])) { marker = r.lowerBound }
        else { return nil }
        guard let inflated = try? (Data(data[(marker + 2)...]) as NSData).decompressed(using: .zlib) as Data,
              let text = String(data: inflated, encoding: .utf8), let yaml = WingetYAML.parse(text) else { return nil }
        let list = (yaml["vD"]?.items ?? []).compactMap { item -> WingetVersion? in
            guard let v = item["v"]?.string, let p = item["rP"]?.string, let h = item["s256H"]?.string else { return nil }
            return WingetVersion(version: v, path: p, sha256: h.lowercased())
        }
        return list.isEmpty ? nil : list
    }
}

// MARK: Index

struct WingetPackage: Identifiable, Equatable {
    var id: String, name: String, moniker: String, latest: String
    /// Hex sha256 of the package's versionData.
    var hash: String
}

final class WingetIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        // The file must be a winget index, not any SQLite file.
        guard (try? query("SELECT COUNT(*) FROM packages LIMIT 1", [])) != nil else { sqlite3_close(db); return nil }
    }
    deinit { sqlite3_close(db) }

    var count: Int { (try? query("SELECT COUNT(*) FROM packages", []).first.flatMap { Int($0[0]) }) ?? 0 }

    /// Packages whose id, name, moniker, tags or commands contain `text`, best match first.
    func search(_ text: String, limit: Int = 40) -> [WingetPackage] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let like = "%" + q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        // Tags and commands go through uncorrelated subqueries: the correlated form took seconds.
        let sql = """
        SELECT id, name, COALESCE(moniker, ''), latest_version, hex(hash) FROM packages WHERE
          id LIKE ?1 ESCAPE '\\' OR name LIKE ?1 ESCAPE '\\' OR moniker LIKE ?1 ESCAPE '\\'
          OR rowid IN (SELECT package FROM tags2_map WHERE tag IN (SELECT rowid FROM tags2 WHERE tag LIKE ?1 ESCAPE '\\'))
          OR rowid IN (SELECT package FROM commands2_map WHERE command IN (SELECT rowid FROM commands2 WHERE command LIKE ?1 ESCAPE '\\'))
        LIMIT 600
        """
        let rows = (try? query(sql, [like])) ?? []
        let found = rows.map { WingetPackage(id: $0[0], name: $0[1], moniker: $0[2], latest: $0[3], hash: $0[4].lowercased()) }
        var scored: [(package: WingetPackage, score: Int)] = []
        for p in found { scored.append((p, Self.score(p, q))) }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.package.name.localizedCaseInsensitiveCompare(b.package.name) == .orderedAscending
        }
        return scored.prefix(limit).map { $0.package }
    }

    func package(id: String) -> WingetPackage? {
        guard let r = try? query("SELECT id, name, COALESCE(moniker, ''), latest_version, hex(hash) FROM packages WHERE id = ?1", [id]).first else { return nil }
        return WingetPackage(id: r[0], name: r[1], moniker: r[2], latest: r[3], hash: r[4].lowercased())
    }

    /// Exact beats prefix beats substring; name beats id beats moniker; a match only by tag or command still counts.
    static func score(_ p: WingetPackage, _ query: String) -> Int {
        let q = query.lowercased()
        func field(_ v: String, _ exact: Int, _ prefix: Int, _ part: Int) -> Int {
            let v = v.lowercased()
            return v == q ? exact : v.hasPrefix(q) ? prefix : v.contains(q) ? part : 0
        }
        let s = field(p.name, 140, 50, 30) + field(p.id, 135, 45, 25) + field(p.moniker, 130, 55, 35)
        // A name close in length to what was typed is likelier what was meant.
        return s == 0 ? 5 : s - min(max(p.name.count - q.count, 0), 60) / 4
    }

    private func query(_ sql: String, _ args: [String]) throws -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw WingetError.index }
        defer { sqlite3_finalize(stmt) }
        for (n, a) in args.enumerated() {
            sqlite3_bind_text(stmt, Int32(n + 1), a, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(stmt)).map { sqlite3_column_text(stmt, $0).map { String(cString: $0) } ?? "" })
        }
        return rows
    }
}

enum WingetError: Error { case index, network(String), mismatch(String), unsupported(String) }
