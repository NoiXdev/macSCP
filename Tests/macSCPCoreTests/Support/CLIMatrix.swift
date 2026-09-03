import Foundation
import NIOCore
import Synchronization
import Testing
@testable import macSCPCore

/// One rig backend, wired end to end for the command line: a temporary
/// session store holding exactly one session, the environment that carries
/// that backend's secret, a way to run the BUILT binary against it, and the
/// backend's own `RemoteFileSystem` for seeding and cleaning up remote
/// state.
///
/// Why this exists: before it, exactly one test drove the built binary
/// against a real server, and only over SSH
/// (`CLIRoundtripITests.sshRoundtripMovesTheBytesBackAndForth`, measured
/// 2026-09-03). Every other backend's command-line behaviour — which
/// session store it reads, where its secret comes from, what `--json`
/// prints — was covered only by unit tests of the pieces underneath the
/// binary, which cannot see an argument the binary never passes on.
///
/// Nothing here enumerates backends by hand. The rig fixture below is an
/// EXHAUSTIVE switch over `ConnectionKind`, so a fourth protocol does not
/// compile until it has rig coordinates; the secret's variable name is read
/// from the backend's own `BackendDescriptor.secretEnvironmentVariable`;
/// the connection the verification side opens is built by the same
/// `StoredSessionConnectionConfig.build` the CLI itself calls; and the
/// command list comes from the binary's `--help`, not from a list written
/// here (`subcommands(binary:)`).
///
/// SECRETS: a secret reaches the child through its ENVIRONMENT and nowhere
/// else — never in argv, never in a file under the temporary store, never
/// in a failure message. `secret` below is `private` and is interpolated
/// into no string in this file.
struct CLIMatrix: Sendable {
    let kind: ConnectionKind

    /// The one session in the temporary store, named uniquely per rig so two
    /// rigs (or two runs) can never resolve each other's.
    let session: StoredSession

    /// `MACSCP_STORAGE_DIRECTORY` for the child: the session file, the
    /// known-hosts file and the trusted-certificate file all land here, so
    /// nothing this suite does touches
    /// `~/Library/Application Support/macSCP/`.
    let storageDirectory: URL

    /// The remote directory this backend's cases work in — the root of the
    /// area the rig makes writable, not necessarily `/`. SSH's `/` is the
    /// container's own filesystem and is not writable by `testuser`; its
    /// home, `/config`, is. S3's is the seeded bucket's root and WebDAV's is
    /// the Basic vhost's `Alias /dav` root, both writable as-is.
    let remoteRoot: String

    /// Never interpolated into a string in this file, and `private` so it
    /// cannot be from outside it either. It has exactly one exit: the
    /// child's environment, in `environment()` below.
    private let secret: String

    var descriptor: BackendDescriptor { .descriptor(for: kind) }
    var capabilities: ProtocolCapabilities { descriptor.capabilities }

    /// The `name:/path` reference every subcommand takes.
    func target(_ path: String) -> String { "\(session.name):\(path)" }

    /// `name` inside `remoteRoot`, without the doubled slash that
    /// `"\(remoteRoot)/\(name)"` produces when the root IS `/` — which S3
    /// reads as a key beginning with an empty segment rather than as the
    /// same path.
    func remotePath(_ name: String) -> String {
        remoteRoot.hasSuffix("/") ? remoteRoot + name : "\(remoteRoot)/\(name)"
    }

    // MARK: - Rig coordinates

