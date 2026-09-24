import Foundation
import MacSCPTestSupport
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
    /// child's environment, in `environment(secretVariable:)` below — under
    /// this backend's own variable for an ordinary run, and under
    /// `secretRelayVariable` for a `--password-command` one, which is still
    /// the environment and still nothing else. `leaksSecret(_:)` reads it to
    /// answer a question ABOUT it and returns a `Bool`, never the value.
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
    ///
    /// `secretVariable` is the ONE variable the secret is written to, or
    /// `nil` for a child that gets no secret at all. It is a parameter
    /// rather than always `descriptor.secretEnvironmentVariable` because
    /// the `--password-command` case needs both of the other two shapes: a
    /// child with no secret anywhere (the control that makes the positive
    /// run mean something) and a child whose secret sits in a variable the
    /// CLI itself never reads, so that only the helper command can deliver
    /// it. Neither shape puts the value anywhere but the environment.
    private func environment(secretVariable: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for other in ConnectionKind.allCases {
            if let variable = BackendDescriptor.descriptor(for: other).secretEnvironmentVariable {
                environment.removeValue(forKey: variable)
            }
        }
        environment.removeValue(forKey: CLIMatrix.secretRelayVariable)
        if let secretVariable {
            environment[secretVariable] = secret
        }
        environment["MACSCP_STORAGE_DIRECTORY"] = storageDirectory.path(percentEncoded: false)
        return environment
    }

    /// The variable the `--password-command` cases relay the secret through:
    /// the child's environment under a name the CLI reads for no backend, so
    /// the ONLY way it can reach a connect is the helper command the case
    /// hands to `--password-command`.
    ///
    /// `noBackendReadsTheSecretRelayVariable` holds it to that — the name is
    /// compared against every backend's own `secretEnvironmentVariable`
    /// rather than eyeballed, because a collision would silently turn the
    /// positive run into a test of `EnvironmentSecretSource`.
    static let secretRelayVariable = "MACSCP_CLI_MATRIX_RELAY"

    /// What `--verbose` prints the answering source's label after
    /// (`SessionConnecting.resolveSession`, `DiagnoseCommand`). One spelling
    /// in this target, because three cases now look for it — the
    /// `--password-command` route, and the two `diagnose` scopes that pin
    /// which of them prints the line at all.
    static let secretSourceNote = "secret source: "

    /// ArgumentParser's `ExitCode.validationFailure` — what a store verb's
    /// `validate()` produces when it refuses.
    ///
    /// Written here rather than taken from `CLIExitCode` for the reason
    /// `CLISessionsEditingTests` gives: that enum deliberately does not
    /// carry this number, because it is ArgumentParser's and not this
    /// project's. Distinct from `CLIExitCode.usage` (2), which is what a
    /// refusal thrown from `run()` and mapped by `CLIErrorMapping` comes
    /// back as — the two are different codes for different moments and the
    /// cases must not swap them.
    static let validationFailure: Int32 = 64

    /// The bound `runUntilLine` gives a child that is supposed to STAY up.
    ///
    /// Ten minutes: twice the longest `.timeLimit` any suite in THIS target
    /// declares. Five minutes is that longest, in THREE test files —
    /// recounted 2026-09-06 by searching the target's test files for the
    /// five-minute time-limit trait (the pattern is not spelled here on
    /// purpose: a comment that quotes the search string matches itself, and
    /// the recount then reads four): `TunnelRigITests`,
    /// `SubprocessRunnerTests` and `CLIMatrixITests`, the last of which is
    /// where this helper's own
    /// callers live and which gained the trait in the same commit as this
    /// constant. The limits in the target otherwise run 1, 2 and 3, and the
    /// single 10 is in `macSCPAppKitTests`, which drives no child through
    /// this runner. So the harness's own cancellation always wins and this
    /// number decides nothing. It is a net against a child nobody ends — a
    /// `tunnels start` whose SIGINT never arrived would otherwise sit in
    /// `.build` forever — not a statement about how long a forwarding should
    /// take to come up (CLAUDE.md, "A wall-clock ceiling in a test measures
    /// the runner").
    static let heldChildBound: Duration = .seconds(600)

    /// The same environment `run(_:...)` builds for the built binary,
    /// exposed for a caller that drives the binary through something other
    /// than `SubprocessRunner` — `PTYSubprocessTests`' gated pair
    /// (`Tests/macSCPCoreTests/CLIMatrixITests.swift`), which needs a real
    /// pseudo-terminal on stdin rather than the null device
    /// `SubprocessRunner` always hands the child.
    func environmentForPTY() -> [String: String] {
        environment(secretVariable: descriptor.secretEnvironmentVariable)
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
    ///
    /// `onStdoutChunk` defaults to `nil` for every case that only wants the
    /// settled result — it exists for
    /// `CLIMatrixDiagnoseITests.rowsArriveInMoreThanOneChunk`, which has to
    /// count stdout reads as they land rather than only see what the child
    /// left behind once it was gone.
    @discardableResult
    func run(
        _ arguments: [String],
        onStdoutChunk: (@Sendable (Data) -> Void)? = nil
    ) async throws -> SubprocessResult {
        try await SubprocessRunner.run(
            try CLIMatrix.binaryURL(), arguments: arguments,
            environment: environment(secretVariable: descriptor.secretEnvironmentVariable),
            onStdoutChunk: onStdoutChunk)
    }

    /// Runs the binary with the secret in `variable` INSTEAD of the backend's
    /// own secret variable — the environment a `--password-command` case
    /// needs, where the helper command is the only route the secret has.
    @discardableResult
    func run(_ arguments: [String], secretRelayedThrough variable: String) async throws
        -> SubprocessResult
    {
        try await SubprocessRunner.run(
            try CLIMatrix.binaryURL(), arguments: arguments,
            environment: environment(secretVariable: variable))
    }

    /// Runs the binary with NO secret in the environment at all: every
    /// backend's variable is removed and none is set. The control a
    /// `--password-command` case is measured against — without it, a run that
    /// succeeds proves only that SOMETHING answered.
    @discardableResult
    func runWithoutASecret(_ arguments: [String]) async throws -> SubprocessResult {
        try await SubprocessRunner.run(
            try CLIMatrix.binaryURL(), arguments: arguments,
            environment: environment(secretVariable: nil))
    }

    /// Runs the binary for a STORE verb: this rig's storage directory, and
    /// no secret variable anywhere in the child's environment.
    ///
    /// `sessions add/edit/rm` and `tunnels add/edit/list/rm` read and write
    /// two JSON files and dial nothing, so a secret in their environment
    /// would be a value the case put there for no reason — and a case that
    /// passed only because one was present would be measuring the wrong
    /// thing. The rig's own `secret` stays `private` and unused here.
    ///
    /// The environment is the same one `runWithoutASecret(_:)` builds, and
    /// the two are deliberately separate names for it: that one is the
    /// CONTROL a `--password-command` case is measured against, and this one
    /// is how the store verbs are always run. They share a body today; a
    /// change to either reason moves only its own caller.
    @discardableResult
    func runStore(_ arguments: [String]) async throws -> SubprocessResult {
        try await runWithoutASecret(arguments)
    }

    /// Whether the environment `runStore(_:)` hands a child carries this
    /// rig's secret ANYWHERE — under a backend's own variable, under the
    /// relay variable, or as the value of any variable at all.
    ///
    /// A `Bool` computed inside the only type that holds the value, for the
    /// reason `leaksSecret(_:)` states: `#expect` prints the SOURCE TEXT of
    /// the expression it checked, so a test that compared an environment
    /// against the secret would print the secret in the failure that says it
    /// leaked (CLAUDE.md, "A value a test must not leak has two exits, not
    /// one").
    ///
    /// The value scan is the half that is not a restatement of
    /// `environment(secretVariable:)`'s own code: the variable-name checks
    /// follow the same list that function scrubs from, so on their own they
    /// would be that function agreeing with itself. Scanning the VALUES
    /// catches a secret that reached the child under a name nobody thought
    /// of — an ambient variable in the developer's shell among them, which
    /// is the case the scrub exists for.
    func storeEnvironmentCarriesASecret() -> Bool {
        let environment = environment(secretVariable: nil)
        for kind in ConnectionKind.allCases {
            if let variable = BackendDescriptor.descriptor(for: kind).secretEnvironmentVariable,
               environment[variable] != nil {
                return true
            }
        }
        if environment[CLIMatrix.secretRelayVariable] != nil { return true }
        return environment.values.contains { isTheSecret($0) }
    }

    /// The positive beside it: the environment `run(_:)` hands a DIALLING
    /// child does carry the secret, under this backend's own variable and
    /// nowhere else.
    ///
    /// Without this, "the store verbs' child carries no secret" is satisfied
    /// by an `environment(secretVariable:)` that stopped setting anything at
    /// all — which would leave every dialling case failing for a reason that
    /// looks like the rig being down.
    func dialEnvironmentCarriesTheSecretUnderItsOwnVariable() -> Bool {
        guard let variable = descriptor.secretEnvironmentVariable else { return false }
        let environment = environment(secretVariable: variable)
        guard let value = environment[variable], isTheSecret(value) else { return false }
        return environment.filter { isTheSecret($0.value) }.count == 1
    }

    /// The `sessions add` argument vector that saves a SECOND session of this
    /// rig's own kind, derived from the fixture's own stored configuration
    /// rather than written out per backend in a case.
    ///
    /// EXHAUSTIVE over `ConnectionKind`, like `fixture(for:name:)`: a fourth
    /// protocol does not compile here until someone says which flags `add`
    /// needs for it. The flags themselves are the required ones
    /// `SessionFieldOptions.requiredFields(for:)` lists, plus the ones this
    /// rig's fixture actually sets — the port SSH is reached on, S3's region
    /// and path-style addressing — so the saved session is a usable copy of
    /// the fixture rather than a shape that merely parses.
    ///
    /// No secret is named anywhere in it, and none could be: `sessions add`
    /// takes none (its own `discussion` says so), so the vector carries a
    /// host, a user and a bucket, and the child that runs it goes through
    /// `runStore(_:)`.
    func sessionsAddArguments(named name: String) throws -> [String] {
        var arguments = ["sessions", "add", name, "--kind", kind.rawValue]
        switch kind {
        case .ssh:
            guard let ssh = session.ssh else { throw CLIMatrixError.fixtureHasNoConfig(kind: kind.rawValue) }
            arguments += [
                "--host", ssh.host, "--port", String(ssh.port), "--user", ssh.username,
            ]
        case .s3:
            guard let s3 = session.s3 else { throw CLIMatrixError.fixtureHasNoConfig(kind: kind.rawValue) }
            arguments += [
                "--endpoint", s3.endpoint, "--bucket", s3.bucket,
                "--access-key", s3.accessKeyID, "--region", s3.region,
            ]
            if s3.usePathStyle { arguments.append("--path-style") }
        case .webdav:
            guard let webdav = session.webdav else { throw CLIMatrixError.fixtureHasNoConfig(kind: kind.rawValue) }
            arguments += ["--url", webdav.baseURL, "--user", webdav.username]
            if webdav.useNextcloudPath { arguments.append("--nextcloud") }
        }
        return arguments
    }

    /// Runs the binary, waits for a stdout LINE that satisfies `matching`,
    /// runs `body` while the child is still holding that state, then sends
    /// `SIGINT` and returns the child's settled result.
    ///
    /// The shape `tunnels start` needs and no other verb does: it prints one
    /// line per state change and then stays up until Ctrl-C, so a case about
    /// it has to observe a line, act on the world while the process is
    /// alive, and end it on purpose. Every one of those three is an
    /// observation rather than a wait on a clock — the line arrives through
    /// `SubprocessRunner`'s stdout seam and raises a latch, `body` runs after
    /// the latch, and the ending is a signal this test sends rather than a
    /// deadline anyone set. The only bound is the calling suite's
    /// `.timeLimit`, which cancels this task; `AsyncSignal.wait()` answers
    /// that cancellation, and the child task is then cancelled too, so
    /// `SubprocessRunner`'s own escalation reaps the child rather than
    /// leaving a bound forwarding behind.
    ///
    /// The runner's `timeout` (`heldChildBound`) is deliberately far past any
    /// suite limit here:
    /// it is a net against a child nobody ends, not a statement about how
    /// long the work should take, and a bound tighter than the harness's
    /// would be a wall-clock ceiling deciding a test (CLAUDE.md, "A
    /// wall-clock ceiling in a test measures the runner").
    ///
    /// A child that ENDS before printing a matching line does not park this:
    /// the run task raises the same latch on its way out, and the settled
    /// result — the failed one — is returned for the caller to assert on.
    /// That is what makes this usable for a `tunnels start` that is supposed
    /// to refuse.
    ///
    /// The child's environment is the dialling one (`run(_:)`'s), because
    /// every caller here is a `tunnels start`: the secret rides the
    /// environment and nothing else.
    ///
    /// Partial lines are held back rather than matched: stdout arrives in
    /// chunks, and a predicate looking for `active port=` would otherwise
    /// match half of `active port=6` and read a truncated number. The
    /// predicate itself runs OUTSIDE the scanner's lock: it is
    /// caller-supplied code, and a lock held across arbitrary code is a lock
    /// held across anything.
    ///
    /// EVERY wait on the child's result goes through `settle()`, which
    /// answers this task's cancellation by cancelling the child. Without it
    /// the last of them — the one after the `SIGINT` — is a wait a
    /// cancellation cannot reach: a child that IGNORES the signal parks the
    /// run until `heldChildBound`, ten minutes after the suite's five-minute
    /// limit already recorded its red, which is exactly the shape
    /// `PollingGuardTests.noBareContinuationEscapesAwaitResumption`
    /// condemns ("the 'exceeded' report is not the process actually
    /// stopping"). `aChildThatIgnoresTheInterruptDoesNotOutliveACancelledCaller`
    /// is the measurement.
    @discardableResult
    func runUntilLine(
        _ arguments: [String],
        matching predicate: @escaping @Sendable (String) -> Bool,
        _ body: (String) async throws -> Void = { _ in }
    ) async throws -> SubprocessResult {
        try await CLIMatrix.runUntilLine(
            try CLIMatrix.binaryURL(),
            arguments: arguments,
            environment: environment(secretVariable: descriptor.secretEnvironmentVariable),
            matching: predicate,
            body)
    }

    /// The same run, over any executable — the shape a test of THIS helper
    /// needs, since the property that matters (a caller's cancellation is
    /// answered even by a child that ignores `SIGINT`) cannot be asked of
    /// `macscp-cli`, which handles the signal correctly.
    ///
    /// The binary comes FIRST, exactly as `SubprocessRunner.run`'s does, so
    /// this overload cannot enter `drivenSubcommands`' driven set: a call
    /// through it is a guard driving a fixture, not a case driving a
    /// subcommand.
    @discardableResult
    static func runUntilLine(
        _ binary: URL,
        arguments: [String],
        environment childEnvironment: [String: String]?,
        matching predicate: @escaping @Sendable (String) -> Bool,
        _ body: (String) async throws -> Void = { _ in }
    ) async throws -> SubprocessResult {
        let scanner = Mutex(LineScan())
        let settledOrMatched = AsyncSignal()
        let childPID = Mutex<Int32?>(nil)
        // Read before the `kill` below. `SubprocessRunner` hands over the pid
        // and Foundation reaps the child on its own, so a number that named
        // this child a moment ago can name somebody else's process by the
        // time a `body` returns — signalling it would be signalling a
        // stranger.
        let childIsOver = Mutex(false)

        let observe: @Sendable (Data) -> Void = { chunk in
            // Complete lines are taken out under the lock; the predicate runs
            // outside it (see the doc comment). A second pass takes the lock
            // again to claim the first match, so two chunks racing still
            // produce one `matched` and one signal.
            let candidates = scanner.withLock { scan -> [String] in
                guard scan.matched == nil else { return [] }
                scan.pending += String(decoding: chunk, as: UTF8.self)
                var lines = scan.pending.components(separatedBy: "\n")
                scan.pending = lines.removeLast()
                return lines
            }
            guard let hit = candidates.first(where: predicate) else { return }
            let claimed = scanner.withLock { scan -> Bool in
                guard scan.matched == nil else { return false }
                scan.matched = hit
                return true
            }
            if claimed { settledOrMatched.signal() }
        }

        // `Task`, not a task group: this task's own cancellation is answered
        // explicitly by `settle()` below, and an unstructured child keeps
        // `body` — which is not `@Sendable` and captures the caller's
        // channels and inboxes — out of a `sending` closure entirely.
        let child = Task { () -> SubprocessResult in
            defer {
                childIsOver.withLock { $0 = true }
                settledOrMatched.signal()
            }
            return try await SubprocessRunner.run(
                binary, arguments: arguments, environment: childEnvironment,
                timeout: CLIMatrix.heldChildBound,
                onStdoutChunk: observe,
                onStarted: { pid in childPID.withLock { $0 = pid } })
        }

        /// Waits for the child's result, and cancels the child if THIS task
        /// is cancelled while waiting. `Task.value` on its own ignores the
        /// awaiting task's cancellation — the defect
        /// `CLITunnelForegroundRunTests` hit from the other side — so a
        /// suite `.timeLimit` would record a red and then leave the run
        /// going.
        func settle() async throws -> SubprocessResult {
            try await withTaskCancellationHandler {
                try await child.value
            } onCancel: {
                child.cancel()
            }
        }

        if await settledOrMatched.wait() == .cancelled { child.cancel() }
        guard let line = scanner.withLock({ $0.matched }) else {
            // The child ended (or this task was cancelled) before the line
            // came. Its own result — or its own error — is the answer.
            return try await settle()
        }

        do {
            try await body(line)
        } catch {
            child.cancel()
            _ = try? await settle()
            throw error
        }

        // Not signalled at all once the child is known to be over: the pid is
        // valid only until the child exits, and Foundation may already have
        // reaped it. A residual window remains — between Foundation's reap
        // and `SubprocessRunner.run` returning, this flag is still false —
        // and it is left stated rather than closed, because it opens only for
        // a child that has ALREADY ended, whose settled result is the very
        // next thing read.
        if !childIsOver.withLock({ $0 }), let pid = childPID.withLock({ $0 }) {
            kill(pid, SIGINT)
        }
        return try await settle()
    }

    /// The stdout line scanner's state: what has arrived since the last
    /// newline, and the first complete line the predicate accepted.
    private struct LineScan {
        var pending = ""
        var matched: String?
    }

    /// Whether a connection of this kind can carry a forwarding — Core's own
    /// answer, never a second list here.
    ///
    /// The matrix's cases branch on it (a `tunnels add` succeeds on SSH and
    /// is refused on S3 and WebDAV), and reading it from
    /// `TunnelCarriers.carries(_:)` is what makes the refusal cases a
    /// measurement of the shipped rule rather than an agreement between two
    /// copies of it. A fourth backend that could carry a forwarding changes
    /// the answer here the moment Core's switch says so.
    static func carriesTunnels(_ kind: ConnectionKind) -> Bool {
        TunnelCarriers.carries(kind)
    }

    /// Whether `text` carries this rig's secret.
    ///
    /// The comparison happens HERE, inside the only type that holds the
    /// value, so a case can assert "this output does not leak" without the
    /// secret — or its spelling — ever reaching an expectation's source text.
    /// `#expect` reports the expression it checked, so a literal in the test
    /// would be printed by the very failure that says the secret leaked
    /// (CLAUDE.md, "A value a test must not leak has two exits, not one").
    func leaksSecret(_ text: String) -> Bool {
        text.contains(secret)
    }

    /// Whether `value` IS this rig's secret, rather than merely containing
    /// it — the question the environment checks above ask.
    ///
    /// Separate from `leaksSecret(_:)` because the two are different
    /// questions and the substring one is wrong here: an environment
    /// variable whose value happens to CONTAIN the rig's short password as a
    /// substring (`PATH` with a `testpass` directory in it, a shell prompt
    /// string) is not a secret handed to the child, and reading it as one
    /// would make a negative check red for a reason about the developer's
    /// shell. A leak into OUTPUT is the opposite case: there the secret's
    /// presence anywhere in a stream is the whole point, which is why that
    /// one stays a `contains`.
    ///
    /// Answers a `Bool` for the reason `leaksSecret(_:)` gives: neither the
    /// value nor its spelling may reach an expectation's source text.
    func isTheSecret(_ value: String) -> Bool {
        value == secret
    }

    /// The same question about a whole run, both streams at once — the shape
    /// every case actually asks, and one `Bool` to compute before any
    /// expectation touches either stream.
    func leaksSecret(_ result: SubprocessResult) -> Bool {
        leaksSecret(result.stdoutText) || leaksSecret(result.stderrText)
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
        switch try StoredSessionConnectionConfig.build(for: session, secret: secret, checkedSources: []) {
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
    /// A single `deleteTree` per entry: `RemoteFileSystem.deleteTree`'s
    /// contract — a plain file behaves exactly like `delete` — now holds on
    /// WebDAV (4587c856) and on S3 (e7169c1a), the two backends that used to
    /// need the delete-then-deleteTree fallback this function carried until
    /// this commit.
    ///
    /// `deleteTree` on a path that was never created throws `.notFound` from
    /// its own lookup (4587c856); `try?` tolerates that the same as any
    /// other outcome, and it is `verifyGone` below, not this call, that
    /// decides pass or fail — a path already absent reads back `.notFound`
    /// there too and is not reported. That is exactly the shape a case
    /// takes when it fails before the `seed`/`write` that would have
    /// created what its litter registration named (litter entries are
    /// registered ahead of the call that creates them, e.g.
    /// `litter.file(remotePath)` before `rig.seed(...)` at
    /// `CLIMatrixITests.swift:57-58`).
    func removeRemote(
        _ fileSystem: any RemoteFileSystem, path: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        try? await fileSystem.deleteTree(at: path)
        await verifyGone(fileSystem, path: path, sourceLocation: sourceLocation)
    }

    /// Removes a DIRECTORY and everything under it, and verifies the same
    /// way `removeRemote` does.
    ///
    /// A separate entry point from `removeRemote`, not because the two
    /// behave differently any more — both are now a single `deleteTree`
    /// plus `verifyGone` — but because `RemoteLitter` already knows at
    /// registration time whether a path is a file or a directory
    /// (`.file`/`.tree`), and passing that knowledge through as a call
    /// choice needs no runtime branch here. Before 4587c856 (WebDAV) and
    /// e7169c1a (S3) the two calls were not interchangeable: `removeRemote`
    /// on a directory did not clean it up on S3 (`delete` resolved the
    /// directory's marker key and the bare key to the same string, and
    /// `DeleteObject` answered success for a key nothing had written), and
    /// `removeRemoteTree` on a file threw 400 on WebDAV and deleted nothing
    /// on S3. That history, not a live asymmetry, is why both entry points
    /// still exist.
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
        // The removal ATTEMPT above is best-effort on purpose — a case that
        // failed before it seeded anything has nothing to remove, and the
        // caller should not turn that into a second failure. Both
        // `removeRemote` and `removeRemoteTree` make exactly one attempt
        // (`deleteTree` alone) and swallow whatever it throws with `try?`.
        // The OUTCOME is not best-effort either way: a `try?` with nothing
        // after it is exactly the shape that let the S3 and WebDAV
        // divergence above go unnoticed through a full green run, and Task 2
        // multiplies the cases that could hide it again. So the entry is
        // looked for afterwards, and its survival is recorded against the
        // caller's own line.
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

    // MARK: - Host keys

    /// Whether this backend authenticates the SERVER with a key the client
    /// remembers — what `--accept-new`, `--non-interactive` and TOFU are
    /// about — PRINTING the reason when it does not, the same way
    /// `supports(_:named:operation:)` does.
    ///
    /// It IS a `ProtocolCapabilities` axis now (`authenticatesHostKey`,
    /// `Sources/macSCPCore/Capabilities/ProtocolCapabilities.swift`): this
    /// used to read the answer off an exhaustive switch over the connection
    /// config the CLI itself builds, because no such axis existed —
    /// `transport` was the near-miss wrong answer (SSH `.alwaysEncrypted`,
    /// S3/WebDAV `.optionalTLS`, which is a statement about the channel, not
    /// about whether the client remembers the server's identity — a WebDAV
    /// vhost on TLS is still `.optionalTLS` and still has no host key). The
    /// switch itself, and the reasoning behind each arm — SSH's `connect`
    /// closure is the one that forwards `HostKeyDecider` to a real
    /// host-key-consuming API, WebDAV authenticates the server through a
    /// SEPARATE certificate decider instead — now lives on the descriptor's
    /// own capability. `BackendDescriptorTests
    /// .authenticatesHostKeyMatchesWhichBackendsConnectClosureUsesTheDecider`
    /// PINS the three values as a hand-written second copy, so a change to
    /// one must be made to the other on purpose;
    /// `BackendDescriptorHostKeyWiringGuardTests` is what actually reads
    /// `BackendDescriptor.swift`'s three `connect` closures and checks each
    /// against its own descriptor's declared value.
    ///
    /// The value is a claim about the backends, so it is not left as one:
    /// `anUnknownHostKeyIsRefusedUntilAccepted` drives BOTH sides of it
    /// against the rig — a backend this answers `true` for must refuse
    /// `--non-interactive` and record exactly one key under `--accept-new`,
    /// and a backend it answers `false` for must connect with neither flag
    /// mattering and record nothing.
    func hasHostKeys(operation: String) throws -> Bool {
        let has = capabilities.authenticatesHostKey
        if !has {
            print("""
                CLIMatrix: skipping \(operation) on \(kind.rawValue) — this \
                backend authenticates no host key
                """)
        }
        return has
    }

    /// The host keys the CHILD remembered, read out of the temporary store
    /// the child was pointed at — the same `known_hosts.json` the CLI writes
    /// through `KnownHostsStore`, and nowhere near the developer's own.
    func recordedHostKeys() throws -> [KnownHostKey] {
        try KnownHostsStore(directory: storageDirectory).allKeys()
    }

    /// Replaces the remembered key for the host it was recorded against with
    /// a DIFFERENT one, and returns what was planted.
    ///
    /// Derived from the key the rig actually presented rather than written
    /// down: the recorded blob is decoded, its last byte inverted, and the
    /// result put back under the same host and port. So this file carries no
    /// key material of its own (CLAUDE.md: test keys are generated at
    /// runtime), the planted key is guaranteed to differ from the real one,
    /// and the host and port come from the entry the connect itself wrote —
    /// not from a literal that would have to track the rig's coordinates.
    func plantADifferentHostKey() throws -> KnownHostKey {
        let store = KnownHostsStore(directory: storageDirectory)
        guard let real = try store.allKeys().first else {
            throw CLIMatrixError.noHostKeyRecorded(kind: kind.rawValue)
        }
        guard var blob = Data(base64Encoded: real.publicKeyBase64), !blob.isEmpty else {
            throw CLIMatrixError.unreadableHostKey(kind: kind.rawValue)
        }
        blob[blob.index(before: blob.endIndex)] ^= 0xFF
        let planted = KnownHostKey(
            host: real.host, port: real.port, keyType: real.keyType,
            publicKeyBase64: blob.base64EncodedString())
        try store.upsert(planted)
        return planted
    }

    // MARK: - The binary, and what it says it can do

    /// Exists only so `binaryURL()` has a class defined in THIS file to hand
    /// `Bundle(for:)`.
    private final class TestBundleAnchor {}

    /// Locates the already-built `macscp-cli` binary. The one definition in
    /// this target: every gated case calls through it, `CLIRoundtripITests`
    /// included since 2026-09-04, and so does every ungated suite that runs
    /// the binary. Each of those used to carry its own copy of exactly this
    /// lookup, under the name `locateCLIBinary()` —
    /// `CLIRoundtripITests`' was folded in when Task 4 of the CLI test
    /// matrix plan closed out, and the remaining SIX on 2026-09-10 (counted
    /// in that pass, one per file: `CLICompletionScriptTests`,
    /// `CLIRootHelpTests`, `CLISessionNameCompletionTests`,
    /// `CLISessionsJSONRoundtripTests`, `CLISessionsEditingTests`,
    /// `CLITunnelsEditingTests`). The suites that want a path rather than a
    /// URL call `binaryPath()` below.
    ///
    /// It deliberately does NOT run `swift build`. A test running under
    /// `swift test` is inside a process that holds SwiftPM's lock on
    /// `.build`; a nested `swift build` waits for that lock, which waits for
    /// the test — a deadlock with no timeout, which is exactly how
    /// `CLIRoundtripITests` first hung. SwiftPM says so plainly if you try:
    /// "Another instance of SwiftPM is already running using '.build',
    /// waiting until that process has finished execution..."
    ///
    /// So the binary is located, not produced: `swift test` has already
    /// built every product into the same directory the test bundle lives
    /// in, so the sibling next to the bundle IS the current source tree's
    /// output. `MACSCP_CLI_BINARY` overrides for anyone running the bundle
    /// from somewhere unusual.
    ///
    /// The lookup is BUNDLE-relative, not repo-root-relative — an earlier
    /// version read `<repoRoot>/.build/debug/macscp-cli` directly, which
    /// only matches the default `swift test` invocation. It hard-failed
    /// under `swift test --scratch-path <tmp>` (products land in
    /// `<tmp>/debug`, not `<repoRoot>/.build/debug`) and under `swift test
    /// -c release` (products land in `.build/release`) — both real
    /// invocations (`scripts/hang-hunt` uses `--scratch-path`), and both
    /// silently pointed the test at a binary that was never built
    /// (final-branch-review finding, 2026-09-02). `Bundle(for:)` on
    /// `TestBundleAnchor`, a class defined right here, always resolves to
    /// the `.xctest` bundle `swift test` just built and loaded this code
    /// from; `.build/debug` and `.build/release` both put the `macscp-cli`
    /// product as that bundle's own sibling, so walking up one level from
    /// the bundle finds it regardless of which products directory this
    /// particular run used.
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

    /// `binaryURL()` as a path, which is what the suites that hand the
    /// binary straight to a subprocess want. A forward, not a second
    /// lookup: everything the doc comment above says applies here.
    static func binaryPath() throws -> String {
        try binaryURL().path(percentEncoded: false)
    }

    /// The subcommands the binary itself offers, read from its `--help`.
    ///
    /// The matrix's command axis, and read rather than written down: a
    /// ninth subcommand appears here the moment it appears in
    /// `MacSCPCLI.configuration.subcommands`, without an edit in this target
    /// — which is exactly what the seventh, `diagnose`, did on 2026-09-04
    /// and the eighth, `tunnels`, did on 2026-09-06. A list typed here would
    /// instead go on passing while covering seven of eight commands.
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
    /// name the moment an abstract wrapped. Nothing wraps today — recounted
    /// 2026-09-06 from the built binary's own `--help`, all EIGHT rows fit on
    /// one line, the widest being `tunnels` at 75 columns against
    /// ArgumentParser's 80 (75 since `start` joined the group and its
    /// abstract gained "and run"; it was 70 before), then `get` at 72, `put`
    /// 70, `diagnose` 69 and `sessions` 68 (68 since it became a group) — so
    /// the hazard was invisible and entirely reachable: FIVE more characters
    /// in one abstract. The count said six
    /// until the recount of 2026-09-04, when `diagnose` had been the seventh
    /// row and the sentence went on claiming six; `tunnels` made it eight on
    /// 2026-09-06. This help
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
    /// Not every subcommand takes them — THREE do not, recounted 2026-09-06
    /// and named by `theConnectionFlagsAreAskedForPerCommand`, which reads
    /// the list off the binary rather than off this comment.
    /// `SessionsCommand` declares `JSONOptions`
    /// (`Sources/MacSCPCLI/SessionsCommand.swift`) because it opens no
    /// connection and resolves no secret; `TunnelsCommand`
    /// (`Sources/MacSCPCLI/TunnelsCommand.swift`) declares nothing at all at
    /// the GROUP level for the same reason — its four store verbs only read
    /// and write two JSON files — while its fifth verb `start`
    /// (`Sources/MacSCPCLI/TunnelStartCommand.swift`) declares them itself,
    /// because it is the one that dials; `DiagnoseCommand` declares
    /// `DiagnoseOptions`
    /// (`Sources/MacSCPCLI/DiagnoseCommand.swift`) because it resolves a
    /// secret but decides no host key — its dial answers that question with
    /// `HostKeyDecider.refusing` inside Core. Either way, advertising
    /// `--accept-new` and `--non-interactive` would describe choices the
    /// command never makes. Handing one over anyway is a usage error, not a
    /// harmless extra — measured 2026-09-04, `macscp-cli sessions
    /// --accept-new` exits 64 with `Error: Unknown option '--accept-new'`.
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
    ///
    /// `command` may name a NESTED verb, spelled with spaces the way it is
    /// typed: `"tunnels start"` asks `macscp-cli help tunnels start`. That is
    /// what lets `takesConnectionFlags` be asked about a verb whose group
    /// declares different flags than it does — which is the shape `tunnels`
    /// has carried since `start` arrived (2026-09-06): the group advertises
    /// none and `start` advertises the connection flags.
    static func helpText(for command: String, binary: URL) async throws -> String {
        let key = "\(binary.path(percentEncoded: false))\u{0}\(command)"
        if let cached = helpCache.withLock({ $0[key] }) { return cached }
        let path = command.split(separator: " ").map(String.init)
        let result = try await SubprocessRunner.run(binary, arguments: ["help"] + path)
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

/// One entry of `sessions --json`, decoded — the same strictness
/// `CLIListedItem` is decoded with, and for the same reason: a renamed key
/// must fail the case, not empty the comparison.
///
/// `group` and `tags` have no `null` state to carry (`SessionCatalog.Row`'s
/// `groupPath` is already `""` at top level and `tags` already `[]` when
/// untagged), so neither is optional here.
struct CLISessionRow: Decodable, Equatable, Sendable {
    let name: String
    let kind: String
    let target: String
    let group: String
    let tags: [String]
}

extension CLIMatrix {
    /// Decodes `sessions --json`: one JSON object per line, every non-empty
    /// line decoded, nothing skipped.
    static func sessionRows(_ stdout: String) throws -> [CLISessionRow] {
        let decoder = JSONDecoder()
        return try stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(CLISessionRow.self, from: Data($0.utf8)) }
    }

    /// The KEYS of every object `sessions --json` printed, per line.
    ///
    /// Decoding answers what the matrix reads; this answers what the binary
    /// WROTE, which is the question a leak has to be caught by: a field added
    /// to `SessionCatalog.Row` — a key path, a login-set id, a secret handle
    /// of any shape — reaches stdout without any decode here failing.
    static func sessionRowKeys(_ stdout: String) throws -> [Set<String>] {
        try stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                guard let dictionary = object as? [String: Any] else {
                    throw CLIMatrixError.unreadableSessionRow
                }
                return Set(dictionary.keys)
            }
    }
}

extension CLIMatrix {
    /// Decodes `tunnels list --json`: one JSON object per line, every
    /// non-empty line decoded into Core's own `TunnelRow`, nothing skipped.
    ///
    /// `TunnelRow` rather than a shape declared here, because that type IS
    /// the `--json` contract — `TunnelsListCommand` hands the very same
    /// values to `OutputFormatter` — so a renamed property is one break in
    /// one place rather than a listing that quietly decodes into a row with
    /// a default in it.
    ///
    /// Strict, for the reason `listing` states: a `compactMap { try? … }`
    /// turns a line the decoder could not read into a row that is simply
    /// absent, and an emptiness assertion is exactly what that satisfies.
    static func tunnelRows(_ stdout: String) throws -> [TunnelRow] {
        let decoder = JSONDecoder()
        return try stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(TunnelRow.self, from: Data($0.utf8)) }
    }
}

/// One line of `tunnels start --json`, decoded — the same strictness
/// `CLIListedItem`, `CLISessionRow` and `TunnelRow` are decoded with, and for
/// the same reason: a renamed key must fail the case, not empty the
/// comparison.
///
/// `state` is the only required field, which is `TunnelStateLine.jsonLine`'s
/// own shape: `connections` and `port` appear on an `active` line (and
/// `port` only when one is bound), `attempt` on a `reconnecting` one, and
/// `reason` on a `failed` one.
///
/// Decoded rather than compared as text, because the object's keys are
/// SORTED (`JSONSerialization` with `.sortedKeys`) and a JSON object is
/// unordered anyway — a case that compared the line would be asserting on a
/// serialiser's choice.
struct CLITunnelStateLine: Decodable, Equatable, Sendable {
    let state: String
    let port: Int?
    let connections: Int?
    let attempt: Int?
    let reason: String?
}

extension CLIMatrix {
    /// Decodes `tunnels start --json`: one JSON object per line, every
    /// non-empty line decoded, nothing skipped.
    static func tunnelStateLines(_ stdout: String) throws -> [CLITunnelStateLine] {
        let decoder = JSONDecoder()
        return try stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(CLITunnelStateLine.self, from: Data($0.utf8)) }
    }

    /// The `state` value `--json` writes for one state, read off the
    /// RENDERER rather than spelled a second time here — the same derivation
    /// `outcomeKey(for:)` makes for `diagnose`.
    ///
    /// `TunnelStateLine`'s own `key(_:)` is private, and deliberately: the
    /// programmatic spelling is the renderer's to choose. Asking it to
    /// render a sample and reading the field back is how a script would
    /// learn it too, and it means a renamed spelling moves every case with
    /// it instead of leaving one comparing against a word nothing prints.
    static func tunnelStateKey(for state: TunnelState) throws -> String {
        let line = TunnelStateLine.render(state, json: true)
        return try JSONDecoder().decode(CLITunnelStateLine.self, from: Data(line.utf8)).state
    }

    /// The prefix an `active` TEXT line carries when a port is bound —
    /// `active port=` — derived by rendering one with a known port and
    /// dropping that port's own digits, so nothing here spells either half.
    ///
    /// The sample is `UInt16.max`, which is a real port and therefore a
    /// number the renderer cannot treat specially.
    static let activePortPrefix: String = {
        let sample = Int(UInt16.max)
        let rendered = TunnelStateLine.render(.active(connections: 0), port: sample, json: false)
        return String(rendered.dropLast("\(sample)".count))
    }()

    /// The port an `active` text line reports, or `nil` when the line is not
    /// one or carries no port.
    static func boundPort(inActiveLine line: String) -> Int? {
        guard line.hasPrefix(activePortPrefix) else { return nil }
        return Int(line.dropFirst(activePortPrefix.count).prefix { $0.isNumber })
    }
}

