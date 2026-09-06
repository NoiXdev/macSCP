import Foundation
import Testing
@testable import macSCPCore

/// `sessions add`, `sessions edit` and `sessions rm` — the store-writing
/// half of the `sessions` group, driven through the BUILT binary against a
/// temporary store, exactly the way `CLISessionsJSONRoundtripTests` drives
/// the listing half. Ungated for the same reason it is: these verbs open no
/// connection, read no keychain and need no rig — they read and write two
/// JSON files under `MACSCP_STORAGE_DIRECTORY`.
///
/// Every refusal below is asserted as exit code 64, not merely as
/// "non-zero": 64 is what ArgumentParser's own `exit(withError:)` gives a
/// `ValidationError`, and it is the only failure code these three verbs may
/// produce. A refusal that arrived as 13 would mean the check ran in `run()`
/// instead of `validate()` — where `CLIErrorMapping` classifies an unknown
/// error as a connection failure — and would tell a script the store was
/// unreachable when in fact its arguments were wrong.
@Suite("CLI sessions add/edit/rm")
struct CLISessionsEditingTests {
    /// ArgumentParser's `ExitCode.validationFailure`. Written here rather
    /// than imported because `CLIExitCode` (Core) deliberately does not
    /// carry it: it is ArgumentParser's number, not this project's.
    private static let validationFailure: Int32 = 64

    // MARK: - add

    @Test func addWritesAnSSHSessionWithKeyAuth() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let added = try await cli.run([
            "sessions", "add", "keyed",
            "--kind", "ssh", "--host", "example.org", "--user", "alice",
            "--port", "2200", "--key", "/tmp/id_ed25519",
        ])
        #expect(added.status == 0, "sessions add failed: \(added.stderr)")

        let session = try #require(cli.storedSession(named: "keyed"))
        let ssh = try #require(session.ssh)
        #expect(ssh.host == "example.org")
        #expect(ssh.port == 2200)
        #expect(ssh.username == "alice")
        #expect(ssh.authKind == .privateKey)
        #expect(ssh.keyPath == "/tmp/id_ed25519")

