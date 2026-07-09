// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "macSCP",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "macSCPCore", targets: ["macSCPCore"]),
        .executable(name: "macscp-cli", targets: ["MacSCPCLI"]),
        .executable(name: "macSCP", targets: ["MacSCPApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "macSCPCore",
            dependencies: [.product(name: "Citadel", package: "Citadel")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacSCPCLI",
            dependencies: [
                "macSCPCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacSCPApp",
            dependencies: ["macSCPCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "macSCPCoreTests",
            dependencies: ["macSCPCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