/// One step object of `diagnose --json`, decoded — the same strictness
/// `CLIListedItem` and `CLISessionRow` are decoded with, and for the same
/// reason: a renamed key must fail the case, not empty the comparison.
///
/// `reason` and `hops` are optional BY CONTRACT rather than by leniency.
/// `DiagnoseRendering.jsonObject(for:)` omits `reason` for the two outcomes
/// that carry none (`ok`, `timedOut`) and `hops` for every step but the
/// trace; everything else is required.
struct CLIDiagnosedStep: Decodable, Equatable, Sendable {
    let id: String
    /// The programmatic spelling, not the row's display word: `timedOut`,
    /// never `timed out`. `CLIMatrix.outcomeKeys()` is where a case turns one
    /// back into a `DiagnosticOutcome` without writing either spelling down.
    let outcome: String
    let reason: String?
    let durationMs: Int
    let detail: String
    /// One dictionary per hop, keyed by the trace table's own column headers;
    /// every value a string, `rtt` included (`"0.1 ms"`, or `"—"` for a hop
    /// that answered nothing).
    let hops: [[String: String]]?
}

/// The endpoint a diagnosis names, or `null` where the walk never got that
/// far (`DiagnoseRendering.jsonSummary`).
struct CLIDiagnosedEndpoint: Decodable, Equatable, Sendable {
    let host: String
    let port: Int
}

