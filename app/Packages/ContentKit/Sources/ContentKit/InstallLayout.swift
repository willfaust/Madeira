// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where installs live. On the device (`container`): staging under
/// `Library/titles/.staging`, placed titles in the prefix's
/// `drive_c/Games/<installdir>`, and
/// the non-secret state (retained manifests, install records) under
/// `Library/Application Support/Playport`. Staging and games must share a
/// volume: the commit is one `rename`.
public struct InstallLayout: Sendable {
    public var stagingRoot: URL
    public var gamesRoot: URL
    public var stateRoot: URL

    public init(stagingRoot: URL, gamesRoot: URL, stateRoot: URL) {
        self.stagingRoot = stagingRoot
        self.gamesRoot = gamesRoot
        self.stateRoot = stateRoot
    }

    public static func container(home: URL) -> InstallLayout {
        InstallLayout(stagingRoot: home.appendingPathComponent("Library/titles/.staging", isDirectory: true),
                      gamesRoot: home.appendingPathComponent("Documents/prefix/drive_c/Games", isDirectory: true),
                      stateRoot: home.appendingPathComponent("Library/Application Support/Playport", isDirectory: true))
    }

    /// A host-side stand-in: `<root>/staging`, `<root>/Games`, `<root>/state`.
    public static func root(_ root: URL) -> InstallLayout {
        InstallLayout(stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
                      gamesRoot: root.appendingPathComponent("Games", isDirectory: true),
                      stateRoot: root.appendingPathComponent("state", isDirectory: true))
    }

    public var manifestsDir: URL { stateRoot.appendingPathComponent("manifests", isDirectory: true) }
    public var installsDir: URL { stateRoot.appendingPathComponent("installs", isDirectory: true) }

    /// A stage directory and its journal, by a name unique to the store's
    /// game and build (`<appID>_<build>`, `gog-<id>_<build>`).
    public func stagingTree(name: String) -> URL { stagingRoot.appendingPathComponent(name, isDirectory: true) }
    public func journal(name: String) -> URL { stagingRoot.appendingPathComponent(name + ".journal") }
}