    /// The rig's coordinates per backend, from `docker/test-server/compose.yml`:
    /// sshd on 2222, MinIO on 19000 with the seeded `macscp-seed` bucket, and
    /// the Apache Basic-auth vhost on 18080. The same values
    /// `CitadelFileSystemIntegrationTests`, `S3FileSystemIntegrationTests` and
    /// `WebDAVFileSystemIntegrationTests` already use.
    ///
    /// EXHAUSTIVE over `ConnectionKind`: this is what makes "every backend the
    /// rig offers" a compiler-checked claim rather than a list that quietly
    /// falls one behind. A fourth protocol fails to build here, which is the
    /// structural boundary CLAUDE.md prefers over a scan that could go stale.
    ///
    /// The WebDAV vhost is the PLAIN-HTTP one on purpose: the CLI hands
    /// `certificate: .refusing` to every connect (`SessionConnecting.swift`),
    /// so it has no way to accept the rig's self-signed certificate on 18443
    /// and the TLS vhost is unreachable from the binary at all.
    private static func fixture(
        for kind: ConnectionKind, name: String
    ) -> (session: StoredSession, secret: String, remoteRoot: String) {
        switch kind {
        case .ssh:
            return (
                sshSession(
                    name: name, host: "127.0.0.1", port: 2222,
                    username: "testuser", authKind: .password),
                "testpass",
                "/config")
        case .s3:
            return (
                s3Session(
                    name: name,
                    config: StoredS3Config(
                        accessKeyID: "macscp", region: "us-east-1",
                        endpoint: "http://127.0.0.1:19000", bucket: "macscp-seed",
                        usePathStyle: true)),
                "macscpsecretkey",
                "/")
        case .webdav:
            return (
                webdavSession(
                    name: name,
                    config: StoredWebDAVConfig(
                        baseURL: "http://127.0.0.1:18080/dav", username: "testuser",
                        useNextcloudPath: false)),
                "testpass",
                "/")
        }
    }

    /// Creates the temporary store, writes the one session into it, and hands
    /// back the rig. `label` only makes the session name legible in a failure
    /// message; a UUID is appended so no two rigs share a name.
    static func make(for kind: ConnectionKind, label: String) throws -> CLIMatrix {
        let storageDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "macscp-cli-matrix-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory, withIntermediateDirectories: true)
        let fixture = fixture(for: kind, name: "\(label)-\(kind.rawValue)-\(UUID().uuidString)")
        try SessionStore(directory: storageDirectory).upsert(fixture.session)
        return CLIMatrix(
            kind: kind, session: fixture.session, storageDirectory: storageDirectory,
            remoteRoot: fixture.remoteRoot, secret: fixture.secret)
    }

    /// Removes the temporary store. Not a `deinit`: this project's rule is
    /// that lifecycles are owned explicitly, and a `struct` has none anyway.
    func tearDown() {
        try? FileManager.default.removeItem(at: storageDirectory)
    }

    // MARK: - Running the binary

