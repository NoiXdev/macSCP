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
        // Citadel from our own fork, same package identity (`Citadel`) at a
        // different URL — the shape the swift-nio-ssh override below already
        // has. `exact:` makes every change to it a deliberate bump here.
        // 0.12.1-noix.2 = upstream 0.12.1 + upstream PR #135 (RFC 8332
        // `rsa-sha2-256`/`-512` signing) with its SHA-1 fallback flipped OFF
        // by default, + an ECDSA `openssh-key-v1` private-key parser
        // (`P256/P384/P521.Signing.PrivateKey.init(sshEcdsa:decryptionKey:)`
        // and the public `OpenSSHKeyTypeMismatch`). Both are what lets
        // `SSHPrivateKeyLoader` load an RSA or ECDSA key FILE at all.
        // 0.12.1-noix.3 types the RSA public key BLOB `ssh-rsa` again
        // (`SHA2PublicKey.publicKeyPrefix`) and moves the RFC 8332 name to
        // the new `userAuthAlgorithmName` that swift-nio-ssh 0.3.10 below
        // reads — the split that makes a Go-based server accept an RSA
        // login. It therefore requires 0.3.10 exactly. The fork record with
        // the measurements behind each tag is in
        // docs/superpowers/specs/2026-08-20-backlog-dependencies.md.
        .package(url: "https://github.com/NoiXdev/Citadel.git", exact: "0.12.1-noix.3"),
        // Citadel depends on Wellz26/swift-nio-ssh, a fork with a deleted
        // parent that is behind Apple on signature validation and mangles
        // RFC 4253 §4.2 preamble lines into the version string. This root
        // dependency carries the same package identity (`swift-nio-ssh`) at
        // a different URL, which SwiftPM resolves in place of Citadel's —
        // measured 2026-09-01, see docs/superpowers/specs/2026-08-20-backlog-dependencies.md.
        // The fork is ours; `exact:` makes every change to it a deliberate
        // bump here. 0.3.8 = Wellz26 0.3.6 + Apple 0.14.1 ECDSA mpint
        // validation + preamble handling + three Apple correctness fixes
        // the fork lacked (window update after local close, ByteBuffer
        // resize, sealed-box construction). 0.3.9 adds
        // `NIOSSHPublicKeyProtocol.hostKeyAlgorithmNames`, which separates a
        // custom host key's negotiated ALGORITHM NAME from the identifier its
        // wire blob carries — the split RFC 8332 requires, and what lets
        // `RSASHA2HostKey` be offered as `rsa-sha2-512` while its blob stays
        // `ssh-rsa` (see .superpowers/sdd/2026-09-02-rsa-host-key-fork-change).
        // 0.3.10 does the same for the USER-AUTH path, which 0.3.9 left
        // coupled: `NIOSSHPublicKeyProtocol.userAuthAlgorithmName` (default
        // `publicKeyPrefix`, so every bundled and existing custom type is
        // unaffected) is what the client now writes as `pkalg` and into the
        // signed payload, while the key blob keeps carrying
        // `publicKeyPrefix` — RFC 8332 §3's three identifiers, at last
        // independently choosable for a CLIENT key.
        .package(url: "https://github.com/NoiXdev/swift-nio-ssh.git", exact: "0.3.10"),
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
                // RSA host-key verification (`RSASHA2HostKey`): PKCS#1 v1.5
                // over SHA-512 lives in `_RSA.Signing`, which `Crypto` does
                // not vend.
                .product(name: "_CryptoExtras", package: "swift-crypto"),
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
                // `CLISessionNameCompletionTests` calls
                // `SessionNameCompletion.complete(prefix:)` directly, in
                // process, rather than through a subprocess — the only
                // dependency edge in this test target onto the CLI
                // executable, added for that one file.
                "MacSCPCLI",
                .product(name: "Crypto", package: "swift-crypto"),
                // `RSASHA2HostKeyTests` parses a host-key blob into
                // `ByteBuffer` and hands the result to NIOSSH's key/signature
                // protocols directly.
                .product(name: "NIOCore", package: "swift-nio"),
                // `SSHPrivateKeyLoaderTests` drains a built
                // `SSHAuthenticationMethod` the way NIOSSH does, on a real
                // event loop, to read the algorithm names it would offer.
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
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