/// The one summary object `diagnose --json` prints after the last step.
struct CLIDiagnosis: Decodable, Equatable, Sendable {
    let completion: String
    let endpoint: CLIDiagnosedEndpoint?
    let steps: [CLIDiagnosedStep]
}

extension CLIMatrix {
    /// Decodes `diagnose --json`: one JSON object per line — the steps as
    /// they finished, and then the summary — so the LAST line is read as the
    /// summary and every earlier one as a step.
    ///
    /// The split is positional, and the decoder is what makes that safe
    /// rather than a guess: a step object has no `completion` and a summary
    /// has no `id`, both required above, so a line read as the wrong kind
    /// throws instead of decoding into a shape a case would then assert on.
    /// Nothing is skipped, for the reason `listing` states.
    static func diagnosis(_ stdout: String) throws
        -> (streamed: [CLIDiagnosedStep], summary: CLIDiagnosis)
    {
        let decoder = JSONDecoder()
        let lines = stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let last = lines.last else { throw CLIMatrixError.emptyDiagnosis }
        let summary = try decoder.decode(CLIDiagnosis.self, from: Data(last.utf8))
        let streamed = try lines.dropLast().map {
            try decoder.decode(CLIDiagnosedStep.self, from: Data($0.utf8))
        }
        return (streamed, summary)
    }

