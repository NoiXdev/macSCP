import Foundation
import Testing
@testable import macSCPCore

/// `tunnels list`, `add`, `edit` and `rm` — the whole group, driven through
/// the BUILT binary against a temporary store, exactly the way
/// `CLISessionsEditingTests` drives the session verbs. Ungated for the same
/// reason that suite is: these verbs open no connection, read no keychain
/// and need no rig — they read and write two JSON files under
/// `MACSCP_STORAGE_DIRECTORY`.
///
/// Every refusal below is asserted as exit code 64, not merely as
/// "non-zero", for the reason `CLISessionsEditingTests` states: 64 is what
/// ArgumentParser's `exit(withError:)` gives a `ValidationError`, and a
/// refusal arriving as 13 would mean the check ran in `run()` — where
/// `CLIErrorMapping` classifies an unknown error as a connection failure —
/// and would tell a script the store was unreachable when its arguments
/// were wrong.
///
/// The refusal TEXTS are read from Core, never spelled here: the carriers'
/// sentence is `TunnelCarriers.refusal(for:)` and the spec's is
/// `TunnelSpecError.description`. A copy in a test is a second place the
/// wording lives, and the first one to drift is the copy.
@Suite("CLI tunnels list/add/edit/rm")
struct CLITunnelsEditingTests {
    /// ArgumentParser's `ExitCode.validationFailure`, written out for the
    /// reason `CLISessionsEditingTests` gives: `CLIExitCode` deliberately
    /// does not carry it.
    private static let validationFailure: Int32 = 64

    // MARK: - add

    @Test func addWritesALocalForwardingWithItsCanonicalSpec() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let added = try await cli.run([
            "tunnels", "add", "db", "--session", CLI.sshSessionName,
            "--local", "8080:db.internal:5432",
        ])
        #expect(added.status == 0, "tunnels add failed: \(added.stderr)")

