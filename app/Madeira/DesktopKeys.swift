// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Keys for Windows programs on the Wine desktop: the on-screen keyboard's extra row and Command
/// as Control. Foundation only (tests/host/check-desktop-keys.py compiles it).
enum DesktopKeys {
    /// The accessory row above the on-screen keyboard: (title, Windows virtual-key code). -1 pastes, 0 closes.
    private static let editing: [(title: String, vk: Int32)] = [
        ("Paste", -1), ("Esc", 0x1b), ("Ctrl", 0x11), ("Shift", 0x10), ("Alt", 0x12), ("Tab", 0x09), ("Enter", 0x0d),
        ("←", 0x25), ("↑", 0x26), ("↓", 0x28), ("→", 0x27),
        ("Home", 0x24), ("End", 0x23), ("PgUp", 0x21), ("PgDn", 0x22), ("Del", 0x2e),
    ]
    private static let functionKeys: [(title: String, vk: Int32)] = (1...12).map { (title: "F\($0)", vk: Int32(0x6f + $0)) }
    private static let close: [(title: String, vk: Int32)] = [("Done", 0)]
    static let accessory: [(title: String, vk: Int32)] = editing + functionKeys + close

    /// Held between presses until pressed again, not tapped.
    static let modifiers: Set<Int32> = [0x10, 0x11, 0x12]

    /// Command is Windows' key (VK_LWIN, VK_RWIN); on a Mac it does what Control does elsewhere, so with
    /// the setting on it is posted as Control (VK_LCONTROL, VK_RCONTROL) when it is part of a shortcut.
    static func postedKey(_ vk: Int32, commandIsControl: Bool) -> Int32 {
        guard commandIsControl else { return vk }
        switch vk {
        case 0x5b: return 0xa2
        case 0x5c: return 0xa3
        default: return vk
        }
    }
}