    /// One sample per `DiagnosticOutcome` case — what the JSON spellings and
    /// the exit rule below are derived FROM, rather than written down.
    ///
    /// EXHAUSTIVE, and structurally so: the `switch` below has no `default`,
    /// so a sixth case on the enum stops compiling here until it is sampled
    /// above. The reason text is one fixed word and nothing reads it back;
    /// it exists because three of the five cases carry a payload.
    static var outcomeSamples: [DiagnosticOutcome] {
        let samples: [DiagnosticOutcome] = [
            .ok, .failed("sample"), .timedOut, .unavailable("sample"), .skipped("sample"),
        ]
        for sample in samples {
            switch sample {
            case .ok, .failed, .timedOut, .unavailable, .skipped: break
            }
        }
        return samples
    }

    /// Each `outcome` spelling `diagnose --json` writes, mapped back to the
    /// outcome it stands for — read off the RENDERER rather than spelled a
    /// second time here.
    ///
    /// `DiagnoseRendering.outcomeKey` is private, and deliberately: the
    /// programmatic spelling is the renderer's to choose. Asking
    /// `jsonObject(for:)` about a sample step is how a script would learn it
    /// too, and it means a renamed spelling moves this table with it instead
    /// of leaving a case comparing against a word nothing prints.
    static func outcomeKeys() -> [String: DiagnosticOutcome] {
        var keys: [String: DiagnosticOutcome] = [:]
        for outcome in outcomeSamples {
            if let key = outcomeKey(for: outcome) { keys[key] = outcome }
        }
        return keys
    }

