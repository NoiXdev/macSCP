import Foundation
import MacSCPTestSupport
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

    /// The other value of `--pane`, and its absence: `files` is what a
    /// session gets when nothing is said, so a `--pane` that silently did
    /// nothing would be invisible without the `files-and-terminal` case above
    /// AND this one.
    @Test func theDefaultPaneIsFilesAndTheFlagCanSayItOutLoud() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "silent", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
        ]).status == 0)
        #expect(try await cli.run([
            "sessions", "add", "spoken", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob", "--pane", "files",
        ]).status == 0)

        let silent = try #require(cli.storedSession(named: "silent"))
        let spoken = try #require(cli.storedSession(named: "spoken"))
        #expect(silent.paneVisibility == .filesOnly)
        #expect(spoken.paneVisibility == .filesOnly)
    }

    /// A group path is EXTENDED, not re-created: a session filed under
    /// `"Work"` and a later one under `"Work / Prod"` share the `Work` the
    /// first one made. The reuse test above proves an identical path is
    /// reused; this proves a longer path walks into the shorter one rather
    /// than starting a second tree beside it.
    @Test func aLongerGroupPathExtendsTheOneAlreadyThere() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "shallow", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob", "--group", "Work",
        ]).status == 0)
        #expect(try await cli.run([
            "sessions", "add", "deep", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob", "--group", "Work / Prod",
        ]).status == 0)

        let groups = try SessionStore(directory: cli.storageDirectory).allGroups()
        #expect(groups.filter { $0.name == "Work" }.count == 1, "Work was made twice")
        let work = try #require(groups.first { $0.name == "Work" })
        let prod = try #require(groups.first { $0.name == "Prod" })
        #expect(work.parentID == nil)
        #expect(prod.parentID == work.id, "Prod was not filed under the existing Work")

        // Through the binary too, so the reuse is visible in what a person
        // reads rather than only in the file underneath it. Driven as
        // `sessions list --json`, the verb spelled out, beside the bare
        // `sessions --json` the other cases use: both spellings must work.
        let rows = try await cli.rows(["sessions", "list", "--json"])
        #expect(rows.count == 2)
        #expect(rows.contains { $0["group"] as? String == "Work" })
        #expect(rows.contains { $0["group"] as? String == "Work / Prod" })
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
        // The design's whole sentence, not the two words it shares with every
        // other refusal: it names the session that is in the way (as SAVED,
        // not as typed) and says which verb to reach for instead.
        #expect(
            refused.stderr.contains("a session named Prod already exists — use `sessions edit`"),
            "\(refused.stderr)")
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

    /// An empty value is not a value. `add` refused one already — its
    /// required fields are checked for emptiness, not merely for presence —
    /// but `edit` wrote it straight through and stored a session with no
    /// host, which is a record `SessionStore` keeps and nothing can dial.
    /// Both verbs are asserted here, because the check is one shared path and
    /// a fix on one side only would look exactly like this test passing.
    @Test func anEmptyValueIsRefusedByBothVerbs() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "web", "--kind", "ssh",
            "--host", "good.example.org", "--user", "bob",
        ]).status == 0)

        let addRefused = try await cli.run([
            "sessions", "add", "empty", "--kind", "ssh", "--host", "", "--user", "bob",
        ])
        #expect(
            addRefused.status == Self.validationFailure,
            "exit \(addRefused.status): \(addRefused.stderr)")
        #expect(addRefused.stderr.contains("--host"), "\(addRefused.stderr)")
        #expect(cli.storedSession(named: "empty") == nil)

        let editRefused = try await cli.run(["sessions", "edit", "web", "--host", ""])
        #expect(
            editRefused.status == Self.validationFailure,
            "exit \(editRefused.status): \(editRefused.stderr)")
        #expect(editRefused.stderr.contains("--host"), "\(editRefused.stderr)")
        let untouched = try #require(cli.storedSession(named: "web")?.ssh)
        #expect(untouched.host == "good.example.org", "the refused edit wrote anyway")
    }

    /// A session with no name is addressable by nothing: every other command
    /// takes `name:/path`, and `sessions edit`/`rm` match by name. Both the
    /// creating and the renaming path could write one.
    @Test func aSessionNameCannotBeEmpty() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        // Whitespace, not just "": the name rule trims before it compares, so
        // a name that is only spaces is the same empty name.
        let added = try await cli.run([
            "sessions", "add", "   ", "--kind", "ssh", "--host", "h.example.org", "--user", "bob",
        ])
        #expect(added.status == Self.validationFailure, "exit \(added.status): \(added.stderr)")
        let afterAdd = try await cli.rows(["sessions", "--json"])
        #expect(afterAdd.isEmpty, "an unnamed session was written: \(afterAdd)")

        #expect(try await cli.run([
            "sessions", "add", "web", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
        ]).status == 0)
        let renamed = try await cli.run(["sessions", "edit", "web", "--rename", ""])
        #expect(renamed.status == Self.validationFailure, "exit \(renamed.status): \(renamed.stderr)")
        #expect(cli.storedSession(named: "web") != nil, "the refused rename wrote anyway")
    }

    /// The port range Core already enforces at connect time
    /// (`SSHConnectionConfig`'s `1...65535`) and the app's own forwarding
    /// form states. Enforcing it here is what turns "the session fails to
    /// dial, later, somewhere else" into a usage error at the moment the
    /// value is typed. Both ends of the range are probed, and both verbs.
    @Test func aPortOutsideTheRangeIsRefused() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "sessions", "add", "web", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
        ]).status == 0)

        for port in ["0", "65536"] {
            let added = try await cli.run([
                "sessions", "add", "bad-\(port)", "--kind", "ssh",
                "--host", "h.example.org", "--user", "bob", "--port", port,
            ])
            #expect(
                added.status == Self.validationFailure,
                "add --port \(port) exited \(added.status): \(added.stderr)")
            #expect(
                added.stderr.contains("--port must be between 1 and 65535"), "\(added.stderr)")
            #expect(cli.storedSession(named: "bad-\(port)") == nil)

            let edited = try await cli.run(["sessions", "edit", "web", "--port", port])
            #expect(
                edited.status == Self.validationFailure,
                "edit --port \(port) exited \(edited.status): \(edited.stderr)")
        }

        // The positive at both ends: the range's own boundaries are accepted,
        // so a check that refused everything could not pass this.
        for port in ["1", "65535"] {
            #expect(try await cli.run(["sessions", "edit", "web", "--port", port]).status == 0)
            let ssh = try #require(cli.storedSession(named: "web")?.ssh)
            #expect(ssh.port == Int(port))
        }
    }

    /// **No secret is a flag.** The guard beside this suite scans the two
    /// store-editing files for the APIs that could READ one; this is the
    /// other half, and only the binary can answer it: an `@Option var
    /// password: String?` added to `SessionFieldOptions` would satisfy every
    /// source scan and every existing case here, and the only thing that
    /// notices is the binary accepting the flag.
    ///
    /// The positive is the same add without the flag, so a build that refused
    /// every add alike could not pass this.
    @Test func noSecretIsAcceptedAsAFlag() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        for flag in ["--password", "--passphrase", "--secret-key"] {
            let refused = try await cli.run([
                "sessions", "add", "secretive", "--kind", "ssh",
                "--host", "h.example.org", "--user", "bob", flag, "hunter2",
            ])
            #expect(
                refused.status == Self.validationFailure,
                "\(flag) exited \(refused.status): \(refused.stderr)")
            #expect(
                refused.stderr.contains(flag),
                "\(flag) was refused without being named: \(refused.stderr)")
            #expect(cli.storedSession(named: "secretive") == nil)
        }

        #expect(try await cli.run([
            "sessions", "add", "secretive", "--kind", "ssh",
            "--host", "h.example.org", "--user", "bob",
        ]).status == 0)
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

    /// The CLI opens no shell and has no flag for the terminal type (plan of
    /// 2026-09-19, Task 4), but it WRITES the store the override lives in.
    /// A session the app gave an override must keep it through every verb
    /// that rewrites or reads that file: `edit` on another field, `add` of a
    /// second session, and the listing.
    @Test func theVerbsLeaveATerminalTypeOverrideUntouched() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        var seeded = StoredSession(name: "web", kind: .ssh)
        seeded.ssh = StoredSSHConfig(host: "host.invalid", username: "bob")
        seeded.ssh?.terminalType = .vt100
        try SessionStore(directory: cli.storageDirectory).upsert(seeded)

        #expect(try await cli.run(["sessions", "edit", "web", "--host", "other.invalid"]).status == 0)
        #expect(try await cli.run([
            "sessions", "add", "second", "--kind", "ssh", "--host", "h.invalid", "--user", "u",
        ]).status == 0)
        _ = try await cli.rows(["sessions", "--json"])

        let after = try #require(cli.storedSession(named: "web")?.ssh)
        #expect(after.host == "other.invalid", "the edit itself must have happened")
        #expect(after.terminalType == .vt100)
        #expect(cli.storedSession(named: "second")?.ssh?.terminalType == nil,
                "a session added by the CLI has no override: it uses the global setting")
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

    /// Moving a session into another group gives it a place among ITS
    /// siblings. Carrying the old `position` over means the moved session
    /// sorts by a number that was about a different list — landing above
    /// sessions that were there first, or below ones that were not.
    @Test func editingTheGroupPutsTheSessionAmongItsNewSiblings() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        for name in ["first", "second", "wanderer"] {
            #expect(try await cli.run([
                "sessions", "add", name, "--kind", "ssh",
                "--host", "h.example.org", "--user", "bob", "--group", "Work",
            ]).status == 0)
        }
        let before = try #require(cli.storedSession(named: "wanderer"))
        #expect(before.position == 2, "the fixture did not stack three sessions in one group")

        #expect(try await cli.run(["sessions", "edit", "wanderer", "--group", "Home"]).status == 0)

        let after = try #require(cli.storedSession(named: "wanderer"))
        #expect(after.groupID != before.groupID, "the move did not happen")
        #expect(after.position == 0, "the moved session kept a position from its old group")
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

    /// `sessions rm` over a `tunnels.json` it cannot decode: the SESSION is
    /// still removed, the forwarding store is left exactly as it was, and
    /// stderr says so, naming the file.
    ///
    /// Not blocked, deliberately. The forwarding store can only be repaired
    /// by hand, and a session nobody can delete until then is a worse
    /// outcome than a few rows left in a file the person has just been told
    /// to look at. What must not happen is the old behaviour — the file
    /// rewritten from empty, every other session's forwardings gone with it.
    @Test func rmOverAnUnreadableForwardingStoreRemovesTheSessionAndWarns() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }
        #expect(try await cli.run([
            "sessions", "add", "web", "--kind", "ssh", "--host", "h.example.org", "--user", "bob",
        ]).status == 0)
        let fileURL = cli.storageDirectory.appendingPathComponent("tunnels.json")
        let before = Data("kein json".utf8)
        try before.write(to: fileURL)
        let path = fileURL.path(percentEncoded: false)

        let removed = try await cli.run(["sessions", "rm", "web", "--yes"])

        #expect(removed.status == 0, "sessions rm failed: \(removed.stderr)")
        #expect(cli.storedSession(named: "web") == nil, "the session was not removed")
        #expect(removed.stderr.contains(path), "\(removed.stderr)")
        #expect(removed.stderr.contains("could not be read"), "\(removed.stderr)")
        #expect(try Data(contentsOf: fileURL) == before, "sessions rm rewrote an unreadable store")
    }

    /// `--verbose` over a `tunnels.json` that cannot be read does not claim
    /// a count it never had. The count used to come from the lenient reader,
    /// which answers an unreadable file with no profiles, so the summary
    /// read "Deleted web and 0 forwardings" while the file still held them.
    @Test func rmVerboseOverAnUnreadableForwardingStoreSaysTheCountIsUnknown() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }
        #expect(try await cli.run([
            "sessions", "add", "web", "--kind", "ssh", "--host", "h.example.org", "--user", "bob",
        ]).status == 0)
        try Data("kein json".utf8)
            .write(to: cli.storageDirectory.appendingPathComponent("tunnels.json"))

        let removed = try await cli.run(["sessions", "rm", "web", "--yes", "--verbose"])

        #expect(removed.status == 0, "sessions rm failed: \(removed.stderr)")
        #expect(!removed.stderr.contains("0 forwardings"), "\(removed.stderr)")
        #expect(
            removed.stderr.contains(SessionRemovalWording.summary(sessionName: "web", forwardings: nil)),
            "\(removed.stderr)")
        #expect(removed.stderr.contains("keychain entry left in place"), "\(removed.stderr)")
    }

    /// `sessions rm` over a `tunnels.json` that DECODES but cannot be
    /// written: the removal aborts with the write's own error, and the
    /// session and the file are both left as they were.
    ///
    /// The other half of `rmOverAnUnreadableForwardingStoreRemovesTheSessionAndWarns`:
    /// only an unreadable file is warned past (`StoreEditing.deleteSession`).
    /// A file that reads fine and refuses the write would otherwise leave
    /// the session gone and its forwardings in the file, addressing an id
    /// nothing resolves — the order that function's doc comment exists for.
    /// Unwritable by the file's user-immutable flag, not by permissions:
    /// the store writes atomically, renaming a temporary file over the
    /// target, which a read-only FILE does not prevent — and a read-only
    /// DIRECTORY would refuse the session store's write too, so the
    /// session would survive whatever order the removal took.
    @Test func rmOverAForwardingStoreThatCannotBeWrittenAbortsTheRemoval() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }
        #expect(try await cli.run([
            "sessions", "add", "web", "--kind", "ssh", "--host", "h.example.org", "--user", "bob",
        ]).status == 0)
        let session = try #require(cli.storedSession(named: "web"))
        try TunnelStore(directory: cli.storageDirectory).upsert(TunnelProfile(
            sessionID: session.id, name: "db",
            kind: .local(bind: "127.0.0.1", localPort: 5432, host: "db.internal", remotePort: 5432)))
        let fileURL = cli.storageDirectory.appendingPathComponent("tunnels.json")
        let before = try Data(contentsOf: fileURL)
        let filePath = fileURL.path(percentEncoded: false)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: filePath)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: filePath) }

        let removed = try await cli.run(["sessions", "rm", "web", "--yes", "--verbose"])

        #expect(
            removed.status == CLIExitCode.connection.rawValue,
            "exit \(removed.status): \(removed.stderr)")
        #expect(removed.stderr.hasPrefix("Error: "), "\(removed.stderr)")
        #expect(!removed.stderr.contains("Deleted"), "\(removed.stderr)")
        #expect(!removed.stderr.contains("Warning:"), "\(removed.stderr)")
        #expect(cli.storedSession(named: "web") != nil, "the session was removed anyway")
        #expect(try Data(contentsOf: fileURL) == before, "tunnels.json changed")
    }

    @Test func rmRefusesANameNoSessionCarries() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run(["sessions", "rm", "nothing", "--yes"])
        #expect(refused.status == Self.validationFailure, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains("nothing"), "\(refused.stderr)")
    }

    // MARK: - Harness

    /// The built binary plus its own throwaway store. A small value rather
    /// than four static functions because every case here needs the same
    /// pair and then asks the store what the binary wrote.
    private struct CLI {
        let binary: String
        let storageDirectory: URL

        static func make() throws -> CLI {
            CLI(
                binary: try CLIMatrix.binaryPath(),
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

    }

}

/// The security constraint the store-editing verbs exist under: **no secret
/// through the CLI**. `sessions add`/`edit` take no password, no passphrase
/// and no S3 secret key — not as a flag, not from stdin, not from the
/// keychain — and neither does any `tunnels` verb, so the files that carry
/// their flag table, their store access and the tunnel verbs themselves must
/// name none of the four APIs that could do it. FIVE files are scanned,
/// counted 2026-09-07: `SessionFieldOptions.swift` and `StoreEditing.swift`
/// against the whole list, `SessionsCommand.swift` against the stdin half
/// (`CLISessionsCommandGuardTests` already forbids `SecretStore` in it, and
/// the two suites keep one owner per claim), `TunnelsCommand.swift` against
/// the whole list, added the day the `tunnels` group arrived with a header
/// claiming exactly this and nothing measuring it, and
/// `TunnelStartCommand.swift` against the whole list too — added 2026-09-07
/// by the final review, which found the fifth verb unscanned.
///
/// A NEGATIVE check alone goes stale in silence the moment the files it
/// scans are renamed out from under it (CLAUDE.md, "Guards that name what
/// they watch"): a scan with nothing to scan finds no violations either. So
/// each negative here has a POSITIVE beside it — the file exists, and it
/// contains the construct that makes it the real implementation rather than
/// an empty file that vacuously passes.
///
/// `rm`'s confirmation is the one place these verbs read a person's answer,
/// and it is deliberately NOT in any scanned file: it goes through
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

    /// The `tunnels` group's own file, scanned since 2026-09-06 for the
    /// claim its header makes: "no secret, no keychain, no connection, in
    /// any verb below" — below being the four STORE verbs, which is all
    /// this file holds since `start` arrived in
    /// `TunnelStartCommand.swift`. Nothing held that claim when it was
    /// written — the
    /// other CLI guard (`CLISessionsCommandGuardTests`) scans a fixed list
    /// of five files this is not on, and the two files scanned above are the
    /// session verbs' — so the sentence was an assertion about code with
    /// nothing measuring it.
    private static let tunnelsCommandFile = repoRoot
        .appendingPathComponent("Sources/MacSCPCLI/TunnelsCommand.swift")

    /// The fifth verb. `tunnels start` DOES reach a secret — it dials — but
    /// never on its own: it asks `secretChain(for:options:)` for the chain
    /// every dialling verb in this tool walks, and that one function
    /// (`SessionConnecting.swift`) is where the keychain read and its
    /// consent prompt are reviewed. So the claim scanned here is not "no
    /// secret" but "no secret of its own": a `SecretStore` or a `readLine`
    /// appearing IN THIS FILE would be a second, unreviewed way in, which is
    /// exactly the shape a flag or a stdin read would take. It named none of
    /// the four when it was added to this list (counted 2026-09-07) and the
    /// negative below keeps it that way.
    private static let tunnelStartCommandFile = repoRoot
        .appendingPathComponent("Sources/MacSCPCLI/TunnelStartCommand.swift")

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
    /// The two stdin halves, split out because they are scanned in THREE
    /// files rather than two: the verbs themselves live in
    /// `SessionsCommand.swift`, which is where a "just read the password
    /// from stdin" would most naturally be written, and no guard looked at
    /// it for these until now (round-1 review, I4). That file legitimately
    /// names `SecretStore`-adjacent nothing but is not scanned for the
    /// storage half here — `CLISessionsCommandGuardTests` already forbids
    /// `SecretStore` in it, and the two suites are left with one owner per
    /// claim rather than two copies of it.
    private static let stdinIdentifiers = ["readLine", "FileHandle.standardInput"]

    /// The storage half: a secret this tool wrote down.
    private static let secretStorageIdentifiers = ["SecretStore", "Keychain"]

    private static let forbiddenIdentifiers = stdinIdentifiers + secretStorageIdentifiers

    /// The subset of `identifiers` that appears anywhere in `source`, in the
    /// order the list itself is declared — so a caller comparing against a
    /// literal array gets a stable result regardless of where in the source
    /// each identifier sits. Defaults to the whole list; the stdin-only scan
    /// passes its own half.
    private static func forbiddenMatches(
        in source: String, identifiers: [String] = forbiddenIdentifiers
    ) -> [String] {
        identifiers.filter { source.contains($0) }
    }

    // MARK: - Positive: both files exist and do the real work

    @Test func theFieldOptionsFileExistsAndCarriesTheKindOwnershipTable() throws {
        #expect(FileManager.default.fileExists(atPath: Self.fieldOptionsFile.path))
        let source = try SourceCorpus.text(of: Self.fieldOptionsFile)
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
        let source = try SourceCorpus.text(of: Self.storeEditingFile)
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
            let source = try SourceCorpus.text(of: file)
            let found = Self.forbiddenMatches(in: source)
            #expect(found.isEmpty, """
                \(file.lastPathComponent) names \(found) — sessions add/edit/rm \
                take no secret: not as a flag, not from stdin, not from the \
                keychain.
                """)
        }
    }

    // MARK: - The tunnels group, under the same constraint

    /// The positive beside the negative below: the file really is the
    /// `tunnels` verbs' implementation, so a scan reading a renamed or
    /// emptied file cannot report its absence of secrets as a pass.
    ///
    /// Both anchors are load-bearing rather than decorative.
    /// `TunnelCarriers.refusal(` is the refusal every verb's `--session`
    /// runs through — the file that stopped naming it would be one that
    /// stopped asking Core whether a session can carry a forwarding — and
    /// `StoreEditing.` is how the group reaches both stores, which is what
    /// keeps `onlyTheStoreEditingFileWritesTheStores` true of it.
    @Test func theTunnelsCommandFileExistsAndDoesTheRealWork() throws {
        #expect(FileManager.default.fileExists(atPath: Self.tunnelsCommandFile.path))
        let source = try SourceCorpus.text(of: Self.tunnelsCommandFile)
        #expect(source.contains("TunnelCarriers.refusal("), """
            TunnelsCommand.swift no longer names TunnelCarriers.refusal( — the \
            positive anchor beside the negative check below has nothing to \
            confirm the scanner is reading a real implementation.
            """)
        #expect(source.contains("StoreEditing."), """
            TunnelsCommand.swift no longer reaches StoreEditing — same concern \
            as TunnelCarriers.refusal( above.
            """)
    }

    /// The negative: the `tunnels` verbs name none of the four APIs that
    /// could carry a secret, in either direction.
    ///
    /// The CASE-SENSITIVITY of the scan is load-bearing here for the second
    /// time in this suite: the file's own prose says a forwarding "reads the
    /// keychain" nowhere and that the session's login is what it dials with,
    /// and those lowercase sentences say the opposite of a violation. The
    /// forbidden identifiers are spelled as the APIs are (`SecretStore`,
    /// `Keychain`), so prose about the idea cannot read as a use of the
    /// thing.
    @Test func theTunnelsVerbsNameNoSecretAPI() throws {
        let source = try SourceCorpus.text(of: Self.tunnelsCommandFile)
        let found = Self.forbiddenMatches(in: source)
        #expect(found.isEmpty, """
            TunnelsCommand.swift names \(found) — tunnels list/add/edit/rm take \
            no secret: not as a flag, not from stdin, not from the keychain.
            """)
    }

    /// The positive beside the negative below, for the fifth verb: the file
    /// really is `tunnels start`'s implementation. `secretChain(` is the
    /// shared chain it must keep going through, and `TunnelRunner(` is the
    /// composition it exists to build — a file that stopped naming either
    /// would not be the one this claim is about.
    @Test func theTunnelStartFileExistsAndResolvesThroughTheSharedChain() throws {
        #expect(FileManager.default.fileExists(atPath: Self.tunnelStartCommandFile.path))
        let source = try SourceCorpus.text(of: Self.tunnelStartCommandFile)
        #expect(source.contains("secretChain("), """
            TunnelStartCommand.swift no longer calls secretChain( — either it \
            stopped resolving a secret at all, or it grew a way of its own, \
            which is what the negative below exists to forbid.
            """)
        #expect(source.contains("TunnelRunner("), """
            TunnelStartCommand.swift no longer composes a TunnelRunner( — same \
            concern as secretChain( above.
            """)
    }

    /// The negative: `tunnels start` reaches its secret only through the
    /// shared chain, never through a store or a prompt of its own.
    @Test func theTunnelStartVerbNamesNoSecretAPIOfItsOwn() throws {
        let source = try SourceCorpus.text(of: Self.tunnelStartCommandFile)
        let found = Self.forbiddenMatches(in: source)
        #expect(found.isEmpty, """
            TunnelStartCommand.swift names \(found) — tunnels start resolves \
            its secret through secretChain(for:options:) and nowhere else: \
            not as a flag, not from stdin, not from a keychain call here.
            """)
    }

    /// The verbs' own file. `sessions rm` asks a question — through
    /// `CLIEnvironment.confirm(_:)`, in another file — and that is the whole
    /// of what these commands read from a person. A `readLine` HERE would be
    /// a second question nobody has reviewed, and the obvious place to write
    /// one is next to the verb that wants a value.
    ///
    /// The positive beside it is the same slice the prompt check below uses:
    /// the file really declares the remove command, so a scan reading a
    /// renamed or empty file cannot report this absence as a pass.
    @Test func theVerbsThemselvesReadNothingFromStandardInput() throws {
        let source = try SourceCorpus.text(of: Self.sessionsCommandFile)
        #expect(source.contains("struct SessionsRemoveCommand"), """
            SessionsCommand.swift no longer declares SessionsRemoveCommand — \
            the positive anchor beside the negative check has nothing to \
            confirm the scanner is reading a real implementation.
            """)
        let found = Self.forbiddenMatches(in: source, identifiers: Self.stdinIdentifiers)
        #expect(found.isEmpty, """
            SessionsCommand.swift names \(found) — sessions add/edit/rm read \
            nothing from standard input; the one question rm asks goes \
            through CLIEnvironment.confirm(_:).
            """)
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
        let source = try SourceCorpus.text(of: Self.sessionsCommandFile)
        let slice = try #require(
            Self.declarationSlice(of: "SessionsRemoveCommand", in: source),
            "SessionsCommand.swift declares no SessionsRemoveCommand")
        #expect(slice.contains("CLIEnvironment.confirm("), """
            sessions rm no longer calls CLIEnvironment.confirm( — the \
            confirmation before a delete is gone, or it moved to a path this \
            guard cannot see.
            """)
        #expect(slice.contains("[y/N]"), "sessions rm asks nothing that reads as a question")
        // The question's forwarding count comes from the wording that says
        // "unknown" for a count that could not be read, not from a number
        // interpolated here (next build of 2026-09-17, Task 2).
        let wording = "\(String(describing: SessionRemovalWording.self)).question("
        #expect(slice.contains(wording), "sessions rm no longer asks through \(wording)")
        #expect(slice.count < source.count, "the slice swallowed the whole file")
    }

    /// A session-store write in the CLI happens in exactly one file, and the
    /// two verbs that do it are the two this task added. Reading the set off
    /// the sources rather than writing it down means a THIRD writer — a
    /// future verb, or a stray `upsert` in a listing path — is red here
    /// rather than silently allowed.
    @Test func onlyTheStoreEditingFileWritesTheStores() throws {
        let cliDirectory = Self.repoRoot.appendingPathComponent("Sources/MacSCPCLI")
        let swiftFiles = try SourceCorpus.files(under: cliDirectory).filter { $0.pathExtension == "swift" }
        #expect(!swiftFiles.isEmpty, "found no .swift files under Sources/MacSCPCLI to scan")

        let writers = try swiftFiles.filter { file in
            let source = try SourceCorpus.text(of: file)
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
