// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pocket-client",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PocketClient", targets: ["PocketClient"]),
        .executable(name: "pocket-cli", targets: ["pocket-cli"]),
    ],
    targets: [
        .target(
            name: "PocketClient",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pocket-cli",
            dependencies: ["PocketClient"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PocketClientTests",
            dependencies: ["PocketClient"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
