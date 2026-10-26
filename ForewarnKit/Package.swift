// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ForewarnKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ForewarnKit", targets: ["ForewarnKit"]),
    ],
    targets: [
        .target(name: "ForewarnKit"),
        .testTarget(name: "ForewarnKitTests", dependencies: ["ForewarnKit"]),
    ]
)