        let listed = try await cli.rows(["sessions", "--json"])
        #expect(listed.count == 1)
        #expect(listed.first?["name"] as? String == "keyed")
        #expect(listed.first?["target"] as? String == "alice@example.org:2200")
    }

    /// `--agent` picks the third auth kind, and `--port` left out means 22 —
    /// the default the design's table states, asserted rather than assumed.
    @Test func addWithoutAKeyOrAgentStoresPasswordAuthAndPortTwentyTwo() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "plain", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
        ]).status == 0)
        #expect(try await cli.run([
            "sessions", "add", "agented", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob", "--agent",
        ]).status == 0)

        let plain = try #require(cli.storedSession(named: "plain")?.ssh)
        #expect(plain.port == 22)
        #expect(plain.authKind == .password)
        #expect(plain.keyPath == nil)
        let agented = try #require(cli.storedSession(named: "agented")?.ssh)
        #expect(agented.authKind == .agent)
    }

    @Test func addWritesAnS3SessionWithItsRegionAndFlags() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let added = try await cli.run([
            "sessions", "add", "objects", "--kind", "s3",
            "--endpoint", "https://s3.example.com", "--bucket", "backups",
            "--access-key", "AKIAEXAMPLE", "--region", "eu-central-1",
            "--path-style", "--bucket-list",
        ])
        #expect(added.status == 0, "sessions add failed: \(added.stderr)")

        let s3 = try #require(cli.storedSession(named: "objects")?.s3)
        #expect(s3.endpoint == "https://s3.example.com")
        #expect(s3.bucket == "backups")
        #expect(s3.accessKeyID == "AKIAEXAMPLE")
        #expect(s3.region == "eu-central-1")
        #expect(s3.usePathStyle)
        #expect(s3.startsAtBucketList)
    }

    /// Without `--region` the stored region is `us-east-1`, the default the
    /// design's table names.
    @Test func addWithoutARegionStoresTheDefaultOne() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "objects", "--kind", "s3",
            "--endpoint", "https://s3.example.com", "--bucket", "backups",
            "--access-key", "AKIAEXAMPLE",
        ]).status == 0)

        let s3 = try #require(cli.storedSession(named: "objects")?.s3)
        #expect(s3.region == "us-east-1")
        #expect(s3.usePathStyle == false)
        #expect(s3.startsAtBucketList == false)
    }

    @Test func addWritesAWebDAVSessionWithTheNextcloudPath() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let added = try await cli.run([
            "sessions", "add", "cloud", "--kind", "webdav",
            "--url", "https://dav.example.com", "--user", "carol", "--nextcloud",
        ])
        #expect(added.status == 0, "sessions add failed: \(added.stderr)")

        let webdav = try #require(cli.storedSession(named: "cloud")?.webdav)
        #expect(webdav.baseURL == "https://dav.example.com")
        #expect(webdav.username == "carol")
        #expect(webdav.useNextcloudPath)
    }

    /// The group path is the one `sessions --json` prints back — `" / "`
    /// separated — and the groups along it are created when they are
    /// missing. Also the proof that `list` stayed the DEFAULT subcommand: the
    /// verification runs `sessions --json`, with no verb, exactly as every
    /// script written before this task did.
    @Test func addCreatesTheGroupPathAndCarriesItsTagsAndPanes() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "deep", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
            "--group", "Work / Prod", "--tag", "eu", "--tag", "db",
            "--pane", "files-and-terminal",
        ]).status == 0)

        let rows = try await cli.rows(["sessions", "--json"])
        #expect(rows.first?["group"] as? String == "Work / Prod")
        #expect(rows.first?["tags"] as? [String] == ["eu", "db"])
        let deep = try #require(cli.storedSession(named: "deep"))
        #expect(deep.paneVisibility == .bothVisible)

        // The second add reuses the groups the first created rather than
        // making a second "Work" beside it.
        #expect(try await cli.run([
            "sessions", "add", "deeper", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob", "--group", "Work / Prod",
        ]).status == 0)
        let groups = try SessionStore(directory: cli.storageDirectory).allGroups()
        #expect(groups.count == 2, "expected exactly Work and Prod, got \(groups.map(\.name))")
    }

    /// Case-insensitively, and trimmed — `SessionNameRule`'s
    /// `.caseInsensitive` matching, which the CLI passes explicitly and the
    /// app does not.
    @Test func aSecondSessionWithTheSameNameIsRefused() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "Prod", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
        ]).status == 0)

        let refused = try await cli.run([
            "sessions", "add", " prod ", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
        ])
        #expect(refused.status == Self.validationFailure, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains("already exists"), "\(refused.stderr)")
        let remaining = try await cli.rows(["sessions", "--json"])
        #expect(remaining.count == 1)
    }

    /// A flag that belongs to another backend is a usage error naming the
    /// kind it does belong to — and the SAME add without it succeeds, so a
    /// build that refused every add alike could not pass this.
    @Test func aFlagForTheWrongKindIsRefused() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run([
            "sessions", "add", "wrong", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob", "--bucket", "backups",
        ])
        #expect(refused.status == Self.validationFailure, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains("--bucket applies to --kind s3"), "\(refused.stderr)")
        #expect(cli.storedSession(named: "wrong") == nil)

        #expect(try await cli.run([
            "sessions", "add", "wrong", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
        ]).status == 0)
    }

    /// `--user` belongs to TWO kinds, so the message names both — the
    /// ownership table is per flag, not one kind per flag.
    @Test func aFlagSharedByTwoKindsNamesBothWhenItIsRefused() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run([
            "sessions", "add", "wrong", "--kind", "s3",
            "--endpoint", "https://s3.example.com", "--bucket", "b",
            "--access-key", "AKIA", "--user", "bob",
        ])
        #expect(refused.status == Self.validationFailure, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains("--user applies to --kind ssh, webdav"), "\(refused.stderr)")
    }

    @Test func aMissingRequiredFieldIsRefused() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run(["sessions", "add", "nohost", "--kind", "ssh", "--user", "bob"])
        #expect(refused.status == Self.validationFailure, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains("--host is required for --kind ssh"), "\(refused.stderr)")
    }

    @Test func aKeyAndAnAgentTogetherAreRefused() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run([
            "sessions", "add", "both", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
            "--key", "/tmp/id_ed25519", "--agent",
        ])
        #expect(refused.status == Self.validationFailure, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains("--key"), "\(refused.stderr)")
        #expect(refused.stderr.contains("--agent"), "\(refused.stderr)")
    }

    // MARK: - edit

    @Test func editChangesOnlyTheFieldsNamed() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "web", "--kind", "ssh",
            "--host", "old.example.org", "--user", "bob", "--port", "2200",
        ]).status == 0)
        let before = try #require(cli.storedSession(named: "web"))

        #expect(try await cli.run(["sessions", "edit", "web", "--host", "new.example.org"]).status == 0)

        let after = try #require(cli.storedSession(named: "web"))
        #expect(after.id == before.id, "editing must keep the id, and with it the keychain slot")
        let ssh = try #require(after.ssh)
        #expect(ssh.host == "new.example.org")
        #expect(ssh.port == 2200, "--port was not named and must not move")
        #expect(ssh.username == "bob")
    }

    @Test func editAddsATagAndNoTagRemovesIt() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "web", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob", "--tag", "eu",
        ]).status == 0)

        #expect(try await cli.run(["sessions", "edit", "web", "--tag", "db"]).status == 0)
        let tagged = try #require(cli.storedSession(named: "web"))
        #expect(tagged.tags == ["eu", "db"])

        #expect(try await cli.run(["sessions", "edit", "web", "--no-tag", "eu"]).status == 0)
        let untagged = try #require(cli.storedSession(named: "web"))
        #expect(untagged.tags == ["db"])
    }

    @Test func editRenamesAndRefusesARenameOntoATakenName() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        for name in ["one", "two"] {
            #expect(try await cli.run([
                "sessions", "add", name, "--kind", "ssh",
                "--host", "h.example.org", "--user", "bob",
            ]).status == 0)
        }

        let refused = try await cli.run(["sessions", "edit", "one", "--rename", "TWO"])
        #expect(refused.status == Self.validationFailure, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains("already exists"), "\(refused.stderr)")
        #expect(cli.storedSession(named: "one") != nil)

        #expect(try await cli.run(["sessions", "edit", "one", "--rename", "three"]).status == 0)
        #expect(cli.storedSession(named: "three") != nil)
        #expect(cli.storedSession(named: "one") == nil)
    }

    @Test func editRefusesToChangeTheKind() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "web", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
        ]).status == 0)

        let refused = try await cli.run(["sessions", "edit", "web", "--kind", "s3"])
        #expect(refused.status == Self.validationFailure, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains("--kind cannot change"), "\(refused.stderr)")
        let unchanged = try #require(cli.storedSession(named: "web"))
        #expect(unchanged.kind == .ssh)
    }

    /// The wrong-kind check on `edit` reads the STORED kind, since `edit`
    /// takes no kind of its own.
    @Test func editRefusesAFlagForTheStoredSessionsOtherKind() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "web", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
        ]).status == 0)

        let refused = try await cli.run(["sessions", "edit", "web", "--bucket", "backups"])
        #expect(refused.status == Self.validationFailure, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains("--bucket applies to --kind s3"), "\(refused.stderr)")
    }

    @Test func editRefusesANameNoSessionCarries() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run(["sessions", "edit", "nothing", "--host", "h"])
        #expect(refused.status == Self.validationFailure, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains("nothing"), "\(refused.stderr)")
    }

    // MARK: - rm

    /// No terminal to ask on and no `--yes`: refused, and the session is
    /// still there afterwards. `--non-interactive` says the same thing
    /// explicitly, and both are asserted so a build that only honoured the
    /// flag — and silently deleted when a script redirected stdin — cannot
    /// pass.
    @Test func rmWithoutYesIsRefusedWhenItCannotAsk() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "web", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
        ]).status == 0)

        for arguments in [["sessions", "rm", "web"], ["sessions", "rm", "web", "--non-interactive"]] {
            let refused = try await cli.run(arguments)
            #expect(
                refused.status == Self.validationFailure,
                "\(arguments) exited \(refused.status): \(refused.stderr)")
            #expect(refused.stderr.contains("--yes"), "\(refused.stderr)")
            #expect(cli.storedSession(named: "web") != nil, "\(arguments) deleted the session anyway")
        }
    }

    /// The deletion order the design states: the tunnel profiles first,
    /// through `TunnelStore.deleteAll(for:)`, then the session. The seeded
    /// profile belongs to the session being deleted; a second profile on
    /// ANOTHER session sits beside it and must survive, so a `deleteAll` that
    /// emptied the file wholesale is red here too.
    @Test func rmDeletesTheSessionAndItsForwardings() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        for name in ["web", "other"] {
            #expect(try await cli.run([
                "sessions", "add", name, "--kind", "ssh",
                "--host", "h.example.org", "--user", "bob",
            ]).status == 0)
        }
        let doomed = try #require(cli.storedSession(named: "web"))
        let spared = try #require(cli.storedSession(named: "other"))

        let tunnels = TunnelStore(directory: cli.storageDirectory)
        try tunnels.upsert(TunnelProfile(
            sessionID: doomed.id, name: "db",
            kind: .local(bind: "127.0.0.1", localPort: 5432, host: "db.internal", remotePort: 5432)))
        try tunnels.upsert(TunnelProfile(
            sessionID: spared.id, name: "keep",
            kind: .dynamic(bind: "127.0.0.1", localPort: 1080)))

        let removed = try await cli.run(["sessions", "rm", "web", "--yes", "--verbose"])
        #expect(removed.status == 0, "sessions rm failed: \(removed.stderr)")
        #expect(removed.stderr.contains("keychain entry left in place"), "\(removed.stderr)")

        #expect(cli.storedSession(named: "web") == nil)
        #expect(cli.storedSession(named: "other") != nil)
        #expect(
            tunnels.profiles(for: doomed.id).isEmpty,
            "the deleted session's forwarding profile outlived it")
        #expect(tunnels.profiles(for: spared.id).count == 1, "another session's profile was deleted")
    }

    @Test func rmRefusesANameNoSessionCarries() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run(["sessions", "rm", "nothing", "--yes"])
        #expect(refused.status == Self.validationFailure, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains("nothing"), "\(refused.stderr)")
    }

    // MARK: - Harness

    /// Exists only so `CLI.make()` has a class defined in THIS file to hand
    /// `Bundle(for:)` — same reason `CLISessionsJSONRoundtripTests` carries
    /// one.
    private final class TestBundleAnchor {}

    /// The built binary plus its own throwaway store. A small value rather
    /// than four static functions because every case here needs the same
    /// pair and then asks the store what the binary wrote.
    private struct CLI {
        let binary: String
        let storageDirectory: URL

        static func make() throws -> CLI {
            CLI(
                binary: try locateCLIBinary(),
                storageDirectory: try makeTempDirectory(prefix: "macscp-cli-sessions-editing"))
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: storageDirectory)
        }

        /// Runs the built CLI binary as a subprocess with an isolated
        /// storage directory and NO controlling terminal (stdin is the null
        /// device — `SubprocessRunner`'s `stdin: nil`). That is what makes
        /// `rm`'s "cannot ask" branch reachable here at all, and it is why
        /// no case below answers a prompt.
        func run(_ arguments: [String]) async throws -> (status: Int32, stdout: String, stderr: String) {
            var environment = ProcessInfo.processInfo.environment
            environment["MACSCP_STORAGE_DIRECTORY"] = storageDirectory.path(percentEncoded: false)
            let result = try await SubprocessRunner.run(
                URL(fileURLWithPath: binary), arguments: arguments, environment: environment)
            return (result.status, result.stdoutText, result.stderrText)
        }

        /// `sessions --json`'s lines, parsed. Fails the run rather than
        /// returning junk when the command itself did not succeed.
        func rows(_ arguments: [String]) async throws -> [[String: Any]] {
            let result = try await run(arguments)
            #expect(result.status == 0, "\(arguments) exited \(result.status): \(result.stderr)")
            return result.stdout.split(separator: "\n").compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        }

        /// What the STORE holds — the fields `sessions --json` deliberately
        /// does not print (`authKind`, the key path, the pane visibility)
        /// are only visible here.
        func storedSession(named name: String) -> StoredSession? {
            let sessions = (try? SessionStore(directory: storageDirectory).all()) ?? []
            return sessions.first { $0.name == name }
        }

        private static func makeTempDirectory(prefix: String) throws -> URL {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        /// Bundle-relative, for the reason `CLIMatrix.binaryURL()` states: a
        /// repo-root-relative `.build/debug` path breaks under
        /// `--scratch-path` and `-c release`, and running `swift build` from
        /// a test deadlocks on SwiftPM's own lock.
        private static func locateCLIBinary() throws -> String {
            if let override = ProcessInfo.processInfo.environment["MACSCP_CLI_BINARY"],
               !override.isEmpty {
                guard FileManager.default.isExecutableFile(atPath: override) else {
                    throw HarnessError("MACSCP_CLI_BINARY is set to \(override), which is not executable")
                }
                return override
            }
            let binaryPath = Bundle(for: TestBundleAnchor.self).bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("macscp-cli")
                .path(percentEncoded: false)
            guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
                throw HarnessError("""
                    macscp-cli not found at \(binaryPath).
                    Build it before running this suite:
                      swift build --product macscp-cli
                    or point MACSCP_CLI_BINARY at an existing binary.
                    """)
            }
            return binaryPath
        }
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// The security constraint the store-editing verbs exist under: **no secret
/// through the CLI**. `sessions add`/`edit` take no password, no passphrase
/// and no S3 secret key — not as a flag, not from stdin, not from the
/// keychain — so the two files that carry their flag table and their store
/// access must name none of the four APIs that could do it.
///
/// A NEGATIVE check alone goes stale in silence the moment the files it
/// scans are renamed out from under it (CLAUDE.md, "Guards that name what
/// they watch"): a scan with nothing to scan finds no violations either. So
/// each negative here has a POSITIVE beside it — the file exists, and it
/// contains the construct that makes it the real implementation rather than
/// an empty file that vacuously passes.
///
/// `rm`'s confirmation is the one place these verbs read a person's answer,
/// and it is deliberately NOT in either scanned file: it goes through
/// `CLIEnvironment.confirm(_:)`, the same terminal path `--accept-new`'s
/// host-key prompt uses, called from `SessionsCommand.swift`. The positive
/// check below pins that call INSIDE the `rm` command's own source slice, so
/// a build that dropped the question and deleted silently is red.
///
/// Same boundary as this project's other wiring guards (see
/// `CLISessionsCommandGuardTests`): a SOURCE-TEXT scan, not a behavioural
/// test — the behaviour is the suite above.
@Suite("CLI sessions store-editing guard")
struct CLISessionsStoreEditingGuardTests {
    /// `#filePath` is `<repoRoot>/Tests/macSCPCoreTests/<this file>`; two
    /// `deletingLastPathComponent()` calls for the file name and the two
    /// directories recover the repo root regardless of `swift test`'s
    /// working directory.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let fieldOptionsFile = repoRoot
        .appendingPathComponent("Sources/MacSCPCLI/SessionFieldOptions.swift")
    private static let storeEditingFile = repoRoot
        .appendingPathComponent("Sources/MacSCPCLI/StoreEditing.swift")
    private static let sessionsCommandFile = repoRoot
        .appendingPathComponent("Sources/MacSCPCLI/SessionsCommand.swift")