    /// The environment the child runs with.
    ///
    /// EVERY backend's secret variable is removed first and only this
    /// backend's is then set — derived from `ConnectionKind.allCases`, so a
    /// fourth backend's variable is scrubbed by construction. Without that,
    /// an `AWS_SECRET_ACCESS_KEY` already exported in the developer's shell
    /// would reach an S3 child and decide the test, and a `MACSCP_PASSWORD`
    /// would reach every other one.
    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for other in ConnectionKind.allCases {
            if let variable = BackendDescriptor.descriptor(for: other).secretEnvironmentVariable {
                environment.removeValue(forKey: variable)
            }
        }
        if let variable = descriptor.secretEnvironmentVariable {
            environment[variable] = secret
        }
        environment["MACSCP_STORAGE_DIRECTORY"] = storageDirectory.path(percentEncoded: false)
        return environment
    }

    /// Runs the built binary with `arguments` and this rig's store and
    /// secret. Through `SubprocessRunner`, which awaits the child instead of
    /// parking a cooperative-pool thread on it (CLAUDE.md, "Tests never block
    /// the cooperative pool"), and whose `SubprocessTimeout` names the
    /// argument COUNT rather than the arguments — the withholding that keeps
    /// a passphrase out of a CI log.
    ///
    /// stdin is the null device, so no case here depends on whether the
    /// process running `swift test` happens to have a terminal.
    @discardableResult
    func run(_ arguments: [String]) async throws -> SubprocessResult {
        try await SubprocessRunner.run(
            try CLIMatrix.binaryURL(), arguments: arguments, environment: environment())
    }

    // MARK: - The backend's own file system

    /// Opens the backend's file system directly, for seeding a fixture and
    /// for verifying (or cleaning up) what the binary did.
    ///
    /// Built from the SAME `StoredSessionConnectionConfig.build` the CLI
    /// calls, so the rig's coordinates are written once and this side cannot
    /// drift from the side under test. What it does NOT reuse is
    /// `BackendDescriptor.openConnection`: the SSH backend's own connect
    /// closure reaches for `KnownHostsStore(directory: SessionStore
    /// .defaultDirectory)`, and in THIS process — which sets no
    /// `MACSCP_STORAGE_DIRECTORY` of its own — that is the developer's real
    /// `~/Library/Application Support/macSCP/known_hosts.json`. The switch
    /// below is over the built `ConnectionConfig`, so it is exhaustive for
    /// the same reason `fixture(for:name:)` is.
    func connect() async throws -> any RemoteFileSystem {
        switch try StoredSessionConnectionConfig.build(for: session, secret: secret) {
        case .ssh(let ssh):
            return try await CitadelFileSystem.connect(
                config: ssh, connectTimeout: .seconds(30),
                knownHosts: KnownHostsStore(directory: storageDirectory),
                onUnknownHostKey: .asking { _ in true })
        case .s3(let s3):
            return try await S3FileSystem.connect(s3)
        case .webdav(let webdav):
            return try await WebDAVFileSystem.connect(
                webdav, trustStore: TrustedCertificateStore(directory: storageDirectory),
                decider: .asking { _ in true })
        }
    }

    /// Writes `content` at `path` through the backend's own file system.
    /// Seeding through the backend rather than through the binary is what
    /// keeps a case that asserts on `ls` from depending on `put` as well.
    func seed(_ fileSystem: any RemoteFileSystem, path: String, content: Data) async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(content)
        continuation.finish()
        try await fileSystem.write(path: path, contents: stream)
    }

    /// Best-effort removal of whatever a case left on the rig, through the
    /// backend's own file system.
    ///
    /// The WebDAV container has no volume: its `/var/dav/basic` is seeded at
    /// container start and every byte a test adds survives until the
    /// container is recreated. So remote state is left as it was found, and
    /// this runs on the throwing path too — a case that fails must not also
    /// leave litter behind.
    ///
    /// `delete` FIRST, and only what that refuses goes to `deleteTree`. Not
    /// tidiness: `RemoteFileSystem.deleteTree`'s own contract says "A plain
    /// file behaves exactly like `delete`", and measured against this rig on
    /// 2026-09-04 that holds for SSH and for neither of the other two —
    ///   - WebDAV sends `DELETE` with a trailing slash (`isDirectory: true`),
    ///     and Apache/mod_dav answers **400** to that on a plain file, **204**
    ///     without it;
    ///   - S3 deletes every key under `<key>/`, and a file's key has nothing
    ///     beneath it, so the call succeeds having deleted nothing.
    /// A `try? await deleteTree(...)` here therefore left the seeded file on
    /// both servers, silently, which is how the divergence was found at all.
    /// It is a fact about those backends, not about this helper, and is
    /// recorded rather than worked around anywhere but here.
    func removeRemote(_ fileSystem: any RemoteFileSystem, path: String) async {
        do {
            try await fileSystem.delete(path: path)
        } catch {
            try? await fileSystem.deleteTree(at: path)
        }
    }

    // MARK: - Capability gating

    /// Whether this backend can be asked for `operation` at all, PRINTING the
    /// reason when it cannot so a skipped case says why in the run's own log
    /// rather than vanishing.
    ///
    /// The question is put to the backend's own `ProtocolCapabilities` — a
    /// key path into it, plus the axis's name for the printed reason — never
    /// to its `kind`. That is the same rule the browser, the menus and
    /// `PlaintextTransportGate` follow, and it is what lets a fourth backend
    /// be skipped correctly without a line changing here.
    func supports(
        _ axis: KeyPath<ProtocolCapabilities, Bool>, named axisName: String,
        operation: String
    ) -> Bool {
        let supported = capabilities[keyPath: axis]
        if !supported {
            print("""
                CLIMatrix: skipping \(operation) on \(kind.rawValue) — \
                \(axisName) is false for this backend
                """)
        }
        return supported
    }

    // MARK: - The binary, and what it says it can do

    /// Exists only so `binaryURL()` has a class defined in THIS file to hand
    /// `Bundle(for:)`.
    private final class TestBundleAnchor {}

    /// Locates the already-built `macscp-cli`. The full argument for why the
    /// lookup is bundle-relative and why it must never run `swift build`
    /// itself is at `CLIRoundtripITests.locateCLIBinary()`; the short version
    /// is that a nested `swift build` waits on the `.build` lock this very
    /// process holds, and that `.build/debug`, `.build/release` and
    /// `--scratch-path` all put the product beside the test bundle.
    static func binaryURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MACSCP_CLI_BINARY"],
           !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw CLIMatrixError.binaryNotFound(override)
            }
            return URL(fileURLWithPath: override)
        }
        let url = Bundle(for: TestBundleAnchor.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("macscp-cli")
        guard FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) else {
            throw CLIMatrixError.binaryNotFound(url.path(percentEncoded: false))
        }
        return url
    }

    /// The subcommands the binary itself offers, read from its `--help`.
    ///
    /// The matrix's command axis, and read rather than written down: a
    /// seventh subcommand appears here the moment it appears in
    /// `MacSCPCLI.configuration.subcommands`, without an edit in this target.
    /// A list typed here would instead go on passing while covering five of
    /// six commands.
    ///
    /// Read ONCE per binary and cached: every case in the matrix asks, and
    /// launching a process per ask is a cost with nothing to show for it.
    /// Two callers racing the first read both run `--help` and store the same
    /// answer — harmless, and cheaper than serialising every reader behind an
    /// actor for a value that never changes within a run.
    static func subcommands(binary: URL) async throws -> [String] {
        if let cached = subcommandCache.withLock({ $0[binary] }) { return cached }
        let result = try await SubprocessRunner.run(binary, arguments: ["--help"])
        guard result.status == 0 else {
            throw CLIMatrixError.helpFailed(status: result.status)
        }
        let parsed = parseSubcommands(result.stdoutText)
        guard !parsed.isEmpty else { throw CLIMatrixError.noSubcommandsInHelp }
        subcommandCache.withLock { $0[binary] = parsed }
        return parsed
    }

    private static let subcommandCache = Mutex<[URL: [String]]>([:])

    /// ArgumentParser prints the subcommands as an indented block under a
    /// `SUBCOMMANDS:` heading, one `  <name>  <abstract>` line each, and ends
    /// the block with a blank line before its own
    /// `See 'macscp-cli help <subcommand>'` footer — which is indented too,
    /// so the blank line is what separates them, not the indentation.
    ///
    /// `internal` rather than private so the parse can be measured against a
    /// fixture without launching anything.
    static func parseSubcommands(_ help: String) -> [String] {
        let lines = help.split(separator: "\n", omittingEmptySubsequences: false)
        guard let heading = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "SUBCOMMANDS:" })
        else { return [] }
        var names: [String] = []
        for line in lines[lines.index(after: heading)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard let name = line.split(separator: " ", omittingEmptySubsequences: true).first
            else { continue }
            names.append(String(name))
        }
        return names
    }
}