    /// The spelling `diagnose --json` writes for one outcome — the same
    /// derivation in the other direction, for a case that wants to say "this
    /// row is `ok`" without spelling the word.
    static func outcomeKey(for outcome: DiagnosticOutcome) -> String? {
        let id = DiagnosticStepID.resolve
        let step = DiagnosticStep(
            id: id, titleKey: DiagnosticStepID.titleKey(for: id), started: Date(),
            duration: .zero, outcome: outcome, detail: "")
        return DiagnoseRendering.jsonObject(for: step)["outcome"] as? String
    }

    /// The exit code Core's own rule gives for the rows a run printed:
    /// `DiagnoseRendering.exitCode(for:)`, asked about a report rebuilt from
    /// the decoded outcomes.
    ///
    /// DERIVED rather than pinned as a number, because the number is exactly
    /// what a runner can change. The ICMP echo is answered on loopback on
    /// the implementer's machine and may be refused in a CI sandbox
    /// (measured 2026-09-04), so a case that pinned 0 would be red on a
    /// runner whose sandbox says no — while the rule it is actually about
    /// ("16 as soon as one step failed or timed out") holds on both. An
    /// outcome spelling this cannot map throws rather than being counted as
    /// harmless.
    static func expectedExitCode(for steps: [CLIDiagnosedStep]) throws -> Int32 {
        let keys = outcomeKeys()
        let rebuilt = try steps.map { step -> DiagnosticStep in
            guard let outcome = keys[step.outcome] else {
                throw CLIMatrixError.unknownOutcome(step.outcome)
            }
            return DiagnosticStep(
                id: step.id, titleKey: DiagnosticStepID.titleKey(for: step.id),
                started: Date(), duration: .zero, outcome: outcome, detail: "")
        }
        return DiagnoseRendering.exitCode(
            for: DiagnosticReport(endpoint: nil, steps: rebuilt, appVersion: "test")).rawValue
    }

