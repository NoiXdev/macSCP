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
        // The directory exists before the store step, and only the caller
        // holding a rig can call `tearDown()` — so a throw between the two
        // used to leave a directory nobody had a handle to. There is no
        // rig yet to `defer` on, which is exactly why the unwind is written
        // out here.
        do {
            try SessionStore(directory: storageDirectory).upsert(fixture.session)
        } catch {
            try? FileManager.default.removeItem(at: storageDirectory)
            throw error
        }
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

    /// Reads a remote file back through the backend's own file system, so a
    /// case can compare what `put` uploaded — or what `--on-conflict
    /// overwrite` replaced — against the bytes it meant to write. Through
    /// the backend rather than through `get`, for the same reason `seed`
    /// exists: a `put` case must not be able to pass because `get` shares
    /// its mistake.
    func read(_ fileSystem: any RemoteFileSystem, path: String) async throws -> Data {
        var data = Data()
        for try await chunk in try await fileSystem.readStream(path: path) {
            data.append(chunk)
        }
        return data
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
    func removeRemote(
        _ fileSystem: any RemoteFileSystem, path: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            try await fileSystem.delete(path: path)
        } catch {
            try? await fileSystem.deleteTree(at: path)
        }
        await verifyGone(fileSystem, path: path, sourceLocation: sourceLocation)
    }

    /// Removes a DIRECTORY and everything under it, and verifies the same
    /// way `removeRemote` does.
    ///
    /// A separate entry point rather than a `Bool` on that one, because the
    /// two are not interchangeable in either direction on this rig, and the
    /// asymmetry is the whole reason both exist:
    ///
    ///   - `removeRemote` on a DIRECTORY would not clean it up on S3 and
    ///     would not even fail. `S3FileSystem.delete(path:)` resolves its
    ///     key through `RootMode.resolve(path:)`, which normalizes and
    ///     splits on `/` — so `<name>/` and `<name>` resolve to the same
    ///     key, and the DELETE addresses a key that was never written.
    ///     Measured against this rig on 2026-09-04: MinIO answers that
    ///     success, so nothing throws, the `deleteTree` fallback is never
    ///     reached, and the directory's own marker key stays in the bucket.
    ///     The `stat` afterwards is what turned that into a red instead of
    ///     litter — two marker keys, removed by hand, when the probe that
    ///     measured it ran.
    ///   - `removeRemoteTree` on a FILE is the divergence recorded on
    ///     `removeRemote` above: WebDAV answers 400 and S3 deletes nothing.
    ///
    /// So a case removes a file with the first and a tree with the second,
    /// and neither call guesses which it is holding.
    func removeRemoteTree(
        _ fileSystem: any RemoteFileSystem, path: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        try? await fileSystem.deleteTree(at: path)
        await verifyGone(fileSystem, path: path, sourceLocation: sourceLocation)
    }

    private func verifyGone(
        _ fileSystem: any RemoteFileSystem, path: String, sourceLocation: SourceLocation
    ) async {
        // The removal ATTEMPTS above are best-effort on purpose — a case that failed
        // before it seeded anything has nothing to remove, and neither call
        // should turn that into a second failure. The OUTCOME is not
        // best-effort: a `try?` around both and nothing after it is exactly
        // the shape that let the S3 and WebDAV divergence above go unnoticed
        // through a full green run, and Task 2 multiplies the cases that
        // could hide it again. So the entry is looked for afterwards, and
        // its survival is recorded against the caller's own line.
        //
        // Neither message interpolates an error or a secret: `RemoteFSError`
        // renders configuration text through `String(describing:)` (the
        // "error text as a leak route" row in `docs/BACKLOG.md`), and the
        // path plus the backend is all a reader needs to go and look.
        do {
            _ = try await fileSystem.stat(path: path)
            Issue.record(
                """
                CLIMatrix cleanup left \(path) behind on the \(kind.rawValue) \
                rig — the rig is no longer as it was found
                """,
                sourceLocation: sourceLocation)
        } catch let error as RemoteFSError {
            guard case .notFound = error else {
                Issue.record(
                    """
                    CLIMatrix could not verify the cleanup of \(path) on the \
                    \(kind.rawValue) rig: the check itself failed
                    """,
                    sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record(
                """
                CLIMatrix could not verify the cleanup of \(path) on the \
                \(kind.rawValue) rig: the check itself failed
                """,
                sourceLocation: sourceLocation)
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
    /// The INDENT is what separates an entry from an abstract's continuation,
    /// and it is checked rather than assumed: an entry's name starts at
    /// column 2, a wrapped abstract continues at column 26 (measured
    /// 2026-09-04 from `macscp-cli ls --help`, where `--verbose`'s and
    /// `--accept-new`'s abstracts both wrap). Taking the first token of every
    /// indented line, as this did, would read `diagnostics.` as a command
    /// name the moment an abstract wrapped. Nothing wraps today — counted
    /// 2026-09-04, all six rows fit on one line, the widest being `get` at 72
    /// columns against ArgumentParser's 80 — so the hazard was invisible and
    /// entirely reachable: eight more characters in one abstract. This help
    /// prints no `<subcommand>` alternatives in its USAGE line to
    /// cross-check against (`USAGE: macscp-cli <subcommand>`), so the column
    /// is the anchor.
    ///
    /// `internal` rather than private so the parse can be measured against a
    /// fixture without launching anything.
    static func parseSubcommands(_ help: String) -> [String] {
        let entryIndent = 2
        let lines = help.split(separator: "\n", omittingEmptySubsequences: false)
        guard let heading = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "SUBCOMMANDS:" })
        else { return [] }
        var names: [String] = []
        for line in lines[lines.index(after: heading)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard line.prefix(while: { $0 == " " }).count == entryIndent else { continue }
            guard let name = line.split(separator: " ", omittingEmptySubsequences: true).first
            else { continue }
            names.append(String(name))
        }
        return names
    }

    /// Whether `command` takes `GlobalOptions` — the connection flags — read
    /// from that command's OWN help rather than written down here.
    ///
    /// Not every subcommand takes them. `SessionsCommand` declares
    /// `JSONOptions` instead (`Sources/MacSCPCLI/SessionsCommand.swift`),
    /// deliberately: it opens no connection and resolves no secret, so
    /// advertising `--verbose`, `--non-interactive`, `--accept-new` and
    /// `--password-command` in its help would describe choices it never
    /// makes. Handing it one anyway is a usage error, not a harmless extra —
    /// measured 2026-09-04, `macscp-cli sessions --accept-new` exits 64 with
    /// `Error: Unknown option '--accept-new'`.
    ///
    /// So a matrix that builds ONE uniform argument vector cannot simply put
    /// `--accept-new` in it. `hostKeyFlags(for:binary:)` below is what Task 2
    /// builds vectors through.
    ///
    /// The question is put to the binary, so the answer follows a subcommand
    /// that changes its mind. Cached per binary and command; a race just asks
    /// twice.
    static func takesConnectionFlags(_ command: String, binary: URL) async throws -> Bool {
        try await advertisedOptions(for: command, binary: binary).contains("--accept-new")
    }

    /// One command's `--help`, read once per binary and command. A race just
    /// asks twice and stores the same answer.
    static func helpText(for command: String, binary: URL) async throws -> String {
        let key = "\(binary.path(percentEncoded: false))\u{0}\(command)"
        if let cached = helpCache.withLock({ $0[key] }) { return cached }
        let result = try await SubprocessRunner.run(binary, arguments: ["help", command])
        guard result.status == 0 else { throw CLIMatrixError.helpFailed(status: result.status) }
        helpCache.withLock { $0[key] = result.stdoutText }
        return result.stdoutText
    }

    private static let helpCache = Mutex<[String: String]>([:])

    /// The option NAMES `command` advertises — the flag axis of the matrix,
    /// read from the binary the same way the command axis is.
    static func advertisedOptions(for command: String, binary: URL) async throws -> Set<String> {
        parseOptionNames(try await helpText(for: command, binary: binary))
    }

    /// The values `option` accepts on `command`, or `nil` where the option
    /// exists but names no closed set (and where the option does not exist
    /// at all — the caller that cares which asks `advertisedOptions` too).
    static func allowedValues(
        of option: String, for command: String, binary: URL
    ) async throws -> [String]? {
        parseAllowedValues(of: option, in: try await helpText(for: command, binary: binary))
    }

    /// The `OPTIONS:` block, one entry per option, each with its wrapped
    /// abstract joined back onto it.
    ///
    /// Same anchor as `parseSubcommands`: an entry starts at column 2 and a
    /// continuation at column 26, so an abstract that wraps is folded into
    /// the entry it belongs to rather than read as a new one. The block ends
    /// at the first blank line, as ArgumentParser prints it.
    ///
    /// `internal` so the parse can be measured against a fixture without
    /// launching anything — which is where the wrapped shapes below are
    /// pinned, since nothing in today's `--help` happens to wrap them all.
    static func optionEntries(_ help: String) -> [String] {
        let entryIndent = 2
        let lines = help.split(separator: "\n", omittingEmptySubsequences: false)
        guard let heading = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "OPTIONS:"
        }) else { return [] }
        var entries: [String] = []
        for line in lines[lines.index(after: heading)...] {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { break }
            if line.prefix(while: { $0 == " " }).count == entryIndent {
                entries.append(text)
            } else if !entries.isEmpty {
                entries[entries.count - 1] += " " + text
            }
        }
        return entries
    }

    /// The names an entry declares, and ONLY those: the leading run of
    /// `-x`/`--long` tokens, with `<placeholder>` skipped, stopping at the
    /// first word of the abstract.
    ///
    /// The stop is the point. `rm`'s `--allow-root-delete` abstract reads
    /// "Required together with --recursive to delete a session root.", so a
    /// `contains("--recursive")` over that help answers yes for a command
    /// whose help merely MENTIONS the flag. That is this project's
    /// "source-scanning guards read comments too" hazard, one layer over —
    /// a help screen's prose is indistinguishable from its option list to a
    /// substring check — and it is closed structurally here rather than
    /// noted, because the two cases that matter most in Task 2 are exactly
    /// negative ones: `put` and `get` advertise no `--recursive`.
    static func leadingOptionNames(of entry: String) -> [String] {
        var names: [String] = []
        for token in entry.split(separator: " ", omittingEmptySubsequences: true) {
            let cleaned = String(token.hasSuffix(",") ? token.dropLast() : token)
            if cleaned.hasPrefix("-") {
                names.append(cleaned)
            } else if cleaned.hasPrefix("<") {
                continue
            } else {
                break
            }
        }
        return names
    }

    static func parseOptionNames(_ help: String) -> Set<String> {
        Set(optionEntries(help).flatMap(leadingOptionNames(of:)))
    }

    /// The closed value set ArgumentParser prints for an option with an
    /// `ExpressibleByArgument`, `CaseIterable` type: `(values: fail, skip,
    /// overwrite; default: fail)`.
    ///
    /// Read off the JOINED entry, because that parenthesis wraps in today's
    /// help — `--on-conflict`'s list breaks between `default:` and `fail)`
    /// (measured 2026-09-04 against `macscp-cli help put`), so a per-line
    /// parse would find an unterminated `(values:` and answer nothing.
    static func parseAllowedValues(of option: String, in help: String) -> [String]? {
        guard let entry = optionEntries(help).first(where: {
            leadingOptionNames(of: $0).contains(option)
        }) else { return nil }
        guard let opening = entry.range(of: "(values: ") else { return nil }
        let rest = entry[opening.upperBound...]
        guard let end = rest.firstIndex(where: { $0 == ";" || $0 == ")" }) else { return nil }
        return rest[..<end]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The host-key flag `command` should be given, or nothing where it does
    /// not take one. `--accept-new` where the command can open a connection:
    /// SSH is the backend that has host keys, and the flag is inert (not
    /// rejected) on the others, so one derived vector serves every backend.
    static func hostKeyFlags(for command: String, binary: URL) async throws -> [String] {
        try await takesConnectionFlags(command, binary: binary) ? ["--accept-new"] : []
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

/// What a case left on the rig, so the scaffolding can remove it on BOTH
/// exits.
///
/// An `actor` rather than a class with a lock: it is written from inside an
/// `async` case body and read by the scaffolding around it, which is
/// precisely the value that has to cross an isolation boundary here. A
/// `final class` would need `@unchecked Sendable` to compile in this
/// language mode, i.e. an assertion instead of a check.
///
/// Two lists, not one with a flag consulted later: a path is registered as
/// the thing it IS at the moment it is created, and `removeRemote` and
/// `removeRemoteTree` are not interchangeable on this rig (see
/// `CLIMatrix.removeRemoteTree`).
actor RemoteLitter {
    private var entries: [(path: String, isTree: Bool)] = []

    func file(_ path: String) { entries.append((path, false)) }
    func tree(_ path: String) { entries.append((path, true)) }

    /// Hands the list over and forgets it, so a second drain cannot record a
    /// second issue about a path the first one already removed.
    fileprivate func drain() -> [(path: String, isTree: Bool)] {
        defer { entries = [] }
        return entries
    }
}

extension CLIMatrix {
    /// Runs `body` with a rig, an open connection to it and a place to
    /// register remote paths, then removes every registered path and
    /// disconnects — on the throwing path too.
    ///
    /// Written out rather than `defer`red because a `defer` body cannot
    /// `await`, which is the same constraint Task 1's single case handled
    /// with a closure both exits call. Counted 2026-09-04, nine case bodies
    /// in `CLIMatrixCases` go through this one, which is why it is a
    /// scaffold rather than a repeated closure: forgetting the throwing exit
    /// does not fail anything, it just leaves a file on a WebDAV container
    /// that has no volume.
    ///
    /// `sourceLocation` is forwarded so a cleanup issue is recorded against
    /// the CASE's own `withRig` line rather than against this function.
    static func withRig(
        _ kind: ConnectionKind, label: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: (CLIMatrix, any RemoteFileSystem, RemoteLitter) async throws -> Void
    ) async throws {
        let rig = try CLIMatrix.make(for: kind, label: label)
        defer { rig.tearDown() }
        let fileSystem = try await rig.connect()
        let litter = RemoteLitter()

        func clean() async {
            for entry in await litter.drain() {
                if entry.isTree {
                    await rig.removeRemoteTree(
                        fileSystem, path: entry.path, sourceLocation: sourceLocation)
                } else {
                    await rig.removeRemote(
                        fileSystem, path: entry.path, sourceLocation: sourceLocation)
                }
            }
            await fileSystem.disconnect()
        }

        do {
            try await body(rig, fileSystem, litter)
        } catch {
            await clean()
            throw error
        }
        await clean()
    }

    /// A local directory that exists for the duration of `body` and is gone
    /// afterwards — `get`'s destination, and `put`'s source directory.
    static func withLocalDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-matrix-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try await body(directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        try? FileManager.default.removeItem(at: directory)
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
