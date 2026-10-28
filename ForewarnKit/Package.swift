// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ForewarnKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ForewarnKit", targets: ["ForewarnKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(name: "ForewarnKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "ForewarnKitTests", dependencies: ["ForewarnKit"]),
    ]
)
