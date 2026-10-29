// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "GameBrowserKit", platforms: [.iOS(.v17), .macOS(.v15)],
 products: [.library(name: "GameBrowserKit", targets: ["GameBrowserKit"])],
 targets: [.target(name: "GameBrowserKit"), .testTarget(name: "GameBrowserKitTests", dependencies: ["GameBrowserKit"])])