    /// The `completion` word the summary writes for `completion`, read off
    /// the renderer the same way `outcomeKeys()` reads the outcomes.
    static func completionKey(for completion: DiagnosticReport.Completion) -> String? {
        let report = DiagnosticReport(
            endpoint: nil, steps: [], appVersion: "test", completion: completion)
        return DiagnoseRendering.jsonSummary(for: report)["completion"] as? String
    }

    /// Every word a hop's `outcome` cell can carry — the three constants
    /// `ConnectionDiagnostics.traceTable(_:)` writes, plus every spelling
    /// `DiagnosticTraceColumn.unreachable(code:)` produces.
    ///
    /// The unreachable arm is expanded over the whole of `UInt8` rather than
    /// matched by prefix: a prefix check would accept `unreachable (code ` +
    /// anything, including the empty tail a formatting change could leave
    /// behind. 256 strings cost nothing and the set is exact.
    static let namedHopOutcomes: Set<String> = {
        var named: Set<String> = [
            DiagnosticTraceColumn.answered,
            DiagnosticTraceColumn.silent,
            DiagnosticTraceColumn.destination,
        ]
        for code in UInt8.min...UInt8.max {
            named.insert(DiagnosticTraceColumn.unreachable(code: code))
        }
        return named
    }()

    /// The keys a hop dictionary carries: the trace table's own columns,
    /// through the same `DiagnosticReport.header` derivation the renderer
    /// applies — not the four words spelled again here.
    static let hopKeys = Set(DiagnosticTraceColumn.all.map(DiagnosticReport.header))
}

