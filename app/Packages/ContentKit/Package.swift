// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// The store-neutral core every store client builds on (README.md): the install
// engine (a plan of files made of chunk parts, the journal, free-space checks),
// the codecs, hashes, the bounded HTTP client, `Secret`, `Redactor` and the
// credential store. Foundation only, so its tests run on the Linux host.
let package = Package(
    name: "ContentKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ContentKit", targets: ["ContentKit"]),
    ],
    targets: [
        .target(
            name: "ContentKit",
            // Always optimised, as SteamClientKit (its Package.swift has the reason):
            // at -Onone the chunk pipeline is CPU-bound on the phone.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(
            name: "ContentKitTests",
            dependencies: ["ContentKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
