// SPDX-License-Identifier: GPL-3.0-or-later
// Stand-ins for the app types GOGSetup.swift uses, for the host tests.
import Foundation
enum GOGAPI { static func isHash(_ t: String) -> Bool { (16...128).contains(t.count) && t.allSatisfy { $0.isHexDigit } } }
enum GOGCodec { static func components(_ name: String) -> [String]? {
    let parts = name.split(separator: "/").map(String.init)
    return parts.isEmpty || parts.contains("..") || parts.contains(".") ? nil : parts } }
struct LibraryEntry { static func folder(of p: String) -> String { guard let i = p.lastIndex(of: "\\") else { return "C:\\" }; let d = String(p[..<i]); return d.count <= 2 ? d + "\\" : d } }
