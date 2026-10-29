// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// The GOG client (README.md): sign-in with GOG's desktop-client identity (decision
// 0058), the owned library, and generation-2 content (builds, depot manifests,
// chunks over secure links) planned for ContentKit's install engine. Foundation
// only, so its tests run on the Linux host.
let package = Package(
    name: "GOGClient",
    platforms: [
        .iOS(.v17),
        .macOS(.v15),
    ],
    products: [
        .library(name: "GOGClientKit", targets: ["GOGClientKit"]),
    ],
    dependencies: [
        .package(path: "../ContentKit"),
    ],
    targets: [
        .target(
            name: "GOGClientKit",
            dependencies: [.product(name: "ContentKit", package: "ContentKit")],
            // Optimised in every configuration, as ContentKit (zlib and md5 per chunk).
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(
            name: "GOGClientKitTests",
            dependencies: ["GOGClientKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