    /// The four ways a secret could reach these verbs. `readLine` and
    /// `FileHandle.standardInput` are the stdin halves — a password piped in
    /// is still a password the CLI handled — and `SecretStore`/`Keychain`
    /// are the storage halves.
    ///
    /// Case-sensitive, and that is load-bearing rather than incidental:
    /// `rm --verbose` prints the lowercase sentence "keychain entry left in
    /// place", which says the opposite of a violation and must not read as
    /// one. It lives in `SessionsCommand.swift`, not in either file scanned
    /// here, but the case rule is what keeps the two apart on purpose rather
    /// than by luck.
    private static let forbiddenIdentifiers = [
        "readLine", "FileHandle.standardInput", "SecretStore", "Keychain",
    ]

    private static func forbiddenMatches(in source: String) -> [String] {
        forbiddenIdentifiers.filter { source.contains($0) }
    }

    // MARK: - Positive: both files exist and do the real work

    @Test func theFieldOptionsFileExistsAndCarriesTheKindOwnershipTable() throws {
        #expect(FileManager.default.fileExists(atPath: Self.fieldOptionsFile.path))
        let source = try String(contentsOf: Self.fieldOptionsFile, encoding: .utf8)
        #expect(source.contains("ParsableArguments"), """
            SessionFieldOptions.swift declares no ParsableArguments — the \
            positive anchor beside the negative check below has nothing to \
            confirm the scanner is reading a real implementation.
            """)
        #expect(source.contains("--bucket"), """
            SessionFieldOptions.swift no longer names --bucket — same concern \
            as ParsableArguments above.
            """)
    }

    @Test func theStoreEditingFileExistsAndReachesBothStores() throws {
        #expect(FileManager.default.fileExists(atPath: Self.storeEditingFile.path))
        let source = try String(contentsOf: Self.storeEditingFile, encoding: .utf8)
        #expect(source.contains("SessionStore("), """
            StoreEditing.swift no longer constructs a SessionStore( — the \
            positive anchor beside the negative check below has nothing to \
            confirm the scanner is reading a real implementation.
            """)
        #expect(source.contains("TunnelStore("), """
            StoreEditing.swift no longer constructs a TunnelStore( — same \
            concern as SessionStore( above.
            """)
        #expect(source.contains("deleteAll(for:"), """
            StoreEditing.swift no longer calls TunnelStore.deleteAll(for:) — \
            a deleted session would leave its forwarding profiles behind.
            """)
    }

    // MARK: - Negative: neither file can reach a secret

    @Test func neitherStoreEditingFileNamesASecretAPI() throws {
        for file in [Self.fieldOptionsFile, Self.storeEditingFile] {
            let source = try String(contentsOf: file, encoding: .utf8)
            let found = Self.forbiddenMatches(in: source)
            #expect(found.isEmpty, """
                \(file.lastPathComponent) names \(found) — sessions add/edit/rm \
                take no secret: not as a flag, not from stdin, not from the \
                keychain.
                """)
        }
    }

    @Test func scannerFlagsAPlantedStdinRead() {
        let fixture = """
            struct FixtureOptions {
                func passphrase() -> String? {
                    FileHandle.standardInput.readDataToEndOfFile()
                    return readLine(strippingNewline: true)
                }
            }
            """
        #expect(Self.forbiddenMatches(in: fixture) == ["readLine", "FileHandle.standardInput"], """
            expected the scanner to flag the planted stdin reads, found \
            \(Self.forbiddenMatches(in: fixture)) instead.
            """)
    }

    @Test func scannerFlagsAPlantedKeychainWrite() {
        let fixture = """
            struct FixtureEditing {
                func store(_ value: String, for id: UUID) throws {
                    try SecretStore().set(value, for: id)
                }
            }
            """
        #expect(Self.forbiddenMatches(in: fixture) == ["SecretStore"], """
            expected the scanner to flag exactly the planted SecretStore call, \
            found \(Self.forbiddenMatches(in: fixture)) instead.
            """)
    }

    @Test func scannerAcceptsAFixtureNamingNoneOfTheForbiddenIdentifiers() {
        let fixture = """
            enum FixtureEditing {
                static func deleteSession(_ session: StoredSession) throws {
                    try TunnelStore(directory: directory).deleteAll(for: session.id)
                    try SessionStore(directory: directory).delete(id: session.id)
                }
            }
            """
        #expect(Self.forbiddenMatches(in: fixture).isEmpty)
    }

    // MARK: - The one question `rm` asks, in `rm`'s own source

    /// The prompt call is pinned INSIDE the remove command's declaration,
    /// not merely somewhere in the file: a `confirm(` left over in `add`
    /// would satisfy a whole-file scan while `rm` deleted without asking.
    ///
    /// The slice runs from the command's own declaration to the next
    /// top-level declaration, and both ends are checked: an empty slice, or
    /// one that swallowed the whole file, is reported as such rather than
    /// answering the question by accident.
    @Test func theRemoveCommandAsksOnTheTerminalBeforeDeleting() throws {
        let source = try String(contentsOf: Self.sessionsCommandFile, encoding: .utf8)
        let slice = try #require(
            Self.declarationSlice(of: "SessionsRemoveCommand", in: source),
            "SessionsCommand.swift declares no SessionsRemoveCommand")
        #expect(slice.contains("CLIEnvironment.confirm("), """
            sessions rm no longer calls CLIEnvironment.confirm( — the \
            confirmation before a delete is gone, or it moved to a path this \
            guard cannot see.
            """)
        #expect(slice.contains("[y/N]"), "sessions rm asks nothing that reads as a question")
        #expect(slice.count < source.count, "the slice swallowed the whole file")
    }

    /// A session-store write in the CLI happens in exactly one file, and the
    /// two verbs that do it are the two this task added. Reading the set off
    /// the sources rather than writing it down means a THIRD writer — a
    /// future verb, or a stray `upsert` in a listing path — is red here
    /// rather than silently allowed.
    @Test func onlyTheStoreEditingFileWritesTheStores() throws {
        let cliDirectory = Self.repoRoot.appendingPathComponent("Sources/MacSCPCLI")
        guard let enumerator = FileManager.default.enumerator(
            at: cliDirectory, includingPropertiesForKeys: nil)
        else {
            Issue.record("could not enumerate \(cliDirectory.path)")
            return
        }
        let swiftFiles = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!swiftFiles.isEmpty, "found no .swift files under Sources/MacSCPCLI to scan")

        let writers = try swiftFiles.filter { file in
            let source = try String(contentsOf: file, encoding: .utf8)
            return source.contains(".upsert(") || source.contains(".delete(id:")
        }
        #expect(
            Set(writers.map(\.lastPathComponent)) == ["StoreEditing.swift"],
            "these files write the session store: \(writers.map(\.lastPathComponent).sorted())")
    }

    /// The text between `<keyword> <name>` and the next line that starts a
    /// new top-level declaration. Pure, so the two hazards the caller checks
    /// for — an empty slice and one that ran to the end of the file — are
    /// answerable.
    private static func declarationSlice(of name: String, in source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("struct \(name)") })
        else { return nil }
        var end = lines.index(after: start)
        while end < lines.endIndex {
            let line = lines[end]
            if line.hasPrefix("struct ") || line.hasPrefix("enum ") || line.hasPrefix("extension ") {
                break
            }
            end = lines.index(after: end)
        }
        return lines[start..<end].joined(separator: "\n")
    }
}