/// A temporary session store with a session for EVERY backend, spread over
/// two top-level groups, one subgroup and two tags — the fixture the
/// `sessions` filter cases read.
///
/// It opens no connection and needs no rig: `SessionsCommand` reads
/// `SessionStore` and nothing else (no keychain, no network), which is the
/// whole reason that subcommand exists. What it does need is the built
/// binary, so the cases that drive it are gated with the rest of the matrix.
///
/// The sessions come from `CLIMatrix.make(for:label:)` — the same exhaustive
/// per-kind fixture the rig cases use — so a fourth protocol appears in this
/// store without an edit here, and its `target` column is a real one. The
/// PLACEMENT is derived from the position in `ConnectionKind.allCases`
/// rather than from which backend it is: the first lands in a top-level
/// group, the second in a subgroup of that group (so `--group <parent>` has
/// something to reach through), the third in the other top-level group, and
/// any further one stays at the top level, untagged. Every expectation is
/// computed from `entries` below, never from a count written down, so that
/// rotation cannot make a case wrong — only a case that asserts on an empty
/// expected set could, which is why each one checks its expectation is
/// non-empty first.
struct CLISessionCatalogFixture: Sendable {
    struct Entry: Sendable, Equatable {
        let name: String
        let kind: ConnectionKind
        /// Group names from the top down; empty for a top-level session.
        let ancestry: [String]
        let tags: [String]

        /// The `group` column `sessions --json` prints for this entry.
        var groupPath: String { ancestry.joined(separator: " / ") }
    }

    static let parentGroup = "cli-matrix-alpha"
    static let childGroup = "cli-matrix-nested"
    static let otherGroup = "cli-matrix-beta"
    static let firstTag = "cli-matrix-red"
    static let secondTag = "cli-matrix-blue"

    /// The groups `make()` writes, as data rather than as a number a guard
    /// would have to keep in step: `make()` builds exactly these three and
    /// `everyBackendHasASessionInTheFilterFixture` compares the store's own
    /// group names against this list. A fourth group added to the fixture
    /// therefore needs no edit in the guard, and a group added WITHOUT being
    /// named here fails it.
    static let groupNames = [parentGroup, childGroup, otherGroup]

    let directory: URL
    let entries: [Entry]

    static func make() throws -> CLISessionCatalogFixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "macscp-cli-matrix-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let store = SessionStore(directory: directory)
            let parent = StoredGroup(name: parentGroup, position: 0)
            let child = StoredGroup(name: childGroup, parentID: parent.id, position: 0)
            let other = StoredGroup(name: otherGroup, position: 1)
            let groups = [parent, child, other]
            precondition(
                groups.map(\.name) == groupNames,
                "CLISessionCatalogFixture.groupNames no longer names what make() writes")
            for group in groups {
                try store.upsertGroup(group)
            }

            // Position in the store's own group tree, and the tags, per
            // position in `ConnectionKind.allCases`. The tuple is the
            // placement rule; `entries` below is the same rule as data, so
            // the expectations and the store cannot disagree.
            let placement: [(groupID: UUID?, ancestry: [String], tags: [String])] = [
                (parent.id, [parentGroup], [firstTag]),
                (child.id, [parentGroup, childGroup], [secondTag]),
                (other.id, [otherGroup], [firstTag, secondTag]),
            ]