        let profile = try #require(cli.profile(named: "db"))
        #expect(profile.kind == .local(
            bind: "127.0.0.1", localPort: 8080, host: "db.internal", remotePort: 5432))
        #expect(profile.autoStart == .off)
        #expect(profile.reconnects == false)

        // The bind address the spec left out is written out in the listing:
        // the row says which interface it listens on.
        let rows = try await cli.rows(["tunnels", "--json"])
        #expect(rows.count == 1)
        #expect(rows.first?.spec == "127.0.0.1:8080:db.internal:5432")
        #expect(rows.first?.kind == "local")
        #expect(rows.first?.session == CLI.sshSessionName)
    }

    @Test func addWritesARemoteForwardingWithTheBindItWasGiven() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "tunnels", "add", "back", "--session", CLI.sshSessionName,
            "--remote", "0.0.0.0:9000:127.0.0.1:3000",
        ]).status == 0)

        let profile = try #require(cli.profile(named: "back"))
        #expect(profile.kind == .remote(
            bind: "0.0.0.0", remotePort: 9000, localHost: "127.0.0.1", localPort: 3000))
        let rows = try await cli.rows(["tunnels", "--json"])
        #expect(rows.first?.spec == "0.0.0.0:9000:127.0.0.1:3000")
        #expect(rows.first?.kind == "remote")
    }

    @Test func addWritesADynamicForwardingWithItsAutostartAndReconnect() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "tunnels", "add", "socks", "--session", CLI.sshSessionName,
            "--dynamic", "1080", "--autostart", "app-start", "--reconnect",
        ]).status == 0)

        let profile = try #require(cli.profile(named: "socks"))
        #expect(profile.kind == .dynamic(bind: "127.0.0.1", localPort: 1080))
        #expect(profile.autoStart == .appStart)
        #expect(profile.reconnects)

        let row = try #require(try await cli.rows(["tunnels", "--json"]).first)
        #expect(row.spec == "127.0.0.1:1080")
        #expect(row.kind == "dynamic")
        // `app-start`, not the stored raw value `appStart`: what the listing
        // prints is what `--autostart` takes.
        #expect(row.autostart == "app-start")
        #expect(row.reconnect)
    }

    /// The three refusals `TunnelCarriers.refusal(for:)` words, each read
    /// from Core against the very session the store holds.
    @Test func addIsRefusedOnASessionThatCannotCarryAForwarding() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        for name in [CLI.s3SessionName, CLI.jumpSessionName, CLI.loginSetSessionName] {
            let session = try #require(cli.storedSession(named: name))
            let expected = try #require(
                TunnelCarriers.refusal(for: session),
                "\(name) is a session Core says CAN carry a forwarding")
            let refused = try await cli.run([
                "tunnels", "add", "nope", "--session", name, "--local", "8080:db:5432",
            ])
            #expect(refused.status == Self.validationFailure, "\(name) was not refused")
            #expect(refused.stderr.contains(expected), """
                \(name) was refused with "\(refused.stderr)", which does not carry Core's \
                own sentence
                """)
        }
        #expect(cli.profiles().isEmpty, "a refused add wrote a profile anyway")
    }

    @Test func addNeedsExactlyOneSpecFlag() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let both = try await cli.run([
            "tunnels", "add", "two", "--session", CLI.sshSessionName,
            "--local", "8080:db:5432", "--dynamic", "1080",
        ])
        #expect(both.status == Self.validationFailure)
        #expect(both.stderr.contains("--local"))

        let none = try await cli.run(["tunnels", "add", "none", "--session", CLI.sshSessionName])
        #expect(none.status == Self.validationFailure)
        #expect(none.stderr.contains("--dynamic"))

        #expect(cli.profiles().isEmpty)
    }

    /// The fork limit `TunnelSpec.parse(remote:)` refuses, with the sentence
    /// Core writes for it.
    @Test func addRefusesARemoteForwardingOnPortZero() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run([
            "tunnels", "add", "zero", "--session", CLI.sshSessionName,
            "--remote", "0:127.0.0.1:3000",
        ])
        #expect(refused.status == Self.validationFailure)
        #expect(refused.stderr.contains(TunnelSpecError.remotePortZero.description))
        #expect(cli.profiles().isEmpty)

        // The positive beside it: the same port is fine on a LOCAL bind,
        // where an ephemeral port is a real answer.
        #expect(try await cli.run([
            "tunnels", "add", "ephemeral", "--session", CLI.sshSessionName,
            "--local", "0:127.0.0.1:3000",
        ]).status == 0)
    }

    @Test func addRefusesASpecItCannotParse() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let spec = "8080:db"
        let refused = try await cli.run([
            "tunnels", "add", "half", "--session", CLI.sshSessionName, "--local", spec,
        ])
        #expect(refused.status == Self.validationFailure)
        #expect(refused.stderr.contains(TunnelSpecError.malformed(spec).description))
    }

    @Test func aSecondForwardingWithTheSameNameOnTheSameSessionIsRefused() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "tunnels", "add", "db", "--session", CLI.sshSessionName, "--local", "8080:db:5432",
        ]).status == 0)

        let refused = try await cli.run([
            "tunnels", "add", "DB", "--session", CLI.sshSessionName, "--local", "9090:db:5432",
        ])
        #expect(refused.status == Self.validationFailure)
        #expect(refused.stderr.contains("db"))
        #expect(cli.profiles().count == 1, "the refused add wrote a second profile")

        // The same name on ANOTHER session is not a conflict: uniqueness is
        // per session, which is what makes `--session` part of the handle.
        #expect(try await cli.run([
            "tunnels", "add", "db", "--session", CLI.otherSSHSessionName,
            "--local", "8080:db:5432",
        ]).status == 0)
        #expect(cli.profiles().count == 2)
    }

    @Test func aForwardingNameCannotBeEmpty() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run([
            "tunnels", "add", "   ", "--session", CLI.sshSessionName, "--local", "8080:db:5432",
        ])
        #expect(refused.status == Self.validationFailure)
        #expect(cli.profiles().isEmpty)
    }

    @Test func addRefusesASessionNameNoSessionCarries() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run([
            "tunnels", "add", "db", "--session", "nowhere", "--local", "8080:db:5432",
        ])
        #expect(refused.status == Self.validationFailure)
        #expect(refused.stderr.contains("nowhere"))
    }

    /// A `tunnels.json` the binary cannot decode is refused, not started
    /// over: before this, `add` read it as an empty store and wrote a file
    /// holding only the new forwarding. The exit code is the one
    /// `CLIErrorMapping` gives the store error — read from Core, not spelled
    /// here — and the stderr names the file so the person knows what to
    /// inspect.
    @Test func addOverAnUnreadableStoreIsRefusedAndLeavesTheFileAlone() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }
        let fileURL = cli.storageDirectory.appendingPathComponent("tunnels.json")
        let before = Data("kein json".utf8)
        try before.write(to: fileURL)
        let path = fileURL.path(percentEncoded: false)

        let refused = try await cli.run([
            "tunnels", "add", "db", "--session", CLI.sshSessionName, "--local", "8080:db:5432",
        ])

        let expected = CLIErrorMapping.exitCode(for: TunnelStoreError.unreadable(path: path))
        #expect(refused.status != 0)
        #expect(refused.status == expected.rawValue, "exit \(refused.status): \(refused.stderr)")
        #expect(refused.stderr.contains(path), "\(refused.stderr)")
        #expect(refused.stderr.contains("could not be read"), "\(refused.stderr)")
        #expect(try Data(contentsOf: fileURL) == before, "tunnels add rewrote an unreadable store")
    }

    // MARK: - list

    @Test func listShowsEverySessionsForwardingsAndTheSessionFilterNarrowsIt() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "tunnels", "add", "db", "--session", CLI.sshSessionName, "--local", "8080:db:5432",
        ]).status == 0)
        #expect(try await cli.run([
            "tunnels", "add", "socks", "--session", CLI.otherSSHSessionName, "--dynamic", "1080",
        ]).status == 0)

        let all = try await cli.rows(["tunnels", "--json"])
        #expect(Set(all.map(\.name)) == ["db", "socks"])

        let filtered = try await cli.rows([
            "tunnels", "list", "--session", CLI.otherSSHSessionName, "--json",
        ])
        #expect(filtered.map(\.name) == ["socks"])
        #expect(filtered.first?.session == CLI.otherSSHSessionName)

        // The columns carry the same six fields the JSON does, and the id
        // is only in the JSON.
        let columns = try await cli.run(["tunnels", "list"])
        #expect(columns.status == 0)
        let line = try #require(
            columns.stdout.split(separator: "\n").first { $0.contains("db") })
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        #expect(fields.count == 6, "the columns are \(fields)")
        #expect(Array(fields[0...4]) == [
            "db", Substring(CLI.sshSessionName), "local", "127.0.0.1:8080:db:5432", "off",
        ])
    }

    @Test func listOnAnEmptyStorePrintsNothingAndSucceeds() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let listed = try await cli.run(["tunnels", "--json"])
        #expect(listed.status == 0)
        #expect(listed.stdout.isEmpty)
    }

    /// A profile whose session is gone is still printed, named by the only
    /// thing known about it. `sessions rm` deletes a session's profiles with
    /// it, so this is a leftover the app could produce and this tool cannot
    /// — and a listing that dropped it silently would hide it from the one
    /// place a person might notice.
    @Test func listNamesAnOrphanedForwardingByItsSessionId() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let orphanID = UUID()
        try TunnelStore(directory: cli.storageDirectory).upsert(TunnelProfile(
            sessionID: orphanID, name: "orphan",
            kind: .dynamic(bind: "127.0.0.1", localPort: 1080)))

        let row = try #require(try await cli.rows(["tunnels", "--json"]).first)
        #expect(row.name == "orphan")
        #expect(row.session == orphanID.uuidString)
    }

    @Test func listRefusesASessionNameNoSessionCarries() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run(["tunnels", "list", "--session", "nowhere"])
        #expect(refused.status == Self.validationFailure)
        #expect(refused.stderr.contains("nowhere"))
    }

    // MARK: - edit

    @Test func editChangesTheKindAndLeavesTheRestAlone() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "tunnels", "add", "db", "--session", CLI.sshSessionName,
            "--local", "8080:db:5432", "--autostart", "login", "--reconnect",
        ]).status == 0)
        let before = try #require(cli.profile(named: "db"))

        let edited = try await cli.run([
            "tunnels", "edit", "db", "--session", CLI.sshSessionName, "--dynamic", "[::1]:1080",
        ])
        #expect(edited.status == 0, "tunnels edit failed: \(edited.stderr)")

        let after = try #require(cli.profile(named: "db"))
        #expect(after.kind == .dynamic(bind: "::1", localPort: 1080))
        #expect(after.id == before.id, "the profile lost its identity")
        #expect(after.autoStart == .login)
        #expect(after.reconnects)
        // The IPv6 literal comes back bracketed, which is what makes the
        // rendered spec parsable again.
        #expect(try await cli.rows(["tunnels", "--json"]).first?.spec == "[::1]:1080")
    }

    @Test func editTurnsReconnectOffAndAutostartBack() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "tunnels", "add", "db", "--session", CLI.sshSessionName,
            "--local", "8080:db:5432", "--autostart", "login", "--reconnect",
        ]).status == 0)

        #expect(try await cli.run([
            "tunnels", "edit", "db", "--session", CLI.sshSessionName,
            "--no-reconnect", "--autostart", "off",
        ]).status == 0)

        let after = try #require(cli.profile(named: "db"))
        #expect(after.reconnects == false)
        #expect(after.autoStart == .off)
        #expect(after.kind == .local(
            bind: "127.0.0.1", localPort: 8080, host: "db", remotePort: 5432))
    }

    @Test func editRenamesAndRefusesARenameOntoATakenName() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        for name in ["db", "cache"] {
            #expect(try await cli.run([
                "tunnels", "add", name, "--session", CLI.sshSessionName,
                "--local", "8080:\(name):5432",
            ]).status == 0)
        }

        #expect(try await cli.run([
            "tunnels", "edit", "db", "--session", CLI.sshSessionName, "--rename", "database",
        ]).status == 0)
        #expect(cli.profile(named: "database") != nil)
        #expect(cli.profile(named: "db") == nil)

        let refused = try await cli.run([
            "tunnels", "edit", "database", "--session", CLI.sshSessionName, "--rename", "cache",
        ])
        #expect(refused.status == Self.validationFailure)
        #expect(cli.profile(named: "database") != nil, "the refused rename was written anyway")
    }

    @Test func editNeedsAtMostOneSpecFlagAndRefusesANameNoForwardingCarries() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "tunnels", "add", "db", "--session", CLI.sshSessionName, "--local", "8080:db:5432",
        ]).status == 0)

        let both = try await cli.run([
            "tunnels", "edit", "db", "--session", CLI.sshSessionName,
            "--local", "8080:db:5432", "--remote", "9000:127.0.0.1:3000",
        ])
        #expect(both.status == Self.validationFailure)

        let missing = try await cli.run([
            "tunnels", "edit", "gone", "--session", CLI.sshSessionName, "--dynamic", "1080",
        ])
        #expect(missing.status == Self.validationFailure)
        #expect(missing.stderr.contains("gone"))

        // Unchanged by either refusal.
        #expect(cli.profile(named: "db")?.kind == .local(
            bind: "127.0.0.1", localPort: 8080, host: "db", remotePort: 5432))
    }

    // MARK: - rm

    @Test func rmDeletesTheNamedForwardingAndLeavesTheOthers() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "tunnels", "add", "db", "--session", CLI.sshSessionName, "--local", "8080:db:5432",
        ]).status == 0)
        #expect(try await cli.run([
            "tunnels", "add", "db", "--session", CLI.otherSSHSessionName, "--dynamic", "1080",
        ]).status == 0)

        // No question is asked, and stdin is the null device here — a verb
        // that prompted would hang or read EOF as "no".
        let removed = try await cli.run(["tunnels", "rm", "db", "--session", CLI.sshSessionName])
        #expect(removed.status == 0, "tunnels rm failed: \(removed.stderr)")

        let left = cli.profiles()
        #expect(left.count == 1)
        #expect(left.first?.kind == .dynamic(bind: "127.0.0.1", localPort: 1080))
    }

    @Test func rmRefusesANameNoForwardingCarries() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run(["tunnels", "rm", "gone", "--session", CLI.sshSessionName])
        #expect(refused.status == Self.validationFailure)
        #expect(refused.stderr.contains("gone"))
    }

    /// A name is what `SessionNameRule.asSaved` makes of it — trimmed — and
    /// BOTH refusals about a name say so. They disagreed once: the
    /// "no forwarding named" sentence echoed the raw argument while the
    /// ambiguity sentence trimmed it, so the same typo read as two different
    /// names depending on which refusal answered.
    @Test func aRefusalNamesTheTrimmedNameTheStoreWouldHaveUsed() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        for verb in ["rm", "edit"] {
            let refused = try await cli.run([
                "tunnels", verb, "  gone  ", "--session", CLI.sshSessionName,
            ])
            #expect(refused.status == Self.validationFailure)
            #expect(refused.stderr.contains("no forwarding named gone on session"), """
                tunnels \(verb) refused with "\(refused.stderr)"
                """)
        }
    }

    /// `--reconnect` and `--no-reconnect` in one invocation is a usage
    /// error, not a last-one-wins: the pair is declared
    /// `exclusivity: .exclusive`, so a script that computed both flags is
    /// told rather than silently given one of them.
    @Test func bothReconnectFlagsTogetherAreRefused() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        #expect(try await cli.run([
            "tunnels", "add", "db", "--session", CLI.sshSessionName,
            "--local", "8080:db:5432", "--reconnect",
        ]).status == 0)

        let refused = try await cli.run([
            "tunnels", "edit", "db", "--session", CLI.sshSessionName,
            "--reconnect", "--no-reconnect",
        ])
        #expect(refused.status == Self.validationFailure)
        #expect(refused.stderr.contains("--no-reconnect"))
        #expect(cli.profile(named: "db")?.reconnects == true, "the refused edit changed the store")
    }

    /// An `--autostart` value outside Core's own three spellings is refused,
    /// and the refusal offers exactly those three — read from
    /// `TunnelProfile.AutoStart.rowName` here as `AutoStartOption` reads
    /// them for `allValueStrings`, so a fourth choice appears in the help
    /// without an edit in either place.
    @Test func anAutostartValueCoreDoesNotSpellIsRefused() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let refused = try await cli.run([
            "tunnels", "add", "db", "--session", CLI.sshSessionName,
            "--dynamic", "1080", "--autostart", "at-login",
        ])
        #expect(refused.status == Self.validationFailure)
        for spelling in TunnelProfile.AutoStart.allCases.map(\.rowName) {
            #expect(refused.stderr.contains(spelling), """
                the refusal does not offer \(spelling): "\(refused.stderr)"
                """)
        }
        #expect(cli.profiles().isEmpty)
    }

    // MARK: - The ambiguity only the app can create

    /// The app allows two profiles with the same name on one session; the
    /// command line addresses a profile BY that name, so it refuses rather
    /// than picking one. Seeded through `TunnelStore` directly, because no
    /// CLI verb can produce this state.
    @Test func anAmbiguousNameIsRefusedByEditAndRm() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let session = try #require(cli.storedSession(named: CLI.sshSessionName))
        let store = TunnelStore(directory: cli.storageDirectory)
        for port in [8080, 9090] {
            try store.upsert(TunnelProfile(
                sessionID: session.id, name: "db",
                kind: .local(bind: "127.0.0.1", localPort: port, host: "db", remotePort: 5432)))
        }

        let expected = "two forwardings named db on session \(CLI.sshSessionName) "
            + "— rename one in the app"
        for arguments in [
            ["tunnels", "edit", "db", "--session", CLI.sshSessionName, "--dynamic", "1080"],
            ["tunnels", "rm", "db", "--session", CLI.sshSessionName],
        ] {
            let refused = try await cli.run(arguments)
            #expect(refused.status == Self.validationFailure, "\(arguments[1]) did not refuse")
            #expect(refused.stderr.contains(expected), """
                \(arguments[1]) refused with "\(refused.stderr)"
                """)
        }
        #expect(cli.profiles().count == 2, "a refused verb changed the store anyway")

        // The positive beside the two refusals: `list` still shows both,
        // since listing addresses nothing.
        #expect(try await cli.rows(["tunnels", "--json"]).count == 2)
    }

    // MARK: - No secret, in either direction

    /// The group takes no secret — the same constraint the session verbs
    /// live under. Asserted through the binary rather than only by the
    /// source guard: an unknown option is a usage error, so a flag that
    /// existed would exit 0 here.
    @Test func noSecretIsAcceptedAsAFlag() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        for flag in ["--password", "--passphrase", "--secret-key"] {
            let refused = try await cli.run([
                "tunnels", "add", "db", "--session", CLI.sshSessionName,
                "--local", "8080:db:5432", flag, "hunter2",
            ])
            #expect(refused.status != 0, "tunnels add accepted \(flag)")
        }
        #expect(cli.profiles().isEmpty)
    }

    /// The same three flags against `start`, which is the verb that actually
    /// resolves a secret and so the one where a `--password` would look most
    /// natural to add.
    ///
    /// `add` above is enough for the four store verbs; `start` is a fifth,
    /// in a file of its own, and nothing measured it until the final review
    /// (2026-09-07). The source guard beside it
    /// (`CLISessionsStoreEditingGuardTests.theTunnelStartVerbNamesNoSecretAPIOfItsOwn`)
    /// covers the claim from the other side: a `@Option var password` would
    /// satisfy every scan for a keychain call, and only the binary can say
    /// whether the flag parses.
    ///
    /// **What the refusal says, measured 2026-09-07.** An unknown option
    /// is refused as one, naming the flag. It did not use to be: `alsoNamed`
    /// is a variadic `@Argument`, and ArgumentParser's default strategy for
    /// one takes dash-prefixed inputs it did not match — so BOTH the flag
    /// and its value landed there and the refusal was this tool's own "one
    /// forwarding per invocation" (exit 64 and no secret accepted, but the
    /// wrong reason). A dash check in `validate()` closed it after the final
    /// review (no parsing strategy refuses an unknown option while still
    /// collecting a bare second name); the two-names sentence is driven
    /// below with what it exists for, a real second name.
    ///
    /// The positive that keeps the negative honest is the same command line
    /// without the flag: it must NOT be refused with that sentence, so the
    /// extra positional the flag creates is what produced it. It is refused
    /// all the same — no `db` profile is seeded — which is why the check is
    /// on the sentence rather than on the status.
    @Test func noSecretIsAcceptedAsAFlagByStart() async throws {
        let cli = try CLI.make()
        defer { cli.tearDown() }

        let twoNames = "one forwarding per invocation"
        for flag in ["--password", "--passphrase", "--secret-key"] {
            let refused = try await cli.run([
                "tunnels", "start", "db", "--session", CLI.sshSessionName,
                flag, "hunter2",
            ])
            #expect(
                refused.status == Self.validationFailure,
                "\(flag) exited \(refused.status): \(refused.stderr)")
            // The trailing positional refuses a dash-prefixed stray AS AN
            // OPTION, naming it, not as a second name.
            #expect(
                refused.stderr.contains(flag) && !refused.stderr.contains(twoNames),
                "\(flag) was refused for another reason: \(refused.stderr)")
        }

        // The sentence the positional exists for, driven with what it is
        // for: a real second name.
        let twoForwardings = try await cli.run([
            "tunnels", "start", "db", "other", "--session", CLI.sshSessionName,
        ])
        #expect(twoForwardings.status == Self.validationFailure)
        #expect(
            twoForwardings.stderr.contains(twoNames),
            "two names were refused for another reason: \(twoForwardings.stderr)")

        let withoutTheFlag = try await cli.run([
            "tunnels", "start", "db", "--session", CLI.sshSessionName,
        ])
        #expect(
            withoutTheFlag.stderr.contains(twoNames) == false,
            "the flag is not what produced the refusal: \(withoutTheFlag.stderr)")
    }

    // MARK: - Binary-level harness

    /// The built binary plus its own throwaway store, seeded with the four
    /// sessions the cases address: one ordinary SSH session, a second one
    /// (so per-session uniqueness has a second session to be measured
    /// against), and the three shapes `TunnelCarriers.refusal(for:)` names —
    /// an S3 session, an SSH session behind a jump host, and one that
    /// belongs to a login set.
    private struct CLI {
        let binary: String
        let storageDirectory: URL

        static let sshSessionName = "web"
        static let otherSSHSessionName = "web2"
        static let s3SessionName = "objects"
        static let jumpSessionName = "behind"
        static let loginSetSessionName = "shared"

        static func make() throws -> CLI {
            let cli = CLI(
                binary: try CLIMatrix.binaryPath(),
                storageDirectory: try makeTempDirectory(prefix: "macscp-cli-tunnels-editing"))
            let store = SessionStore(directory: cli.storageDirectory)
            try store.upsert(sshSession(name: sshSessionName, host: "example.org"))
            try store.upsert(sshSession(name: otherSSHSessionName, host: "example.net"))
            try store.upsert(s3Session(name: s3SessionName))
            try store.upsert(sshSession(
                name: jumpSessionName, host: "internal.example.org",
                jump: StoredSession.JumpSpec(host: "gate.example.org", username: "alice")))
            try store.upsert(sshSession(
                name: loginSetSessionName, host: "example.org", loginSetID: UUID()))
            return cli
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: storageDirectory)
        }

        /// Runs the built binary with an isolated storage directory and NO
        /// controlling terminal (`SubprocessRunner` hands the child the null
        /// device for stdin) — so a verb in this group that asked a question
        /// would be visible here as a hang or an EOF, rather than passing
        /// unnoticed.
        func run(
            _ arguments: [String]
        ) async throws -> (status: Int32, stdout: String, stderr: String) {
            var environment = ProcessInfo.processInfo.environment
            environment["MACSCP_STORAGE_DIRECTORY"] = storageDirectory.path(percentEncoded: false)
            let result = try await SubprocessRunner.run(
                URL(fileURLWithPath: binary), arguments: arguments, environment: environment)
            return (result.status, result.stdoutText, result.stderrText)
        }

        /// `tunnels --json`'s lines, decoded into `TunnelRow` — the Core type
        /// the command prints, so the keys are pinned by the type rather
        /// than by string literals here. Fails the run rather than returning
        /// junk when the command itself did not succeed.
        func rows(_ arguments: [String]) async throws -> [TunnelRow] {
            let result = try await run(arguments)
            #expect(result.status == 0, "\(arguments) exited \(result.status): \(result.stderr)")
            let decoder = JSONDecoder()
            return result.stdout.split(separator: "\n").compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(TunnelRow.self, from: data)
            }
        }

        /// What the STORE holds — a profile's id and its stored `autoStart`
        /// raw value are only visible here.
        func profiles() -> [TunnelProfile] {
            TunnelStore(directory: storageDirectory).allProfiles()
        }

        func profile(named name: String) -> TunnelProfile? {
            profiles().first { $0.name == name }
        }

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
