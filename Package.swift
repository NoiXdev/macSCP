// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "macSCP",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "macSCPCore", targets: ["macSCPCore"]),
        .executable(name: "macscp-cli", targets: ["MacSCPCLI"]),
        .executable(name: "macSCP", targets: ["MacSCPMain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        // Citadel depends on Wellz26/swift-nio-ssh, a fork with a deleted
        // parent that is behind Apple on signature validation and mangles
        // RFC 4253 §4.2 preamble lines into the version string. This root
        // dependency carries the same package identity (`swift-nio-ssh`) at
        // a different URL, which SwiftPM resolves in place of Citadel's —
        // measured 2026-09-01, see docs/superpowers/specs/2026-08-20-backlog-dependencies.md.
        // The fork is ours; `exact:` makes every change to it a deliberate
        // bump here. 0.3.7 = Wellz26 0.3.6 + Apple 0.14.1 ECDSA mpint
        // validation + preamble handling.
        .package(url: "https://github.com/NoiXdev/swift-nio-ssh.git", exact: "0.3.7"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", revision: "d5ee56e1c74777120f3af688600d336de4201bd2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
    ],
    targets: [
        .target(
            name: "macSCPCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                // Core implements NIOSSH's key/signature protocols itself
                // (AgentBackedPrivateKey); naming the product here is what
                // makes the root-level swift-nio-ssh dependency "used".
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            resources: [
                .process("Resources/en.lproj"),
                .process("Resources/de.lproj"),
                .process("Resources/fr.lproj"),
                .process("Resources/pl.lproj"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MacSCPCLI",
            dependencies: [
                "macSCPCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MacSCPAppKit",
            dependencies: [
                "macSCPCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MacSCPMain",
            dependencies: ["MacSCPAppKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "macSCPAppKitTests",
            dependencies: ["MacSCPAppKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "macSCPCoreTests",
            dependencies: [
                "macSCPCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            // `LegacyStoreCompatibilityTests` copies these into a temporary
            // directory and loads them through the real stores, addressing
            // them by `#filePath` — so they must NOT be bundled as resources.
            // Declaring them keeps SwiftPM from warning about unhandled files.
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