            var entries: [Entry] = []
            for (index, kind) in ConnectionKind.allCases.enumerated() {
                let rig = try CLIMatrix.make(for: kind, label: "sessions")
                defer { rig.tearDown() }
                var session = rig.session
                let spot = index < placement.count
                    ? placement[index]
                    : (groupID: nil, ancestry: [String](), tags: [String]())
                session.groupID = spot.groupID
                session.tags = spot.tags
                try store.upsert(session)
                entries.append(
                    Entry(
                        name: session.name, kind: kind, ancestry: spot.ancestry,
                        tags: spot.tags))
            }
            return CLISessionCatalogFixture(directory: directory, entries: entries)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Runs the binary against THIS store. No secret is set for any backend:
    /// `sessions` resolves none, and a child that carries one would be
    /// proving something else.
    @discardableResult
    func run(_ arguments: [String]) async throws -> SubprocessResult {
        var environment = ProcessInfo.processInfo.environment
        for kind in ConnectionKind.allCases {
            if let variable = BackendDescriptor.descriptor(for: kind).secretEnvironmentVariable {
                environment.removeValue(forKey: variable)
            }
        }
        environment["MACSCP_STORAGE_DIRECTORY"] = directory.path(percentEncoded: false)
        return try await SubprocessRunner.run(
            try CLIMatrix.binaryURL(), arguments: arguments, environment: environment)
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
/// the thing it IS at the moment it is created, and `withRig`'s `clean()`
/// dispatches on that to call `removeRemote` or `removeRemoteTree` (see
/// `CLIMatrix.removeRemoteTree` for why both still exist).
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

extension CLIMatrix {
    /// The subcommands the matrix's own cases DRIVE, read out of the case
    /// source rather than from a list a reader would have to maintain.
    ///
    /// The token is a LITERAL subcommand string as the first array element
    /// of a fixture's own run — `rig.run(["ls", …])` in a backend case,
    /// `fixture.run(["sessions", …])` in a sessions one,
    /// `rig.runStore(["tunnels", …])` in a store one,
    /// `rig.runUntilLine(["tunnels", …], matching: …)` in a `tunnels start`
    /// one. The whole `run…`
    /// family counts, because a rig has more than one way to run the binary:
    /// they differ in the child's ENVIRONMENT — `runStore` and
    /// `runWithoutASecret` put no secret in it (added to the pattern
    /// 2026-09-06, when the first `tunnels` case drove the binary through
    /// `runStore`) — and in WHEN the run ends, which is what `runUntilLine`
    /// adds (it signals a child that would otherwise never exit). A drive is
    /// a drive whichever of them a case picked. FOUR members today, counted
    /// 2026-09-06 against this file's own `func run` declarations.
    /// That is what
    /// "a case drives this subcommand" means here, and it is deliberately
    /// narrower than "the file mentions the name somewhere": a guard that
    /// asks the binary about a flag it does not declare, or reads a help
    /// screen, does so through `SubprocessRunner.run(binary, arguments:
    /// […])` — the binary first, an `arguments:` label second — so that
    /// shape cannot match the pattern at all. A guard that instead drives a
    /// subcommand through `rig.run([…])` keeps the name in a VARIABLE
    /// rather than a literal for exactly this reason
    /// (`theConflictActionsAreTheOnesCoreDefines` does, the same way
    /// `neitherTransferCommandOffersARecursiveFlag` does): a literal there
    /// would enter the driven set from a guard, not a case, which is what
    /// "the guards cannot match" actually depends on — the call shape a
    /// guard happens to use, not something guards are structurally unable
    /// to do.
    ///
    /// COMMENT LINES ARE REMOVED FIRST, and structurally rather than by
    /// asking the author to be careful: this project writes long
    /// explanatory comments AND scans its own source, and a comment quoting
    /// a call is indistinguishable from the call to a scanner (CLAUDE.md,
    /// "Source-scanning guards read comments too"). A commented-out drive
    /// must not count as coverage.
    ///
    /// Pure, so the two hazards above are measured against a fixture rather
    /// than argued about — see `theDrivenScanReadsCallsAndNotComments`, whose
    /// fixture is `drivenScanFixture` below.
    static func drivenSubcommands(inSource source: String) throws -> Set<String> {
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // The rig's whole run family and nothing else — a name written by
        // the pattern rather than enumerated here, because a list in a
        // comment is a second copy of the members and this one has already
        // fallen behind once. The suffix may not contain a `(`, so
        // `SubprocessRunner.run(binary, …)` still cannot match (its first
        // argument is not an array literal either), and neither can the
        // STATIC `runUntilLine(_:arguments:…)`, which takes its binary
        // first for that reason.
        let pattern = try Regex(#"\.run[A-Za-z]*\(\s*\[\s*"([A-Za-z0-9-]+)""#)
        var names: Set<String> = []
        for match in code.matches(of: pattern) {
            guard let range = match.output[1].range else { continue }
            names.insert(String(code[range]))
        }
        return names
    }

    /// The source `theDrivenScanReadsCallsAndNotComments` measures the scan
    /// against, in the shapes the case file really contains: a drive whose
    /// call spans two lines, a drive on one line, a drive through a
    /// differently-named member of the run family, a commented-out drive, a
    /// prose sentence quoting one, and one of the guards' own
    /// `SubprocessRunner` launches (which passes the binary first, so the
    /// pattern cannot reach it).
    ///
    /// The `runUntilLine` line is there for the same reason `runStore`'s is:
    /// it is a real member of the run family with a name the pattern has to
    /// reach through, and a scan that only knew `run(` and `runStore(` would
    /// pass this fixture while missing every `tunnels start` case.
    ///
    /// It lives in THIS file rather than beside the test, and the placement
    /// is the whole point: `drivenSubcommands(inFileAt:)` scans the CASE
    /// file, where a fixture's live line is indistinguishable from a real
    /// drive — the names in it would enter the driven set from a string
    /// literal, and the coverage guard's positive companion would be
    /// satisfied by that literal too. Measured 2026-09-04 with
    /// `scripts/mutation-probe`, deleting the real `mkdir` case and its
    /// three wrappers: with the fixture beside the test the guard came back
    /// GREEN over 5 tests; with the fixture here it is RED. The scan never
    /// reads this file.
    static let drivenScanFixture = """
        let result = try await rig.run(
            ["mkdir"] + flags + [rig.target(remotePath)])
        let listed = try await fixture.run(["sessions"] + flags + ["--json"])
        let added = try await rig.runStore(["tunnels", "add", name, "--session", session])
        let held = try await rig.runUntilLine(["diagnose", name], matching: { $0 == "x" })
        // let skipped = try await rig.run(["nevermind"])
        /// A drive of rig.run(["alsonot"]) described in prose.
        let asked = try await SubprocessRunner.run(binary, arguments: ["help", name])
        """

    /// The names `drivenScanFixture` really declares — the answer the scan
    /// must give for it. Beside the fixture rather than in the case, so the
    /// two move together.
    static let drivenScanFixtureNames: Set<String> = [
        "mkdir", "sessions", "tunnels", "diagnose",
    ]

    /// The same scan, over a source FILE — the caller passes its own
    /// `#filePath`, so the guard reads the very file the cases live in and
    /// cannot be pointed at a stale copy.
    static func drivenSubcommands(inFileAt path: String) throws -> Set<String> {
        guard let source = try? SourceCorpus.text(of: URL(fileURLWithPath: path)),
              !source.isEmpty else {
            throw CLIMatrixError.unreadableTestSource(path)
        }
        return try drivenSubcommands(inSource: source)
    }
}

enum CLIMatrixError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case fixtureHasNoConfig(kind: String)
    case helpFailed(status: Int32)
    case noSubcommandsInHelp
    case noHostKeyRecorded(kind: String)
    case unreadableHostKey(kind: String)
    case unreadableSessionRow
    case unreadableTestSource(String)
    case emptyDiagnosis
    case unknownOutcome(String)

    var description: String {
        switch self {
        case .fixtureHasNoConfig(let kind):
            return "the \(kind) rig fixture carries no configuration of its own kind"
        case .noHostKeyRecorded(let kind):
            return "no host key was recorded for the \(kind) rig"
        case .unreadableHostKey(let kind):
            return "the host key recorded for the \(kind) rig is not readable Base64"
        case .unreadableSessionRow:
            return "sessions --json printed a line that is not a JSON object"
        case .emptyDiagnosis:
            return "diagnose --json printed nothing at all"
        case .unknownOutcome(let outcome):
            return """
                diagnose --json reported the outcome '\(outcome)', which is none of the \
                spellings DiagnoseRendering writes
                """
        case .unreadableTestSource(let path):
            return "the matrix case source could not be read at \(path)"
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
