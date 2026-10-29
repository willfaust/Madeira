import Foundation

public enum BrowserRegistry {
    // Override Wine's web handler only. Keep custom handlers and all other protocols.
    public static func install(in text: String) -> String {
        var commands: [String: String] = [:]
        var section = ""
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("["), let end = line.lastIndex(of: "]") {
                section = String(line.dropFirst().prefix(upTo: end)).replacingOccurrences(of: "\\\\", with: "\\").lowercased()
            } else if line.hasPrefix("@=") { commands[section] = line }
        }
        let command = "\"C:\\windows\\system32\\madeira-url-opener.exe\" \"%1\""
        let value = "@=\"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        var result = text
        for scheme in ["http", "https"] {
            let key = "Software\\Classes\\\(scheme)\\shell\\open\\command"
            if let old = commands[key.lowercased()] {
                if old == value { continue }
                if !old.lowercased().contains("winebrowser.exe") && !old.lowercased().contains("madeira-url-opener.exe") { continue }
            }
            result += "\n[" + key.replacingOccurrences(of: "\\", with: "\\\\") + "] 0\n" + value + "\n"
        }
        return result
    }
}
