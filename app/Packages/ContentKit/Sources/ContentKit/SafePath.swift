// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Path policy for everything the client writes under an install root.
public enum SafePath {
    public static let maxPathBytes = 1024
    public static let maxComponentBytes = 255

    /// Normalises a manifest path (Windows separators) to a relative,
    /// "/"-separated path, or throws `unsafeContent`.
    public static func normalize(_ raw: String) throws -> String {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        guard !unified.isEmpty, unified.utf8.count <= maxPathBytes else { throw ClientError.unsafeContent("path length \(unified.utf8.count)") }
        guard !unified.hasPrefix("/") else { throw ClientError.unsafeContent("absolute path \(unified)") }
        guard !unified.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == ":" }) else {
            throw ClientError.unsafeContent("control character, drive or stream separator in \(unified.debugDescription)")
        }
        var parts: [Substring] = []
        for c in unified.split(separator: "/", omittingEmptySubsequences: true) {
            guard c != "..", c != "." else { throw ClientError.unsafeContent("traversal component in \(unified)") }
            guard c.utf8.count <= maxComponentBytes else { throw ClientError.unsafeContent("component too long in \(unified)") }
            parts.append(c)
        }
        guard !parts.isEmpty else { throw ClientError.unsafeContent("empty path") }
        return parts.joined(separator: "/")
    }

    /// A symlink entry may only point at a location inside the root.
    public static func checkLink(from path: String, target: String) throws {
        let t = target.replacingOccurrences(of: "\\", with: "/")
        guard !t.hasPrefix("/"), !t.contains(":") else { throw ClientError.unsafeContent("symlink \(path) -> absolute target") }
        var stack = path.split(separator: "/").dropLast().map(String.init)
        for c in t.split(separator: "/") {
            if c == "." { continue }
            if c == ".." {
                guard !stack.isEmpty else { throw ClientError.unsafeContent("symlink \(path) escapes the install root") }
                stack.removeLast()
            } else {
                stack.append(String(c))
            }
        }
    }
}

/// Names a Windows guest can hold: what an import from Files may bring into C:\Games.
public enum WindowsName {
    static let reserved: Set<String> = Set(["con", "prn", "aux", "nul"]
        + (0...9).map { "com\($0)" } + (0...9).map { "lpt\($0)" })

    /// Throws `unsafeContent` for a component Windows cannot name: a reserved
    /// device name (with any extension), a character outside its file names,
    /// a control character, a trailing dot or space, `.` or `..`.
    public static func check(_ component: String) throws {
        guard !component.isEmpty, component != ".", component != ".." else {
            throw ClientError.unsafeContent("empty or traversal component")
        }
        guard component.utf8.count <= SafePath.maxComponentBytes else { throw ClientError.unsafeContent("\(component.prefix(40))… is too long") }
        if let bad = component.unicodeScalars.first(where: { $0.value < 0x20 || $0.value == 0x7F || "<>:\"/\\|?*".unicodeScalars.contains($0) }) {
            throw ClientError.unsafeContent("\(component.debugDescription) has a character Windows refuses (U+\(String(bad.value, radix: 16, uppercase: true)))")
        }
        guard !component.hasSuffix("."), !component.hasSuffix(" ") else {
            throw ClientError.unsafeContent("\(component.debugDescription) ends in a dot or space")
        }
        let stem = component.split(separator: ".", maxSplits: 1).first.map { $0.lowercased() } ?? ""
        guard !reserved.contains(stem.trimmingCharacters(in: .whitespaces)) else {
            throw ClientError.unsafeContent("\(component) is a reserved Windows name")
        }
    }

    /// Checks a relative path's every component, and that no two paths in
    /// `seen` differ only by case (Windows would see one file); inserts it.
    public static func check(path: [String], seen: inout Set<String>) throws {
        for c in path { try check(c) }
        let key = path.joined(separator: "/").lowercased()
        guard seen.insert(key).inserted else {
            throw ClientError.unsafeContent("\(path.joined(separator: "/")) differs from another name only by case")
        }
    }
}