/// One entry of `ls --json`, decoded.
///
/// A decoded type rather than a `JSONSerialization` dictionary walked with
/// `as?`: those silently drop a line whose shape changed, so a rename of
/// `directory` would leave a listing assertion reading an empty list and
/// saying "the file is not there". `Decodable` makes the same change a
/// decode error naming the key.
struct CLIListedItem: Decodable, Equatable, Sendable {
    let name: String
    let path: String
    let directory: Bool
    /// `null` for an unknown size — never `0`, which is a real size
    /// (`OutputFormatter.print(items:asJSON:)`).
    let size: UInt64?
}

extension CLIMatrix {
    /// Decodes `ls --json` output: ONE JSON object per line, which is what
    /// `--json` means here ("Emit one JSON object per line", `GlobalOptions`)
    /// — not one array.
    ///
    /// Every non-empty line must decode; nothing is skipped. That is the
    /// point: a case asserts on the entries AND on the count, so a line the
    /// decoder could not read fails the test instead of disappearing from
    /// the comparison.
    static func listing(_ stdout: String) throws -> [CLIListedItem] {
        let decoder = JSONDecoder()
        return try stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(CLIListedItem.self, from: Data($0.utf8)) }
    }
}

enum CLIMatrixError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case helpFailed(status: Int32)
    case noSubcommandsInHelp

    var description: String {
        switch self {
        case .binaryNotFound(let path):
            return """
                macscp-cli not found at \(path). Build it before running the \
                gated suite (swift build --product macscp-cli), or point \
                MACSCP_CLI_BINARY at an existing binary.
                """
        case .helpFailed(let status):
            return "macscp-cli --help exited \(status)"
        case .noSubcommandsInHelp:
            return "macscp-cli --help printed no SUBCOMMANDS block"
        }
    }
}
