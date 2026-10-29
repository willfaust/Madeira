// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "GameImportKit", platforms: [.iOS(.v17), .macOS(.v15)],
 products: [.library(name: "GameImportKit", targets: ["GameImportKit"])],
 dependencies: [.package(path: "../ContentKit")],
 targets: [.target(name: "GameImportKit", dependencies: [.product(name: "ContentKit", package: "ContentKit")]),
 .testTarget(name: "GameImportKitTests", dependencies: ["GameImportKit"], resources: [.copy("Fixtures")])])
